#!/usr/bin/env ruby

# drun gnome run dialog
# Copyright (C) 2008 David Maciver
#
# GTK3 port: Jeremy Sylvestre
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

require 'gtk3'
require 'fileutils'

Windows = (ENV['OS'] =~ /Windows/)

if Windows
	require 'win32ole'
	require 'Win32API'

	PATH = ENV['PATH'].split(/;/).map { |x| x.gsub('\\', '/') }
	HOME = ENV['USERPROFILE'].gsub('\\', '/')
else
	PATH = ENV['PATH'].split(/:/)
	HOME = ENV['HOME']
end


CacheDir = "#{HOME}/.cache/drun"
FileUtils.mkdir_p "#{CacheDir}"
HistFile = "#{CacheDir}/history"

ConfigDir = "#{HOME}/.config/drun"
ConfigFile = "#{ConfigDir}/.config/drun/rc"

useShortcut = false

# If a directory is passed, then that is what the CWD is set to.
# If filenames are passed, then the CWD is the location of the first file and the files are added as arguments
$execpath = nil
$execargs = nil
if ARGV.length > 0
	if ARGV.length == 1 and ARGV[0] == '--shortcut'
		useShortcut = true
	elsif File.directory? ARGV[0]
		$execpath = ARGV[0]
	else
		$execargs = ARGV.map{ |x| "\"#{x}\"" }.join(' ')
		$execpath = ARGV[0][0..ARGV[0].rindex('/')] if ARGV[0][0..0] == '/'
	end
end

class Configuration
	def initialize(configfile)
		if Windows
			@httpHandler = "firefox"
			#@sshHandler = "xterm -e ssh"
			@fileHandler = "start"
			@directoryHandler = "explorer"
			@terminalHandler = "cmd"
		else
			@httpHandler = "firefox"
			@sshHandler = "xterm -e ssh"
			@fileHandler = "gnome-open"
			@directoryHandler = "nautilus"
			@terminalHandler = "Terminal -e"
		end

		return if not File.exists? configfile

		File.readlines(configfile).each { |line|
			if line =~ /^\s*http-handler\s*=(.*)/i
				@httpHandler = $1.strip
			elsif line =~ /^\s*ssh-handler\s*=(.*)/i
				@sshHandler = $1.strip
			elsif line =~ /^\s*file-handler\s*=(.*)/i
				@fileHandler = $1.strip
			elsif line =~ /^\s*directory-handler\s*=(.*)/i
				@directoryHandler = $1.strip
			elsif line =~ /^\s*terminal-handler\s*=(.*)/i
				@terminalHandler = $1.strip
			end
		}
	end

	attr_reader :httpHandler, :sshHandler, :fileHandler, :directoryHandler, :terminalHandler
end

# Keeps a history of recently run commands along with how many times they were run, reading/writing them to a file
class History
	def initialize(histfile)
		@histfile = histfile

		@entries = []
		@recent = []

		return if not File.exists? HistFile

		# Load history from HistFile which is formatted as a list of recent commands
		# then a blank line, then a list of "count command" in descending order by count
		recent = true
		File.readlines(HistFile).each { |line|
			if line =~ /^$/
				recent = false
			else
				if recent
					@recent += [line.strip]
				else
					line =~ /(\d*) (.*)/
					@entries += [[$1.to_i, $2]]
				end
			end
		}

		@entries.sort!.reverse!
	end

	def delete(input)
		# Deletes the entries matching input
		@entries.delete_if { |entry| entry[1] == input }
		@recent.delete_if { |recent| recent == input }

		# Update history file
		writeFile
	end

	def incCount(input)
		# Increments the count of the entry matching input or adds a new entry
		i = nil
		@entries.each_index { |x| i = x if @entries[x][1] == input }
		if i
			# Input exists, increment count
			@entries[i][0] += 1
		else
			# Add new entry
			@entries += [[1, input]]
		end

		# Only save 500 most significant entries
		@entries = @entries[0...500] if @entries.length > 500

		# Update recent entries
		@recent = [input] + @recent
		@recent.uniq!
		@recent = @recent[0...500] if @recent.length > 500

		# Update history file
		writeFile
	end

	def entries
		@entries
	end

	def recent
		@recent
	end
