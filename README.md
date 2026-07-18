# DreamSTer
polly2-rtl, minicast and a python TUI rolled together for the MiSTer environment.

This, currently, is very experimental and does not follow MiSTer conventions / is not a MiSTer core.

The way this works is quite nasty, it kills the MiSTer process, takes over the fpga
launches minicast and re-loads menu.rbf / re-starts MiSTer once done.

### Setup Steps
- Download latest release from [DreamSTer Releases Page](https://github.com/skmp/DreamSTer/releases)
- Extract to the root of your MiSTer's SD/microSD card (`/media/fat`)
- Put the correct BIOS and flash files in `games/Dreamcast` on the SD/microSD card
- Put .cue/.gdi/.cdi files on the SD/microSD card, or use an external USB/NVMe drive as described below
- Start DreamSTer from Scripts menu

### External game directories
DreamSTer always loads `dc_boot.bin`, `dc_flash.bin`, and `emu.cfg` from the
SD/microSD card at `/media/fat/games/Dreamcast`.

Leave `Dreamcast.ContentPath` empty in `emu.cfg` to automatically use the
first available `/media/usb*/games/Dreamcast` directory. DreamSTer falls back
to the SD/microSD game directory when no external drive is available. During
the first 30 seconds after boot, an empty SD/microSD library waits briefly for
external USB/NVMe storage to finish mounting.

To choose game directories explicitly, set one or more absolute paths
separated by semicolons:

```ini
[config]
Dreamcast.ContentPath = /media/usb0/games/Dreamcast;/media/usb1/games/Dreamcast
```

All existing configured directories are scanned recursively. Missing or
relative configured paths are ignored; if none are available, automatic
USB/NVMe discovery and then the SD/microSD fallback are used.

Setup [Video tutorial by Pixel Cherry Ninja](https://youtu.be/r7nzop2nVWg?si=ldTbRYXF_mA8pDR5&t=1152)

### Help needed - We need to test the Dreamcast library
[Update issues](https://github.com/skmp/DreamSTer/issues) (or file [new ones](https://github.com/skmp/DreamSTer/issues) for games we don't have already). There's an issue template to help you.
