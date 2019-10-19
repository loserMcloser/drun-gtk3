# drun-gtk3
GTK3 port of drun

## Gotchas

+ I have moved config and history location.
  * Config moved from ~/.drunrc -> .config/drun/rc
  * History moved ~/.drun-history -> .cache/drun/history
+ On sway the DIALOG window hint seems to be ignored [issue #4655](https://github.com/swaywm/sway/issues/4655), but you can force floating mode with  
`for_window [app_id="drun"] floating enable`  
in your sway config.  
(Or `[app_id="drun.rb"]` if you haven't renamed the executable on install.)