private
	def writeFile
		# Writes entries to HistFile
		File.open(@histfile, 'w') { |file|
			@recent.each { |x|
				file.puts x
			}
			file.puts
			@entries.each { |x|
				file.puts "#{x[0]} #{x[1]}"
			}
		}
	end
end

# Finds completions based on the history and the file system
class Completion
	def initialize(history)
		@history = history
	end

	def getRecent
		@history.recent
	end

	def getCompletion(input)
		c = getCompletionCorrections(input, 0)
		c = getCompletionCorrections(input, 2) if c == []
		c = getCompletionCorrections(input, 4) if c == []

		return c
	end

	def getReverseCompletion(input)
		return nil if input == ''

		input = createRegex(input)
		@history.recent.map { |x|
			return x if x =~ /#{input}/
		}
		return nil
	end

	def execInput(input, inTerminal=false)
		config = Configuration.new(ConfigFile)

		input = expandAll(input)

		# Find program corresponding to a url
		if input =~ /^(\w*):\/\/(.*)/
			prog = config.httpHandler if $1 == 'http'
			prog = config.fileHandler if $1 == 'file'
			if $1 == 'ssh'
				input.gsub!(/ssh:\/\//, '')
				prog = config.sshHandler
			end
		end

		if not prog
			prefix, suffix = getPrefixSuffix(input, false)

			prefix = unescape(prefix.strip)

			return if prefix == ''

			prefix = which(prefix) if which(prefix)

			if Windows and prefix =~ /.lnk$/i
				# Replace lnk path with target (windows shortcut)
				file = prefix.gsub('/', '\\')
				shell = WIN32OLE.new('WScript.Shell')
				link = shell.CreateShortcut(file)

				prefix = link.TargetPath
				input = escape(prefix)
				input += ' ' + suffix if suffix
			end

			if not which(prefix)
				if File.directory? prefix
					Dir.chdir prefix
					prog = inTerminal ? config.terminalHandler.split(' ').first : config.directoryHandler
				elsif not executable? prefix and File.file? prefix
					prog = config.fileHandler

					if Windows and config.fileHandler.downcase == 'start'
						# Don't know what escaping start should accept but it seems to work for the following

						# Convert: "c:/documents and settings/david/desktop/test file.txt"
						# To: c:/"documents and settings"/"david"/"desktop"/"test file.txt"

						prefix.gsub!(/"/, '')
						prefix.gsub!('/', '\\')
						prefix.gsub!('\\', '"\\"')
						prefix = prefix + '"'
						prefix.gsub!(':"\\', ':\\')
						input = "#{prefix} #{suffix}"
					end
				elsif not executable? prefix
					return
				end
			end
		end

		input = "#{prog} #{input}"
		input = config.terminalHandler + ' "' + input.gsub(/"/, '\\"') + '"' if inTerminal
		Dir.chdir $execpath if $execpath
		input += " #{$execargs}" if $execargs

		Thread.new { sleep 0.01; system(input) }

		return true
	end

	def getParentDirectory(input)
		prefix, suffix = getPrefixSuffix(input, true)

		if not suffix
			suffix = prefix
			prefix = ''
		end

		return input if not suffix

		suffix = unescape(suffix)

		if suffix =~ /(.*)\/$/
			suffix = $1
		end

		if suffix.count('/') == 1 and suffix =~ /^\/.+/
			suffix = '/'
		else
			suffix =~ /^(.*\/)/
			suffix = $1
		end

		return prefix if not suffix
		return (prefix + ' ' + escape(suffix)).strip
	end
private
	def escape(input)
		if Windows and input =~ / /
			return '"' + input + '"'
		end

		# Add a backslash before backslashes, quotes, and shell metacharacters
		input.gsub(/([ \\'"|&;()<>])/, "\\\\\\1")
	end

	def unescape(input)
		# Remove double quotes and unescaped backslashes outside of quotes

		s = ''

		quoted = false
		remaining = input
		while remaining and remaining.length > 0
			if remaining == '\\'
				# Final backslash is considered literal
				s += remaining
				remaining = ''
			elsif not quoted and remaining =~ /^\\/
				# Backslashes followed by a letter are considered literal
				s += '/' if remaining =~ /^\\[a-zA-Z]/

				s += remaining[1..1]
				remaining = remaining[2..-1]
			else
				quoted = !quoted if remaining =~ /^"/
				s += remaining[0..0] if not remaining =~ /^"/
				remaining = remaining[1..-1]
			end
		end

		return s
	end

	def getPrefixSuffix(input, greedyPrefix)
		# Return the parts of a string before and after the first or last unescaped space

		prefix = nil
		suffix = nil

		quoted = false
		remaining = input
		while remaining and remaining.length > 0
			if not quoted and remaining =~ /^\\/
				remaining = remaining[2..-1]
			else
				quoted = !quoted if remaining =~ /^"/
				if not quoted
					if remaining =~ /^ /
						prefix = input[0..(input.length-remaining.length-1)]
						suffix = remaining[1..-1]

						if not greedyPrefix
							return [prefix, suffix]
						end
					end
				end
				remaining = remaining[1..-1]
			end
		end

		if prefix
			return [prefix, suffix]
		else
			return [input, nil]
		end
	end

	def split(input)
		parts = []
		while input
			(prefix, suffix) = getPrefixSuffix(input, false)
			parts << unescape(prefix)
			input = suffix
		end
		return parts
	end

	def which(file)
		# Return the full path to an executable file by searching the path variable

		suffixes = ['']
		suffixes = ['', '.exe', '.bat', '.lnk', '.exe.lnk', '.bat.lnk'] if Windows

		PATH.each { |dir|
			suffixes.each { |suf|
				f = "#{dir}/#{file}#{suf}"
				return f if File.exists? f and executable? f and not File.directory? f
			}
		}
		return nil
	end

	def getCompletionCorrections(input, corrections)
		# Complete the text after the last space

		prefix, suffix = getPrefixSuffix(input, true)

		if suffix
			c = getCompletionHist(unescape(input), corrections)
			c += getCompletionPartial(unescape(suffix), corrections).map { |x| "#{prefix} #{x}" }
			c.uniq
		else
			getCompletionPartial(unescape(input), corrections)
		end
	end

	def expandAll(input)
		input = split(input).map { |x| escape(expand(x, true)) }.join(' ')
		input = input.gsub(/\//, '\\') if Windows
		return input
	end

	def expand(input, singleMatch=false)
		input = expandHome(input)

		if absoluteFilePath?(input)
			input = input.sub(/^file:\/\//, '')
			input = input.gsub(/\\/, '/') if Windows
		else
			if singleMatch
				if input =~ /^=(.*)/
					input = which($1) if which($1)
				end
			end
		end

		return input
	end

	def expandHome(input)
		match = input.match(/^~\//)
		return input.sub(match[0], HOME + '/') if match

		if Windows
			match = input.match(/^~\\/)
			return input.sub(match[0], HOME + '/') if match
		end

		if not Windows
			match = input.match(/^~[^\/]*/)
			if match
				begin
					return input.sub(match[0], File.expand_path(match[0]))
				rescue
				end
			end
		end

		return input
	end

	def getCompletionPartial(input, corrections)
		ret = []

		return ret if input.length == 0

		input = expand(input)

		if absoluteFilePath?(input)
			# Complete from executable and absolute path
			ret += getCompletionHist(input, corrections)
			ret += getCompletionDir(input, corrections)
		else
			# Complete executable from history and path
			ret += getCompletionHist(input, corrections)
			ret += getCompletionPath(input, corrections)
		end

		ret.uniq
	end

	def getCompletionDir(input, corrections)
		# Completes an absolute path
		# If any of the parent directories don't exist, recursively expand these directories first
		s = input.split(/\//)[0..-1]
		if not File.directory? s.join('/')
			2.upto(s.length - 1) { |x|
				if not File.directory? s[0...x].join('/')
					return getCompletionDir(s[0...x].join('/'), 0).map { |y|
						y += s[x..-1].join('/')
						getCompletionDir(unescape(y), corrections)
					}.flatten
				end
			}
		end

		if input =~ /(.*)\/$/ and not File.directory? input
			input = $1
		end

		if input =~ /\/$/
			glob = "#{input}*"
		else
			dirname = File.dirname(input)
			# Find hidden files if the input filename starts with a dot
			if File.basename(input) =~ /^\./
				glob = "#{dirname}/.*"
			else
				glob = "#{dirname}/*"
			end
			glob.gsub!(/\/\//, '/')
		end

		beginsWith(Dir.glob(glob), input, corrections).map { |x|
			x = File.directory?(x) ? "#{x}/" : x
			x = escape(x)
		}
	end

	def getCompletionHist(input, corrections)
		# Completes based on history
		beginsWith(@history.entries.map { |x| x[1] }, input, corrections)
	end

	def getCompletionPath(input, corrections)
		# Completes an executable name based on contents of PATH
		# Ignores hidden files in the path

		# A filename beginning with equals is substituted for a full path
		fullpath = false
		if input =~ /^=/
			input = input.sub(/^=/, '')
			fullpath = true
		end

		ret = []
		PATH.each { |dir|
			beginsWith(filesInDir(dir), input, corrections).each { |file| ret << [dir, file] }
		}

		if Windows
			ret.reject! { |x| not executable? x[1] }
			ret.map! { |dir, file| [dir, file.gsub(/\.(exe|lnk|bat)$/i, '')] } if not fullpath
		end

		ret.map! { |dir, file| [dir, escape(file)] }

		ret.sort_by { |x| x[1] }.map { |x| fullpath ? (x[0] + '/' + x[1]) : x[1] }
	end

	def filesInDir(dir)
		# Gets a list of all files in dir
		Dir.glob("#{dir}/*").map { |x| File.basename(x) }
	end

	def beginsWith(list, prefix, corrections)
		if corrections == 0
			return list.select { |x| x =~ /^#{createRegex(prefix)}/ }
		else
			return list.select { |x| x.split(//)[0] == prefix.split(//)[0] and editDistance(prefix, x[0...prefix.length]) <= corrections }
		end
	end

	def createRegex(input)
		# Return regex that matches input or input with some characters converted to uppercase
		input = Regexp.escape(input)
		# Keep '*' glob from input
		input = input.gsub(/\\\*/, '.*')
		input = input.split(//).map { |c| (c == c.downcase and c =~ /[a-zA-Z]/) ? "[#{c + c.upcase}]" : c }.join
		return input
	end

	def absoluteFilePath?(input)
		if Windows
			return true if input.length > 1 and input[1].chr == ':'
		end

		return true if input[0].chr == '/'
		return true if input =~ /^file:\/\//

		return false
	end

	def executable?(file)
		if Windows
			file =~ /\.(exe|lnk|bat)$/i
		else
			File.executable? file
		end
	end

	def editDistance(a, b)
		# Return the minimum number of insertions, deletions or subsitutions needed to transform a into b
		# Allow any characters in a to be converted to uppercase

		d = Array.new(a.length+1).map { Array.new(b.length+1) }
		0.upto(a.length) { |x| d[x][0] = x }
		0.upto(b.length) { |x| d[0][x] = x }

		asplit = [nil] + a.split(//)
		bsplit = [nil] + b.split(//)

		1.upto(a.length) { |x|
			1.upto(b.length) { |y|
				d[x][y] = [
					d[x][y-1] + 1,
					d[x-1][y] + 1,
					d[x-1][y-1] + ((asplit[x] == bsplit[y] or asplit[x].upcase == bsplit[y]) ? 0 : 2)
				].min
			}
		}

		d.last.last
	end
end

# A scrollable completion list window that calls various blocks on different events
class CompletionWindow < Gtk::Window
	def initialize(parent)
		super(:popup)

		@parent = parent

		@liststore = Gtk::ListStore.new(String)
		@treeview = Gtk::TreeView.new(@liststore)
		@treeview.headers_visible = false
		@treeview.insert_column(-1, "text", Gtk::CellRendererText.new, {:text => 0})
		@treeview.signal_connect('cursor_changed') { changeCompletion }

		@treeview.signal_connect('row_activated') { dismissCompletion; @activatedblock.call(false) }

		@scroll = Gtk::ScrolledWindow.new
		@scroll.add(@treeview)
		@scroll.set_policy(:automatic, :automatic)
		set_transient_for(parent)
		set_default_size(350, 200)
		set_accept_focus(false)

		frame = Gtk::Frame.new
		frame.add(@scroll)
		add(frame)
	end

	# Block to call to get a list of completions
	def setCompletionBlock(&completionblock)
		@completionblock = completionblock
	end

	# Block to call when a completion has been selected
	def setFinishedCompletionBlock(&finishedcompletionblock)
		@finishedcompletionblock = finishedcompletionblock
	end

	# Block to call when a completion entry has been deleted
	def setDeletionBlock(&deletionblock)
		@deletionblock = deletionblock
	end

	# Block to call to get the position to display a completion window
	def setGetPositionBlock(&getpositionblock)
		@getpositionblock = getpositionblock
	end

	# Block to call when a command is activated to run
	def setActivatedBlock(&activatedblock)
		@activatedblock = activatedblock
	end

	# Call to handle a gtk key press event
	def keyPressEvent(event)
		down = event.keyval == Gdk::Keyval::KEY_Down
		down ||= event.keyval == Gdk::Keyval::KEY_Tab
		up = event.keyval == Gdk::Keyval::KEY_Up
		del = event.keyval == Gdk::Keyval::KEY_Delete
		pagedown = event.keyval == Gdk::Keyval::KEY_Page_Down
		pageup = event.keyval == Gdk::Keyval::KEY_Page_Up

		ret = event.keyval == Gdk::Keyval::KEY_Return
		control = ((event.state & :control_mask) == :control_mask)
		shift = ((event.state & :shift_mask) == :shift_mask)

		up ||= (shift and event.keyval == Gdk::Keyval::KEY_ISO_Left_Tab)

		if ret
			dismissCompletion
			@activatedblock.call(control || shift)
			true
		elsif up or down or pageup or pagedown
			complete(down || pagedown)
			true
		elsif del and visible? and @deletionblock
			selected = @treeview.selection.selected
			if selected
				# Remove the selected completion entry keeping the selection at the same location
				# There might not be any selection after running this
				path = selected.path
				text = @treeview.model.get_value(@liststore.get_iter(path), 0)
				@liststore.remove(@treeview.selection.selected)
				@treeview.selection.select_path(path)

				dismissCompletion if not @liststore.iter_first

				@deletionblock.call(text)
			end
			true
		elsif (event.keyval == Gdk::Keyval::KEY_Shift_L) or (event.keyval == Gdk::Keyval::KEY_Shift_R)
		elsif visible?
			# Any unhandled keypress dismisses the completion
			dismissCompletion
			# Don't pass escape event to parent
			return (event.keyval == Gdk::Keyval::KEY_Escape)
		end
	end

	def complete(forward)
		# Move through the completion list.
		# If it isn't being displayed, then a new completion list is generated.
		if not visible?
			return if not @completionblock
			comp = @completionblock.call

			if comp.length == 1
				# Unique completion updates the text entry without a menu
				@finishedcompletionblock.call(comp.first)
			elsif comp.length > 1
				x,y = @getpositionblock.call
				# More than one completion creates a menu
				move(x, y)
				show_all
				# Add completion list for menu and select the first item
				@liststore.clear
				comp.each { |x|
					row = @liststore.append
					row.set_value(0, x)
				}
				@treeview.selection.select_path(Gtk::TreePath.new('0'))

				changeCompletion
			end
		else
			selected = @treeview.selection.selected
			if selected
				# Move selection up or down
				path = selected.path
				if forward
					return if not selected.next!
					path.next!
				else
					path.prev!
				end
			else
				# If there isn't a selection, select the first row
				path = @liststore.iter_first.path
			end
			@treeview.selection.select_path(path)

			changeCompletion

			# Scroll window to keep selection in the middle
			@treeview.scroll_to_cell(path, nil, true, 0.5, 0.5)
		end
	end
private
	def changeCompletion
		# Set the text entry to the selected completion
		path = @treeview.selection.selected.path
		text = @treeview.model.get_value(@liststore.get_iter(path), 0)

		@finishedcompletionblock.call(text) if @finishedcompletionblock
	end

	def dismissCompletion
		hide
		@parent.present
	end
end

# An entry that displays a completion list
class CompletionEntry < Gtk::Entry
	def initialize(parent)
		super()

		ignoreslashes = true
		enablereversesearch = true

		@completionwindow = CompletionWindow.new(parent)

		@completionwindow.setFinishedCompletionBlock() { |completion|
			@completedtext = completion
			self.text = completion
			self.position = self.text.length
		}

		@completionwindow.setGetPositionBlock() {
			# Display window underneath the text entry
			(_, _, _, height, _) = self.window.geometry
			(x, y) = self.window.origin
			[x + 1, y + height - 1]
		}

		self.signal_connect('key_press_event') { |widget, event|
			slash = (event.keyval == Gdk::Keyval::KEY_slash)
			escape = (event.keyval == Gdk::Keyval::KEY_Escape)
			slash ||= (event.keyval == Gdk::Keyval::KEY_backslash)

			if enablereversesearch
				control = ((event.state & :control_mask) == :control_mask)
				r = (event.keyval == Gdk::Keyval::KEY_r)
				tab = (event.keyval == Gdk::Keyval::KEY_Tab)
				ret = (event.keyval == Gdk::Keyval::KEY_Return)

				if tab or ret
					@reversesearch = nil
					@reversesearchendblock.call
				end

				if control and r
					if @reversesearch
						@reversesearch = nil
						@reversesearchendblock.call
					else
						@reversesearch = true
						@reversesearchtext = self.text
						completion = @reversecompletionblock.call(@reversesearchtext)
						if completion
							self.text = completion
							self.position = self.text.length
						end
					end
				elsif @reversesearch
					endsearch = false

					if Gdk::Keyval.to_unicode(event.keyval) > 0
						@reversesearchtext += GLib::UniChar.to_utf8(event.keyval)
					elsif event.keyval == Gdk::Keyval::KEY_BackSpace
						@reversesearchtext = @reversesearchtext[0..-2]
					elsif escape or
						event.keyval == Gdk::Keyval::KEY_Left or
						event.keyval == Gdk::Keyval::KEY_Right or
						event.keyval == Gdk::Keyval::KEY_Up or
						event.keyval == Gdk::Keyval::KEY_Down or
						event.keyval == Gdk::Keyval::KEY_Home or
						event.keyval == Gdk::Keyval::KEY_End

						endsearch = true
						@reversesearch = nil
						@reversesearchendblock.call
					end

					if not endsearch
						completion = @reversecompletionblock.call(@reversesearchtext)
						if completion
							self.text = completion
							self.position = self.text.length
						end
						handledevent = true
					end

					handledevent = true if escape
				end
			end

			if not handledevent
				handledevent = @keyPressBlock.call(event) if @keyPressBlock
			end

			if not handledevent
				handledevent = @completionwindow.keyPressEvent(event)
			end

			if ignoreslashes
				if slash and self.text == @completedtext and @completedtext =~ /\/"?$/
					@completedtext = nil
					handledevent = true
				end
			end

			Gtk.main_quit if not handledevent and escape

			@completedtext = nil if not handledevent

			handledevent
		}
	end

	def setReverseSearchEndBlock(&block)
		@reversesearchendblock = block
	end

	def setreversecompletionblock(&block)
		@reversecompletionblock = block
	end

	def setCompletionBlock(&block)
		@completionwindow.setCompletionBlock &block
	end

	def setDeletionBlock(&block)
		@completionwindow.setDeletionBlock &block
	end

	def setActivatedBlock(&block)
		@completionwindow.setActivatedBlock &block
	end

	def setKeyPressBlock(&block)
		@keyPressBlock = block
	end
end

# Main window displaying a completion entry which uses the completion class
class Window < Gtk::Window
	def initialize
		super

		@history = History.new(HistFile)
		@completion = Completion.new(@history)

		@completedtext = nil

		set_type_hint(Gdk::WindowTypeHint::DIALOG)
		set_window_position(:center_always)

		set_border_width(4)
		signal_connect('destroy') { Gtk.main_quit }
		set_default_size(500, 50)
		set_title('Run')

		vbox = Gtk::Box.new(:vertical, 1) # Gtk::VBox.new(false, 1)

		@runProgramLabel = Gtk::Label.new('  Run Program:')
		@runProgramLabel.set_alignment(0, 0)
		@notFoundLabel = Gtk::Label.new('<span color="red">Command not found</span>  ')
		@notFoundLabel.set_alignment(1, 0)

		@notFoundLabel.use_markup = true

		hbox = Gtk::Box.new(:horizontal, 1) # Gtk::HBox.new(false, 1)

		hbox.pack_start(@runProgramLabel, :expand => true, :fill => true, :padding => 0)
		hbox.pack_start(@notFoundLabel, :expand => true, :fill => true, :padding => 0)
		vbox.pack_start(hbox, :expand => false, :fill => false, :padding => 0)

		@textentry = CompletionEntry.new(self)
		vbox.pack_start(@textentry, :expand => true, :fill => true, :padding => 0)

		add(vbox)

		@textentry.setActivatedBlock { |inTerminal|
			if @completion.execInput(@textentry.text, inTerminal)
				@history.incCount(@textentry.text)
				Gtk.main_quit
			else
				@notFoundLabel.show
				Thread.new {
					sleep 1
					@notFoundLabel.hide
				}
			end
		}

		@textentry.setCompletionBlock() {
			if @textentry.text.length == 0
				@completion.getRecent
			else
				@completion.getCompletion(@textentry.text)
			end
		}

		@textentry.setreversecompletionblock() { |text|
			@runProgramLabel.text = "  reverse-i-search: #{text}"
			@completion.getReverseCompletion(text)
		}

		@textentry.setReverseSearchEndBlock() {
			@runProgramLabel.text = '  Run Program:'
		}

		@textentry.setDeletionBlock() { |text| @history.delete(text) }

		@textentry.setKeyPressBlock() { |event|
			up = event.keyval == Gdk::Keyval::KEY_Up
			down = event.keyval == Gdk::Keyval::KEY_Down
			alt = ((event.state & :mod1_mask) == :mod1_mask)

			handled = false

			@dirstack = [] if not @dirstack

			if up and alt
				old = @textentry.text
				@textentry.text = @completion.getParentDirectory(@textentry.text)
				@textentry.position = @textentry.text.length
				if @textentry.text != old
					@dirstack << [old, @textentry.text]
					@dirstack.reject! { |x| x[1].length < @textentry.text.length }
				end
				handled = true
			elsif down and alt
				if @dirstack
					dirs = @dirstack[-1]
					if dirs
						if dirs[1] == @textentry.text
							@dirstack.pop
							@textentry.text = dirs[0]
							@textentry.position = @textentry.text.length
						end
					end
				end
				handled = true
			end

			handled
		}

	end

	def show_all
		super
		@notFoundLabel.hide
	end
end

def showHideLoop
	loop {
		window = Window.new
		loop {
			Gtk.main_iteration while Gtk.events_pending?
			break if yield
		}
		window.show_all
		Gtk.main
		begin
			window.hide_all
		rescue
		end
		Gtk.main_iteration while Gtk.events_pending?
	}
end

if Windows
	VK_LWIN = 0x5b
	VK_RWIN = 0x5c
	VK_Q = 0x51
	VK_W = 0x57
	VK_E = 0x45
	VK_R = 0x52

	GetAsyncKeyState = Win32API.new("user32","GetAsyncKeyState",['i'],'i')
end

def pressed(key)
	GetAsyncKeyState.call(key) != 0
end

if useShortcut
	pressed(VK_W)
	pressed(VK_LWIN)
	pressed(VK_RWIN)
	showHideLoop {
		sleep 0.1

		# win+w pressed
		(pressed(VK_LWIN) or pressed(VK_RWIN)) and pressed(VK_W)
	}
else
	# Show run dialog once
	w = Window.new.show_all
	Gtk.main
end

sleep 0.1
