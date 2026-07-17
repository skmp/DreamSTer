# DreamSTer
polly2-rtl, minicast and a python TUI rolled together for the MiSTer environment.

This, currently, is very experimental and does not follow MiSTer conventions / is not a MiSTer core.

The way this works is quite nasty, it kills the MiSTer process, takes over the fpga
launches minicast and re-loads menu.rbf / re-starts MiSTer once done.