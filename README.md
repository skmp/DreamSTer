# DreamSTer
polly2-rtl, minicast and a python TUI rolled together for the MiSTer environment.

This, currently, is very experimental and does not follow MiSTer conventions / is not a MiSTer core.

The way this works is quite nasty, it kills the MiSTer process, takes over the fpga
launches minicast and re-loads menu.rbf / re-starts MiSTer once done.

### Setup Steps
- Download latest release from [DreamSTer Releases Page](https://github.com/skmp/DreamSTer/releases)
- Extract to the root of your SD card
- put correct bios and flash in games/Dreamcast
- put .cue/.gdi/.cdi files in games/Dreamcast
- Start DreamSTer from Scripts menu

Setup [Video tutorial by Pixel Cherry Ninja](https://youtu.be/r7nzop2nVWg?si=ldTbRYXF_mA8pDR5&t=1152)

### Help needed - We need to test the Dreamcast library
Update issues (or file new ones for games we don't have already). There's an issue template to help you.
