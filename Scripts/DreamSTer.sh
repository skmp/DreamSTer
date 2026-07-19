#!/usr/bin/env python3
"""DreamSTer Hybrid Core - terminal UI for minicast / polly2-rtl.

Python 3.9 / curses. Scans gane dir for .cdi/.cue/.gdi images,
lets the user tweak emu.cfg and launches minicast on the polly2-rtl bitstream.

The MiSTer main binary is killed as soon as the script starts (so it stops
eating input/video) and is ALWAYS restarted when the script exits, on every
path. Menus navigate from the terminal keyboard (console tty or ssh pty) and
from any configured evdev device: mapped dpad moves, A confirms; leaving
a screen is always an explicit Back/Exit menu entry.
"""

import configparser
import curses
import fcntl
import glob
import os
import re
import select
import signal
import struct
import subprocess
import sys
import time

TITLE = "DreamSTer Hybrid Core"

STORAGE_LOCATIONS = [
    ("sd", "SD Card", "/media/fat/games/Dreamcast"),
    ("usb0", "USB0", "/media/usb0/games/Dreamcast"),
    ("cifs", "CIFS", "/media/fat/cifs/games/Dreamcast"),
]
DC_DIR = STORAGE_LOCATIONS[0][2]
BOOT_BIN = os.path.join(DC_DIR, "dc_boot.bin")
FLASH_BIN = os.path.join(DC_DIR, "dc_flash.bin")
CFG_PATH = os.path.join(DC_DIR, "emu.cfg")


def set_dc_dir(path):
    global DC_DIR, BOOT_BIN, FLASH_BIN, CFG_PATH
    DC_DIR = path
    BOOT_BIN = os.path.join(DC_DIR, "dc_boot.bin")
    FLASH_BIN = os.path.join(DC_DIR, "dc_flash.bin")
    CFG_PATH = os.path.join(DC_DIR, "emu.cfg")



MINICAST_DIR = "/media/fat/minicast"
LOAD_BITSTREAM = os.path.join(MINICAST_DIR, "load_fpga_bitstream")
BITSTREAM_RBF = os.path.join(MINICAST_DIR, "polly2-rtl.rbf")
MEM_WC = os.path.join(MINICAST_DIR, "mem_wc.ko")
SETUP_HDMI = os.path.join(MINICAST_DIR, "setup_hdmi")
MINICAST_ELF = os.path.join(MINICAST_DIR, "minicast.elf")
MISTER_BIN = "/media/fat/MiSTer"
MENU_RBF = "/media/fat/menu.rbf"

GAME_EXTS = (".cdi", ".cue", ".gdi")

KEY_ENTER = (curses.KEY_ENTER, 10, 13)

# There is deliberately NO ESC/B "back" shortcut: a laggy arrow-key escape
# sequence decays into a bare tty ESC, which used to quit menus at random.
# tty ESC (and any other unmapped key) is ignored; every screen navigates
# through explicit Back/Exit menu entries instead.

DEFAULT_CFG = """\
[audio]
backend = auto
disable = 0

[config]
Cloudroms.HideHomebrew = no
Cloudroms.ShowArchiveOrg = no
Debug.SerialConsoleEnabled = no
Debug.VirtualSerialPort = no
Debug.VirtualSerialPortFile =
Dreamcast.Broadcast = 4
Dreamcast.Cable = 0
Dreamcast.ContentPath =
Dreamcast.FullMMU = no
Dreamcast.Language = 6
Dreamcast.Region = 3
Dynarec.DspEnabled = 1
Dynarec.Enabled = yes
Dynarec.ScpuEnabled = 1
Dynarec.SmcCheckLevel = 0
Dynarec.idleskip = yes
Dynarec.safe-mode = yes
Dynarec.unstable-opt = no
SavePopup.isShown = no
Social.HideCallToAction = no
aica.LimitFPS = yes
aica.NoBatch = no
aica.NoSound = no
polly2.AutoReset = no
polly2.ClockSel = 3
pvr.FPSTarget = 66
pvr.ForceGLES2 = no
pvr.MaxThreads = 3
pvr.MultithreadedTA = 1
pvr.SynchronousRendering = no
pvr.backend = auto
rend.Clipping = yes
rend.CustomTextures = no
rend.DumpTextures = no
rend.FloatVMUs = no
rend.Fog = yes
rend.MaxFilteredTextureSize = 256
rend.ModifierVolumes = yes
rend.RenderToTextureBuffer = no
rend.RenderToTextureUpscale = 1
rend.Rotate90 = no
rend.ScreenOrientation = 0
rend.ScreenScaling = 100
rend.ScreenStretching = 100
rend.ShowFPS = no
rend.TextureUpscale = 1
rend.WideScreen = no
ta.skip = 0

[input]
MouseSensitivity = 100
VirtualGamepadVibration = 20
device1 = 0
device1.1 = 1
device1.2 = 1
device2 = 8
device2.1 = 8
device2.2 = 8
device3 = 8
device3.1 = 8
device3.2 = 8
device4 = 8
device4.1 = 8
device4.2 = 8
"""


# ---------------------------------------------------------------- config ---

class Option:
    def __init__(self, label, key, choices, default):
        self.label = label
        self.key = key                 # key inside [config]
        self.choices = choices         # list of (value, display)
        self.default = default

    def current(self, cfg):
        return cfg.get("config", self.key, fallback=self.default)

    def display(self, cfg):
        val = self.current(cfg)
        for v, name in self.choices:
            if v == val:
                return name
        return "? (%s)" % val

    def cycle(self, cfg, direction):
        val = self.current(cfg)
        idx = next((i for i, (v, _) in enumerate(self.choices) if v == val), -1)
        idx = (idx + direction) % len(self.choices)
        if not cfg.has_section("config"):
            cfg.add_section("config")
        cfg.set("config", self.key, self.choices[idx][0])


class AudioOption(Option):
    """Audio mode: [config] aica.LimitFPS + [audio] disable together.

    Synced   = LimitFPS yes, disable 0  (audio FIFO paces the emu)
    Unsynced = LimitFPS no,  disable 0  (drop samples rather than wait)
    Off      = disable 1                (LimitFPS left as-is)

    Values match the DEFAULT_CFG template: aica.LimitFPS is yes/no,
    [audio] disable is 0/1.
    """

    def __init__(self):
        Option.__init__(self, "Audio", "aica.LimitFPS",
                        [("synced", "Synced"), ("unsynced", "Unsynced"),
                         ("off", "Off")], "synced")

    def current(self, cfg):
        if cfg.get("audio", "disable", fallback="0").strip() == "1":
            return "off"
        v = cfg.get("config", self.key, fallback="yes").strip().lower()
        return "synced" if v in ("yes", "true", "on", "1") else "unsynced"

    def cycle(self, cfg, direction):
        val = self.current(cfg)
        idx = next(i for i, (v, _) in enumerate(self.choices) if v == val)
        val = self.choices[(idx + direction) % len(self.choices)][0]
        for section in ("audio", "config"):
            if not cfg.has_section(section):
                cfg.add_section(section)
        cfg.set("audio", "disable", "1" if val == "off" else "0")
        if val != "off":
            cfg.set("config", self.key, "yes" if val == "synced" else "no")


OPTION_GROUPS = [
    ("Console", [
        Option("Cable Mode", "Dreamcast.Cable",
               [("0", "VGA"), ("3", "TV Composite")], "0"),
    ]),
    ("Minicast", [
        Option("Unstable SH4 Optimizations", "Dynarec.unstable-opt",
               [("no", "No"), ("yes", "Yes")], "no"),
        Option("Multithreaded TA", "pvr.MultithreadedTA",
               [("0", "Off"), ("1", "Safe"), ("2", "Full")], "1"),
        Option("FPS Target", "pvr.FPSTarget",
               [("66", "60 FPS"), ("55", "50 FPS"),
                ("33", "30 FPS"), ("28", "25 FPS")], "66"),
        AudioOption(),
    ]),
    ("polly2", [
        Option("AutoReset", "polly2.AutoReset",
               [("no", "No"), ("yes", "Yes")], "no"),
        Option("Clock", "polly2.ClockSel",
               [("3", "112 MHz"), ("0", "75 MHz"),
                ("1", "90 MHz"), ("2", "100 MHz")], "3"),
    ]),
]


def load_cfg():
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str  # preserve key case
    if os.path.isfile(CFG_PATH):
        try:
            cfg.read(CFG_PATH)
        except configparser.Error:
            pass
    else:
        try:
            with open(CFG_PATH, "w") as f:
                f.write(DEFAULT_CFG)
        except OSError:
            pass
        cfg.read_string(DEFAULT_CFG)
    if not cfg.has_section("config"):
        cfg.add_section("config")
    return cfg


def save_cfg(cfg):
    try:
        with open(CFG_PATH, "w") as f:
            cfg.write(f)
    except OSError:
        pass


# ----------------------------------------------------------------- games ---

def scan_games():
    games = []
    for root, dirs, files in os.walk(DC_DIR):
        dirs.sort()
        for name in sorted(files):
            if name.lower().endswith(GAME_EXTS):
                path = os.path.join(root, name)
                games.append((os.path.relpath(path, DC_DIR), path))
    games.sort(key=lambda g: g[0].lower())
    return games


# ---------------------------------------------------------- input mapper ---
# evdev access is stdlib-only (raw ioctls); works on 32-bit ARM MiSTer.

CAPTURE_SECONDS = 5

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03

EVENT_FMT = "llHHi"  # struct input_event (native long timeval)
EVENT_SIZE = struct.calcsize(EVENT_FMT)


def _ioc_read(nr, size):
    return (2 << 30) | (size << 16) | (ord("E") << 8) | nr


EVIOCGID = _ioc_read(0x02, 8)


def EVIOCGNAME(length):
    return _ioc_read(0x06, length)


def EVIOCGUNIQ(length):
    return _ioc_read(0x08, length)


def EVIOCGBIT(ev, length):
    return _ioc_read(0x20 + ev, length)


def EVIOCGABS(code):
    return _ioc_read(0x40 + code, 24)


def test_bit(buf, bit):
    return bool(buf[bit // 8] >> (bit % 8) & 1)


KEY_NAMES = {}
for _i, _c in enumerate("1234567890"):
    KEY_NAMES[2 + _i] = "KEY_" + _c
for _i, _c in enumerate("QWERTYUIOP"):
    KEY_NAMES[16 + _i] = "KEY_" + _c
for _i, _c in enumerate("ASDFGHJKL"):
    KEY_NAMES[30 + _i] = "KEY_" + _c
for _i, _c in enumerate("ZXCVBNM"):
    KEY_NAMES[44 + _i] = "KEY_" + _c
for _i in range(10):
    KEY_NAMES[59 + _i] = "KEY_F%d" % (_i + 1)
KEY_NAMES.update({
    1: "KEY_ESC", 14: "KEY_BACKSPACE", 15: "KEY_TAB", 28: "KEY_ENTER",
    29: "KEY_LEFTCTRL", 42: "KEY_LEFTSHIFT", 54: "KEY_RIGHTSHIFT",
    56: "KEY_LEFTALT", 57: "KEY_SPACE", 58: "KEY_CAPSLOCK",
    97: "KEY_RIGHTCTRL", 100: "KEY_RIGHTALT",
    102: "KEY_HOME", 103: "KEY_UP", 104: "KEY_PAGEUP", 105: "KEY_LEFT",
    106: "KEY_RIGHT", 107: "KEY_END", 108: "KEY_DOWN", 109: "KEY_PAGEDOWN",
    110: "KEY_INSERT", 111: "KEY_DELETE",
    0x110: "BTN_LEFT", 0x111: "BTN_RIGHT", 0x112: "BTN_MIDDLE",
    0x113: "BTN_SIDE", 0x114: "BTN_EXTRA",
    0x120: "BTN_TRIGGER", 0x121: "BTN_THUMB", 0x122: "BTN_THUMB2",
    0x123: "BTN_TOP", 0x124: "BTN_TOP2", 0x125: "BTN_PINKIE",
    0x126: "BTN_BASE", 0x127: "BTN_BASE2", 0x128: "BTN_BASE3",
    0x129: "BTN_BASE4", 0x12a: "BTN_BASE5", 0x12b: "BTN_BASE6",
    0x130: "BTN_SOUTH(A)", 0x131: "BTN_EAST(B)", 0x133: "BTN_NORTH(X)",
    0x134: "BTN_WEST(Y)", 0x135: "BTN_Z", 0x136: "BTN_TL", 0x137: "BTN_TR",
    0x138: "BTN_TL2", 0x139: "BTN_TR2", 0x13a: "BTN_SELECT",
    0x13b: "BTN_START", 0x13c: "BTN_MODE", 0x13d: "BTN_THUMBL",
    0x13e: "BTN_THUMBR",
    0x220: "BTN_DPAD_UP", 0x221: "BTN_DPAD_DOWN", 0x222: "BTN_DPAD_LEFT",
    0x223: "BTN_DPAD_RIGHT",
})

ABS_NAMES = {
    0: "ABS_X", 1: "ABS_Y", 2: "ABS_Z", 3: "ABS_RX", 4: "ABS_RY",
    5: "ABS_RZ", 6: "ABS_THROTTLE", 7: "ABS_RUDDER", 8: "ABS_WHEEL",
    9: "ABS_GAS", 10: "ABS_BRAKE",
    16: "ABS_HAT0X", 17: "ABS_HAT0Y", 18: "ABS_HAT1X", 19: "ABS_HAT1Y",
    20: "ABS_HAT2X", 21: "ABS_HAT2Y", 22: "ABS_HAT3X", 23: "ABS_HAT3Y",
}

REL_NAMES = {
    0: "REL_X", 1: "REL_Y", 2: "REL_Z", 6: "REL_HWHEEL", 7: "REL_DIAL",
    8: "REL_WHEEL", 11: "REL_WHEEL_HI_RES", 12: "REL_HWHEEL_HI_RES",
}


def key_name(code):
    return KEY_NAMES.get(code, "KEY_%d" % code)


def abs_name(code):
    return ABS_NAMES.get(code, "ABS_%d" % code)


def rel_name(code):
    return REL_NAMES.get(code, "REL_%d" % code)


class Device:
    def __init__(self, path):
        self.path = path
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            raw = fcntl.ioctl(fd, EVIOCGNAME(256), b"\0" * 256)
            self.name = raw.split(b"\0", 1)[0].decode(errors="replace") or "?"

            bus, vid, pid, ver = struct.unpack(
                "HHHH", fcntl.ioctl(fd, EVIOCGID, b"\0" * 8))
            self.id = "%04x:%04x:%04x:%04x" % (bus, vid, pid, ver)
            try:
                raw = fcntl.ioctl(fd, EVIOCGUNIQ(64), b"\0" * 64)
                uniq = raw.split(b"\0", 1)[0].decode(errors="replace")
                if uniq:
                    self.id += ":" + uniq
            except OSError:
                pass

            ev = fcntl.ioctl(fd, EVIOCGBIT(0, 8), b"\0" * 8)
            self.has_key = test_bit(ev, EV_KEY)
            self.has_rel = test_bit(ev, EV_REL)
            self.has_abs = test_bit(ev, EV_ABS)

            self.abs_codes = []
            if self.has_abs:
                bits = fcntl.ioctl(fd, EVIOCGBIT(EV_ABS, 8), b"\0" * 8)
                self.abs_codes = [c for c in range(64) if test_bit(bits, c)]

            keybits = b""
            if self.has_key:
                keybits = fcntl.ioctl(fd, EVIOCGBIT(EV_KEY, 96), b"\0" * 96)

            if self.has_abs and keybits and (test_bit(keybits, 0x130)
                                             or test_bit(keybits, 0x120)):
                self.kind = "gamepad"
            elif self.has_rel or (keybits and (test_bit(keybits, 0x110)
                                               or test_bit(keybits, 0x14a))):
                # relative mice, or absolute pointers (BTN_LEFT/BTN_TOUCH):
                # tablets, touchpads, KVM-style absolute mice
                self.kind = "mouse"
            elif keybits and test_bit(keybits, 30):  # KEY_A
                self.kind = "keyboard"
            else:
                self.kind = "other"
        finally:
            os.close(fd)


def scan_devices():
    devs = []
    paths = sorted(glob.glob("/dev/input/event*"),
                   key=lambda p: int("".join(filter(str.isdigit, p)) or "0"))
    seen = {}
    for path in paths:
        try:
            dev = Device(path)
        except OSError:
            continue
        n = seen.get(dev.id, 0)
        seen[dev.id] = n + 1
        if n:  # two identical devices with no unique id
            dev.id += "#%d" % (n + 1)
        devs.append(dev)
    return devs


def read_absinfo(fd, code):
    """Returns (value, min, max, fuzz, flat, resolution)."""
    raw = fcntl.ioctl(fd, EVIOCGABS(code), b"\0" * 24)
    return struct.unpack("6i", raw)


def read_events(fd):
    """Returns list of (type, code, value), or None if the device is gone."""
    try:
        data = os.read(fd, EVENT_SIZE * 64)
    except (BlockingIOError, InterruptedError):
        return []
    except OSError:
        return None
    out = []
    for off in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
        _, _, etype, code, value = struct.unpack_from(EVENT_FMT, data, off)
        out.append((etype, code, value))
    return out


def drain(fd):
    while True:
        try:
            if not os.read(fd, 4096):
                return
        except OSError:
            return


# device id -> {target key -> mapping dict}. A device with no entry uses
# the per-kind defaults below; an explicit empty dict (after "Remove
# configuration") means inactive. Persisted in emu.cfg [input0]..[inputN].
CONFIG = {}

TARGETS = [
    ("dpad_up", "Dpad Up"),
    ("dpad_down", "Dpad Down"),
    ("dpad_left", "Dpad Left"),
    ("dpad_right", "Dpad Right"),
    ("btn_a", "Button A"),
    ("btn_b", "Button B"),
    ("btn_x", "Button X"),
    ("btn_y", "Button Y"),
    ("btn_start", "Button Start"),
    ("analog_x", "Analog X  (-127..127)"),
    ("analog_y", "Analog Y  (-127..127)"),
    ("trig_l", "Trigger Left  (0..255)"),
    ("trig_r", "Trigger Right (0..255)"),
]

# capture prompts name the direction to actuate. For the analog axes the
# prompted direction is the NEGATIVE end of the DC axis (left/up negative),
# so an axis capture flips the detected sign to point the mapping there and
# a key capture becomes the negative keypair half (positive asked second).
CAPTURE_PROMPTS = {
    "dpad_up": "Move Up",
    "dpad_down": "Move Down",
    "dpad_left": "Move Left",
    "dpad_right": "Move Right",
    "analog_x": "Move Left",
    "analog_y": "Move Up",
}
ANALOG_POS_PROMPTS = {"analog_x": "Move Right", "analog_y": "Move Down"}

# emu.cfg key per target, in file order
TARGET_CFG_KEYS = [
    ("dpad_up", "DpadUp"),
    ("dpad_down", "DpadDown"),
    ("dpad_left", "DpadLeft"),
    ("dpad_right", "DpadRight"),
    ("btn_a", "ButtonA"),
    ("btn_b", "ButtonB"),
    ("btn_x", "ButtonX"),
    ("btn_y", "ButtonY"),
    ("btn_start", "ButtonStart"),
    ("analog_x", "AxisX"),
    ("analog_y", "AxisY"),
    ("trig_l", "TriggerL"),
    ("trig_r", "TriggerR"),
]


def _key(code):
    return {"kind": "key", "code": code}


def _abs(code, direction):
    return {"kind": "abs", "code": code, "dir": direction}


def _rel(code, direction):
    return {"kind": "rel", "code": code, "dir": direction}


# Defaults follow minicast/main.cpp: js0 buttons 0/1/2/3 + start 10 and
# axes 0/1 (stick), 2/5 (triggers), 6/7 (dpad) translated to evdev codes;
# keyboard uses the (commented-out) kbhit() map. Mice: motion -> analog,
# left/right click -> A/B.
DEFAULTS = {
    "gamepad": {
        "dpad_up": _abs(17, -1),     # ABS_HAT0Y
        "dpad_down": _abs(17, 1),
        "dpad_left": _abs(16, -1),   # ABS_HAT0X
        "dpad_right": _abs(16, 1),
        "btn_a": _key(0x130),        # BTN_SOUTH
        "btn_b": _key(0x131),        # BTN_EAST
        "btn_x": _key(0x133),        # BTN_NORTH
        "btn_y": _key(0x134),        # BTN_WEST
        "btn_start": _key(0x13b),    # BTN_START
        "analog_x": _abs(0, 1),      # ABS_X
        "analog_y": _abs(1, 1),      # ABS_Y
        "trig_l": _abs(2, 1),        # ABS_Z
        "trig_r": _abs(5, 1),        # ABS_RZ
    },
    "keyboard": {
        "dpad_up": _key(23),         # I
        "dpad_down": _key(37),       # K
        "dpad_left": _key(36),       # J
        "dpad_right": _key(38),      # L
        "btn_a": _key(30),           # A
        "btn_b": _key(45),           # X
        "btn_x": _key(46),           # C
        "btn_y": _key(47),           # V
        "btn_start": _key(31),       # S
        "analog_x": {"kind": "keypair", "neg": 33, "pos": 35},  # F / H
        "analog_y": {"kind": "keypair", "neg": 20, "pos": 34},  # T / G
        "trig_l": _key(18),          # E
        "trig_r": _key(19),          # R
    },
    "mouse": {
        "analog_x": _rel(0, 1),      # REL_X
        "analog_y": _rel(1, 1),      # REL_Y
        "btn_a": _key(0x110),        # BTN_LEFT
        "btn_b": _key(0x111),        # BTN_RIGHT
    },
}


def default_config(dev):
    return DEFAULTS.get(dev.kind, {})


def effective_config(dev):
    if dev.id in CONFIG:
        return CONFIG[dev.id]
    return default_config(dev)


def mapping_text(m):
    if m is None:
        return "-"
    if m["kind"] == "key":
        return key_name(m["code"])
    if m["kind"] == "keypair":
        neg = key_name(m["neg"]) if m["neg"] is not None else "-"
        pos = key_name(m["pos"]) if m["pos"] is not None else "-"
        return "%s / %s" % (neg, pos)
    if m["kind"] == "abs":
        return "%s %s" % (abs_name(m["code"]), "+" if m["dir"] > 0 else "-")
    return "%s %s" % (rel_name(m["code"]), "+" if m["dir"] > 0 else "-")


# Map values are colon-separated for easy C++ parsing:
#   key:<code>              button/key press
#   keys:<neg>:<pos>        key pair driving an axis (-1 = unset)
#   abs:<code>:<dir>        absolute axis, dir 1 or -1
#   rel:<code>:<dir>        relative axis (mouse motion)

def encode_mapping(m):
    if m["kind"] == "key":
        return "key:%d" % m["code"]
    if m["kind"] == "keypair":
        return "keys:%d:%d" % (m["neg"] if m["neg"] is not None else -1,
                               m["pos"] if m["pos"] is not None else -1)
    if m["kind"] == "abs":
        return "abs:%d:%d" % (m["code"], m["dir"])
    return "rel:%d:%d" % (m["code"], m["dir"])


def decode_mapping(text):
    parts = text.strip().split(":")
    try:
        if parts[0] == "key" and len(parts) == 2:
            return {"kind": "key", "code": int(parts[1])}
        if parts[0] == "keys" and len(parts) == 3:
            neg, pos = int(parts[1]), int(parts[2])
            return {"kind": "keypair",
                    "neg": neg if neg >= 0 else None,
                    "pos": pos if pos >= 0 else None}
        if parts[0] == "abs" and len(parts) == 3:
            return {"kind": "abs", "code": int(parts[1]),
                    "dir": 1 if int(parts[2]) >= 0 else -1}
        if parts[0] == "rel" and len(parts) == 3:
            return {"kind": "rel", "code": int(parts[1]),
                    "dir": 1 if int(parts[2]) >= 0 else -1}
    except ValueError:
        pass
    return None


def load_input_config(cfg):
    """Populates CONFIG from the shared emu.cfg parser."""
    for section in cfg.sections():
        if not re.match(r"input\d+$", section):
            continue
        dev_id = cfg.get(section, "DeviceId", fallback="")
        if not dev_id:
            continue
        mappings = {}
        for target, cfg_key in TARGET_CFG_KEYS:
            val = cfg.get(section, cfg_key, fallback=None)
            if val:
                m = decode_mapping(val)
                if m is not None:
                    mappings[target] = m
        # a DeviceId-only section is an explicitly cleared device
        CONFIG[dev_id] = mappings


def save_input_config(cfg, devices):
    """Rewrites [input0]..[inputN] in the shared emu.cfg parser and saves.
    Returns the number of device sections written."""
    # materialize defaults for connected devices so the C++ side only
    # ever needs emu.cfg
    for dev in devices:
        if dev.id not in CONFIG:
            defaults = default_config(dev)
            if defaults:
                CONFIG[dev.id] = dict(defaults)

    for section in list(cfg.sections()):
        if re.match(r"input\d+$", section):
            cfg.remove_section(section)
    n = 0
    for dev_id, mappings in CONFIG.items():
        section = "input%d" % n
        cfg.add_section(section)
        cfg.set(section, "DeviceId", dev_id)
        for target, cfg_key in TARGET_CFG_KEYS:
            m = mappings.get(target)
            if m is not None:
                cfg.set(section, cfg_key, encode_mapping(m))
        n += 1
    save_cfg(cfg)
    return n


class InputDetector:
    """Reports the first significant input (ignoring axis deadzone noise)."""

    REL_THRESH = {0: 15, 1: 15}  # REL_X/REL_Y need real motion; wheels: 1

    def __init__(self, fd, dev):
        self.fd = fd
        self.abs_info = {}
        self.abs_base = {}
        for code in dev.abs_codes:
            try:
                info = read_absinfo(fd, code)
            except OSError:
                continue
            self.abs_info[code] = info
            self.abs_base[code] = info[0]
        self.rel_accum = {}

    def check(self, etype, code, value):
        """Returns a mapping dict once a significant input is seen."""
        if etype == EV_KEY and value == 1:
            return {"kind": "key", "code": code}
        if etype == EV_ABS:
            info = self.abs_info.get(code)
            if info is None:
                try:
                    info = read_absinfo(self.fd, code)
                except OSError:
                    return None
                self.abs_info[code] = info
                self.abs_base[code] = info[0]
            delta = value - self.abs_base[code]
            thresh = max(1, (info[2] - info[1]) * 0.2)
            if abs(delta) >= thresh:
                return {"kind": "abs", "code": code,
                        "dir": 1 if delta > 0 else -1,
                        "min": info[1], "max": info[2]}
        if etype == EV_REL:
            acc = self.rel_accum.get(code, 0) + value
            self.rel_accum[code] = acc
            if abs(acc) >= self.REL_THRESH.get(code, 1):
                return {"kind": "rel", "code": code,
                        "dir": 1 if acc > 0 else -1}
        return None


def capture_mapping(scr, dev, render, prompt="Waiting"):
    """Waits up to CAPTURE_SECONDS for input on dev; returns mapping or None.

    render(text) redraws the screen with the countdown on the selected row.
    """
    try:
        fd = os.open(dev.path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        render("[error: cannot open device]")
        scr.refresh()
        time.sleep(1.0)
        return None
    try:
        drain(fd)
        det = InputDetector(fd, dev)
        scr.nodelay(True)
        deadline = time.monotonic() + CAPTURE_SECONDS
        while True:
            now = time.monotonic()
            if now >= deadline:
                return None
            remaining = int(deadline - now) + 1  # CAPTURE_SECONDS .. 1
            text = "[" + prompt + " ... " + "...".join(
                str(n) for n in range(CAPTURE_SECONDS, remaining - 1, -1)) + "]"
            render(text)
            scr.refresh()
            scr.getch()   # drain tty so captured keys don't leak into menus
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            evs = read_events(fd)
            if evs is None:
                return None
            for etype, code, value in evs:
                m = det.check(etype, code, value)
                if m:
                    return m
    finally:
        scr.nodelay(False)
        os.close(fd)


class DCState:
    """Applies a device's mappings to its events -> Dreamcast pad state."""

    REL_GAIN = 4.0        # mouse counts -> analog deflection

    def __init__(self, dev, fd):
        self.dev = dev
        self.cfg = effective_config(dev)
        self.absrange = {}
        for code in dev.abs_codes:
            try:
                info = read_absinfo(fd, code)
                self.absrange[code] = (info[1], info[2])
            except OSError:
                pass
        self.buttons = set()  # dpad_*/btn_* targets currently held
        self.analog = {"analog_x": 0, "analog_y": 0}
        self.trig = {"trig_l": 0, "trig_r": 0}
        self.kp = {}          # keypair target -> [neg held, pos held]
        self.rel_accum = {}   # rel-driven analog target -> float
        self.by_key = {}
        self.by_abs = {}
        self.by_rel = {}
        for target, m in self.cfg.items():
            if m["kind"] == "key":
                self.by_key.setdefault(m["code"], []).append((target, None))
            elif m["kind"] == "keypair":
                if m["neg"] is not None:
                    self.by_key.setdefault(m["neg"], []).append((target, 0))
                if m["pos"] is not None:
                    self.by_key.setdefault(m["pos"], []).append((target, 1))
            elif m["kind"] == "abs":
                self.by_abs.setdefault(m["code"], []).append((target, m))
            elif m["kind"] == "rel":
                self.by_rel.setdefault(m["code"], []).append((target, m))
                self.rel_accum[target] = 0.0

    def feed(self, etype, code, value):
        if etype == EV_KEY:
            for target, side in self.by_key.get(code, []):
                if side is not None:  # keypair half driving an analog axis
                    st = self.kp.setdefault(target, [False, False])
                    st[side] = bool(value)
                    self.analog[target] = (-128 if st[0] else
                                           (127 if st[1] else 0))
                elif target in self.trig:
                    self.trig[target] = 255 if value else 0
                else:
                    if value:
                        self.buttons.add(target)
                    else:
                        self.buttons.discard(target)
        elif etype == EV_ABS:
            for target, m in self.by_abs.get(code, []):
                lo, hi = m.get("min"), m.get("max")
                if lo is None or hi is None or hi <= lo:
                    lo, hi = self.absrange.get(code, (-32768, 32767))
                if hi <= lo:
                    continue
                norm = (value - lo) / float(hi - lo) * 2.0 - 1.0  # -1..1
                if m["dir"] < 0:
                    norm = -norm
                if target in self.analog:
                    self.analog[target] = max(-127, min(127,
                                                        int(round(norm * 127))))
                elif target in self.trig:
                    self.trig[target] = max(0, min(255,
                                                   int(round((norm + 1)
                                                             / 2 * 255))))
                elif norm > 0.5:
                    self.buttons.add(target)
                else:
                    self.buttons.discard(target)
        elif etype == EV_REL:
            for target, m in self.by_rel.get(code, []):
                if target in self.analog:
                    self.rel_accum[target] += value * m["dir"] * self.REL_GAIN

    def tick(self):
        # mouse deflection decays back to center when motion stops
        for target in self.rel_accum:
            acc = self.rel_accum[target]
            self.analog[target] = max(-127, min(127, int(acc)))
            self.rel_accum[target] = acc * 0.8 if abs(acc) >= 1.0 else 0.0


# --------------------------------------------------------- evdev menu nav ---
# Menu navigation from configured evdev devices: the mapped dpad moves the
# cursor, A confirms (ENTER). Keyboard-kind devices are
# deliberately NOT read here: their input already arrives through the
# terminal (console tty locally, pty over ssh), so reading them from evdev
# too would process every key twice. Gamepads/mice produce no tty input, so
# evdev is their only path - no double handling either way, and no exclusive
# grabs needed (MiSTer, the other evdev reader, is killed on script entry).

NAV_KEYS = {
    "dpad_up": curses.KEY_UP,
    "dpad_down": curses.KEY_DOWN,
    "dpad_left": curses.KEY_LEFT,
    "dpad_right": curses.KEY_RIGHT,
    "btn_a": 10,        # confirm / enter
}
NAV_REPEAT = ("dpad_up", "dpad_down", "dpad_left", "dpad_right")
NAV_REPEAT_DELAY = 0.40
NAV_REPEAT_RATE = 0.11


class NavPump:
    """Translates mapped dpad/A/B presses on non-keyboard evdevs into keys."""

    def __init__(self):
        self.states = {}  # fd -> DCState
        self.queue = []   # pending key codes
        self.held = {}    # (fd, target) -> next auto-repeat time
        for dev in scan_devices():
            if dev.kind == "keyboard":
                continue
            if not any(t in effective_config(dev) for t in NAV_KEYS):
                continue
            try:
                fd = os.open(dev.path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            drain(fd)
            self.states[fd] = DCState(dev, fd)

    def close(self):
        for fd in self.states:
            os.close(fd)
        self.states = {}
        self.queue = []
        self.held = {}

    def fds(self):
        return list(self.states)

    def pump(self):
        now = time.monotonic()
        for fd in list(self.states):
            st = self.states[fd]
            evs = read_events(fd)
            if evs is None:  # device unplugged
                os.close(fd)
                del self.states[fd]
                continue
            if not evs:
                continue
            before = set(st.buttons)
            for etype, code, value in evs:
                st.feed(etype, code, value)
            for target in st.buttons - before:
                if target in NAV_KEYS:
                    self.queue.append(NAV_KEYS[target])
                    if target in NAV_REPEAT:
                        self.held[(fd, target)] = now + NAV_REPEAT_DELAY
        for key in list(self.held):
            fd, target = key
            st = self.states.get(fd)
            if st is None or target not in st.buttons:
                del self.held[key]
            elif now >= self.held[key]:
                self.queue.append(NAV_KEYS[target])
                self.held[key] = now + NAV_REPEAT_RATE

    def next_key(self):
        self.pump()
        if self.queue:
            return self.queue.pop(0)
        return None

    def flush(self):
        """Discards pending nav input (after test/capture screens, where the
        same physical presses were consumed by a different reader)."""
        self.pump()
        self.queue = []
        self.held = {}


NAV = [None]  # active NavPump; rebuilt when mappings change


def nav_flush():
    if NAV[0] is not None:
        NAV[0].flush()


def nav_getch(scr):
    """Blocking scr.getch() that also accepts evdev navigation input."""
    nav = NAV[0]
    while True:
        if nav is not None:
            ch = nav.next_key()
            if ch is not None:
                return ch
        rl = [0] + (nav.fds() if nav else [])
        timeout = 0.05 if (nav and nav.held) else 1.0
        try:
            r, _, _ = select.select(rl, [], [], timeout)
        except OSError:
            r = []
        # 60ms window lets terminal escape sequences complete; a plain poll
        # (timeout 0) otherwise, which also harvests pending KEY_RESIZE
        scr.timeout(60 if 0 in r else 0)
        ch = scr.getch()
        scr.timeout(-1)
        if ch != -1:
            return ch


def draw_tokens(scr, y, x, tokens):
    """tokens: (text, None=label / False=idle / True=pressed)."""
    for text, state in tokens:
        if state is None:
            safe_addstr(scr, y, x, text, color(C_DIM))
        elif state:
            safe_addstr(scr, y, x, text, color(C_SEL, curses.A_BOLD))
        else:
            safe_addstr(scr, y, x, text)
        x += len(text) + 1
    return x


def test_screen(scr, devices, subtitle):
    """Live view of the mapped Dreamcast pad state, per device."""
    fds = {}
    states = {}
    for dev in devices:
        try:
            fd = os.open(dev.path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        drain(fd)
        fds[fd] = dev
        states[fd] = DCState(dev, fd)
    scr.nodelay(True)
    top = 0
    # the only exits are the pinned Back entry (tty ENTER) or a fresh A
    # press on a device; armed per-device only after A is first seen
    # released, so the press that opened this screen can't exit it
    a_prev = {}  # fd -> btn_a held on the previous pump
    try:
        while True:
            ch = scr.getch()
            if ch in KEY_ENTER:
                return
            if ch == curses.KEY_UP:
                top -= 1
            elif ch == curses.KEY_DOWN:
                top += 1
            if fds:
                r, _, _ = select.select(list(fds), [], [], 0.05)
                for fd in r:
                    evs = read_events(fd)
                    if evs is None:
                        os.close(fd)
                        del states[fd]
                        del fds[fd]
                        a_prev.pop(fd, None)
                        continue
                    for etype, code, value in evs:
                        states[fd].feed(etype, code, value)
            else:
                time.sleep(0.05)
            for st in states.values():
                st.tick()

            for fd, st in states.items():
                a_now = "btn_a" in st.buttons
                if a_now and not a_prev.get(fd, True):
                    return
                a_prev[fd] = a_now

            draw_title(scr, subtitle)
            h, _ = scr.getmaxyx()
            safe_addstr(scr, 3, 2, "> Back", color(C_SEL, curses.A_BOLD))
            list_top = 5
            list_h = max(1, h - list_top - 2)
            total = sum(3 if not states[fd].cfg else 4 for fd in fds)
            top = max(0, min(top, max(0, total - list_h)))

            def put(yv, x, text, attr=0):
                y = list_top + yv - top
                if list_top <= y < list_top + list_h:
                    safe_addstr(scr, y, x, text, attr)

            yv = 0
            for fd, dev in list(fds.items()):
                st = states[fd]
                put(yv, 2, dev.name[:44], curses.A_BOLD)
                put(yv, 2 + min(44, len(dev.name)) + 2,
                    "[%s]" % dev.id, color(C_DIM))
                yv += 1
                if not st.cfg:
                    put(yv, 4, "(no mappings)", color(C_DIM))
                    yv += 2
                    continue
                y = list_top + yv - top
                if list_top <= y < list_top + list_h:
                    draw_tokens(scr, y, 4, [
                        ("Dpad:", None),
                        ("UP", "dpad_up" in st.buttons),
                        ("DOWN", "dpad_down" in st.buttons),
                        ("LEFT", "dpad_left" in st.buttons),
                        ("RIGHT", "dpad_right" in st.buttons),
                        ("  Buttons:", None),
                        ("A", "btn_a" in st.buttons),
                        ("B", "btn_b" in st.buttons),
                        ("X", "btn_x" in st.buttons),
                        ("Y", "btn_y" in st.buttons),
                        ("START", "btn_start" in st.buttons),
                    ])
                yv += 1
                put(yv, 4,
                    "Analog X:%+4d Y:%+4d    Trigger L:%3d R:%3d"
                    % (st.analog["analog_x"], st.analog["analog_y"],
                       st.trig["trig_l"], st.trig["trig_r"]),
                    color(C_VALUE))
                yv += 2
            safe_addstr(scr, h - 1, 1,
                        "Press buttons / move axes   UP/DOWN: scroll   "
                        "ENTER/A: back", color(C_DIM))
            scr.refresh()
    finally:
        scr.nodelay(False)
        for fd in fds:
            os.close(fd)


def device_list_screen(scr, devices, cfg):
    """Returns ("test", None), ("open", dev), or None to exit."""
    rows = [("back", None),
            ("header", "General"),
            ("test", None),
            ("save", None),
            ("header", "Input Devices")]
    rows += [("dev", d) for d in devices]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0
    top = 0
    notice = ""
    notice_attr = 0
    while True:
        draw_title(scr, "%d input device(s)" % len(devices))
        h, w = scr.getmaxyx()
        list_top = 4
        list_h = max(1, h - list_top - 3)

        cur = selectable[sel]
        if cur < top:
            top = cur
        if cur >= top + list_h:
            top = cur - list_h + 1
        top = max(0, min(top, max(0, len(rows) - list_h)))

        for i in range(top, min(len(rows), top + list_h)):
            kind, payload = rows[i]
            y = list_top + (i - top)
            if kind == "header":
                safe_addstr(scr, y, 2, "[ %s ]" % payload,
                            color(C_HEADER, curses.A_BOLD))
                continue
            if kind == "back":
                text = "Back"
            elif kind == "test":
                text = "Test (all devices)"
            elif kind == "save":
                text = "Save Changes"
            else:
                active = "[Active]" if effective_config(payload) else ""
                text = "%-32s %-10s %s  %s" % (payload.name[:32],
                                               payload.kind,
                                               "[%s]" % payload.id, active)
            if i == cur:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_SEL))
                safe_addstr(scr, y, 2, "> " + text, color(C_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, text)

        if notice:
            safe_addstr(scr, h - 2, 1, notice, notice_attr)
        footer = "UP/DOWN: select   ENTER/A: open"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        ch = nav_getch(scr)
        notice = ""
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER:
            kind, payload = rows[selectable[sel]]
            if kind == "back":
                return None
            if kind == "save":
                n = save_input_config(cfg, devices)
                notice = "Saved %d device config(s) to %s" % (n, CFG_PATH)
                notice_attr = color(C_VALUE)
                continue
            return (kind, payload)


def device_screen(scr, dev):
    # rows: ("back",), ("test",), ("header", text), ("map", key, label),
    #       ("remove",)
    rows = [("back",), ("header", "General"), ("test",),
            ("header", "Mappings")]
    rows += [("map", key, label) for key, label in TARGETS]
    rows += [("header", "Danger Zone"), ("remove",)]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0
    top = 0

    def draw(capture_idx=None, capture_text=""):
        nonlocal top
        draw_title(scr, dev.name)
        h, w = scr.getmaxyx()
        safe_addstr(scr, 3, 2, "ID:   %s" % dev.id, color(C_DIM))
        safe_addstr(scr, 4, 2, "Path: %s  (%s)" % (dev.path, dev.kind),
                    color(C_DIM))
        list_top = 6
        list_h = max(1, h - list_top - 2)
        cur = selectable[sel]
        if cur < top:
            top = cur
        if cur >= top + list_h:
            top = cur - list_h + 1
        top = max(0, min(top, max(0, len(rows) - list_h)))
        mappings = effective_config(dev)
        for i in range(top, min(len(rows), top + list_h)):
            row = rows[i]
            y = list_top + (i - top)
            is_sel = (selectable[sel] == i)
            if row[0] == "header":
                if row[1]:
                    safe_addstr(scr, y, 2, "[ %s ]" % row[1],
                                color(C_HEADER, curses.A_BOLD))
                continue
            if row[0] == "back":
                text = "Back"
                value = ""
            elif row[0] == "test":
                text = "Test this device"
                value = ""
            elif row[0] == "remove":
                text = "Remove configuration"
                value = ""
            else:
                text = "%-26s" % row[2]
                value = mapping_text(mappings.get(row[1]))
                if i == capture_idx:
                    value = capture_text
            if is_sel:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_SEL))
                safe_addstr(scr, y, 2, "> " + text, color(C_SEL, curses.A_BOLD))
                safe_addstr(scr, y, 6 + len(text) + 2, value,
                            color(C_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, text)
                safe_addstr(scr, y, 6 + len(text) + 2, value, color(C_VALUE))
        footer = "UP/DOWN: select   ENTER/A: map/activate"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))

    while True:
        draw()
        scr.refresh()

        ch = nav_getch(scr)
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER:
            idx = selectable[sel]
            row = rows[idx]
            if row[0] == "back":
                return
            if row[0] == "test":
                test_screen(scr, [dev], "Testing: %s" % dev.name)
                nav_flush()
            elif row[0] == "remove":
                # explicit empty config: overrides the per-kind defaults
                CONFIG[dev.id] = {}
            else:  # map
                target = row[1]
                m = capture_mapping(
                    scr, dev,
                    lambda text: draw(capture_idx=idx, capture_text=text),
                    prompt=CAPTURE_PROMPTS.get(target, "Waiting"))
                if m is not None:
                    if target in ANALOG_POS_PROMPTS:
                        if m["kind"] == "key":
                            # that key is the negative (left/up) half of the
                            # axis; now capture the positive one
                            m2 = capture_mapping(
                                scr, dev,
                                lambda text: draw(capture_idx=idx,
                                                  capture_text=text),
                                prompt=ANALOG_POS_PROMPTS[target])
                            pos = (m2["code"]
                                   if m2 is not None and m2["kind"] == "key"
                                   else None)
                            m = {"kind": "keypair", "neg": m["code"],
                                 "pos": pos}
                        else:
                            # the prompted move (left/up) is the negative end
                            # of the DC axis: point the mapping the other way
                            m["dir"] = -m["dir"]
                    if dev.id not in CONFIG:
                        CONFIG[dev.id] = dict(effective_config(dev))
                    CONFIG[dev.id][target] = m
                nav_flush()  # the captured press also landed in the nav fds


def input_mapper(scr, cfg):
    """Input configuration UI. Returns when the user backs out."""
    while True:
        devices = scan_devices()
        res = device_list_screen(scr, devices, cfg)
        if res is None:
            return
        kind, dev = res
        if kind == "test":
            test_screen(scr, devices, "Testing all devices")
            nav_flush()
        else:
            device_screen(scr, dev)


# -------------------------------------------------------------- curses ui ---

C_TITLE = 1
C_ERROR = 2
C_SEL = 3
C_HEADER = 4
C_DIM = 5
C_VALUE = 6


def init_colors():
    if not curses.has_colors():
        return
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(C_TITLE, curses.COLOR_CYAN, -1)
    curses.init_pair(C_ERROR, curses.COLOR_RED, -1)
    curses.init_pair(C_SEL, curses.COLOR_BLACK, curses.COLOR_WHITE)
    curses.init_pair(C_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(C_DIM, curses.COLOR_WHITE, -1)
    curses.init_pair(C_VALUE, curses.COLOR_GREEN, -1)


def color(pair, extra=0):
    if curses.has_colors():
        return curses.color_pair(pair) | extra
    return extra


def safe_addstr(scr, y, x, text, attr=0):
    h, w = scr.getmaxyx()
    if y < 0 or y >= h or x >= w:
        return
    try:
        scr.addstr(y, x, text[: max(0, w - x - 1)], attr)
    except curses.error:
        pass


def draw_title(scr, subtitle=""):
    _, w = scr.getmaxyx()
    scr.erase()
    safe_addstr(scr, 0, max(0, (w - len(TITLE)) // 2), TITLE,
                color(C_TITLE, curses.A_BOLD))
    if subtitle:
        safe_addstr(scr, 1, max(0, (w - len(subtitle)) // 2), subtitle,
                    color(C_DIM))
    safe_addstr(scr, 2, 0, "-" * (w - 1), color(C_DIM))


def error_screen(scr, lines):
    draw_title(scr)
    h, _ = scr.getmaxyx()
    y = h // 2 - len(lines) // 2
    for i, line in enumerate(lines):
        _, w = scr.getmaxyx()
        safe_addstr(scr, y + i, max(0, (w - len(line)) // 2), line,
                    color(C_ERROR, curses.A_BOLD))
    msg = "Press any button to exit"
    safe_addstr(scr, y + len(lines) + 2,
                max(0, (scr.getmaxyx()[1] - len(msg)) // 2), msg, color(C_DIM))
    scr.refresh()
    scr.getch()



def storage_location_screen(scr, selected_key):
    """Lets the user choose where Dreamcast files are stored."""
    sel = next((i for i, item in enumerate(STORAGE_LOCATIONS)
                if item[0] == selected_key), 0)
    while True:
        draw_title(scr, "Select Dreamcast storage location")
        h, w = scr.getmaxyx()
        start_y = max(4, h // 2 - len(STORAGE_LOCATIONS))
        for i, (_key, label, path) in enumerate(STORAGE_LOCATIONS):
            text = "%-10s %s" % (label, path)
            y = start_y + i
            if i == sel:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_SEL))
                safe_addstr(scr, y, 2, "> " + text,
                            color(C_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, text)
        safe_addstr(scr, h - 1, 1,
                    "UP/DOWN: select   ENTER/A: use location", color(C_DIM))
        scr.refresh()
        ch = nav_getch(scr)
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(STORAGE_LOCATIONS)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(STORAGE_LOCATIONS)
        elif ch in KEY_ENTER:
            return STORAGE_LOCATIONS[sel]


def main_menu_screen(scr, games):
    """Returns ("inputmap",), ("bios",), ("game", path), or None to exit."""
    rows = [("header", "System"),
            ("inputmap", None),
            ("bios", None),
            ("exit", None),
            ("header", "Disc Images")]
    rows += [("game", g) for g in games]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    # default to the first disc image if any, otherwise Boot To Bios
    sel = 3 if games else 1
    top = 0
    while True:
        draw_title(scr, "%d game(s) found in %s" % (len(games), DC_DIR))
        h, w = scr.getmaxyx()
        list_top = 4
        list_h = max(1, h - list_top - 2)

        cur = selectable[sel]
        if cur < top:
            top = cur
        if cur >= top + list_h:
            top = cur - list_h + 1
        top = max(0, min(top, max(0, len(rows) - list_h)))

        for i in range(top, min(len(rows), top + list_h)):
            kind, payload = rows[i]
            y = list_top + (i - top)
            if kind == "header":
                safe_addstr(scr, y, 2, "[ %s ]" % payload,
                            color(C_HEADER, curses.A_BOLD))
                continue
            if kind == "inputmap":
                text = "Configure Input"
            elif kind == "bios":
                text = "Boot To Bios"
            elif kind == "exit":
                text = "Exit To MiSTer"
            else:
                text = payload[0]
            if i == cur:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_SEL))
                safe_addstr(scr, y, 2, "> " + text, color(C_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, text)

        footer = "UP/DOWN: select   ENTER/A: select"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        ch = nav_getch(scr)
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER:
            kind, payload = rows[selectable[sel]]
            if kind == "game":
                return ("game", payload[1])
            if kind == "exit":
                return None
            return (kind,)


def config_screen(scr, cfg, game_rel):
    """Returns True to launch, False to go back to the games list."""
    # rows: ("launch",), ("back",), ("header", text), ("opt", Option)
    rows = [("launch",), ("back",)]
    for group, opts in OPTION_GROUPS:
        rows.append(("header", group))
        for opt in opts:
            rows.append(("opt", opt))
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0  # index into selectable; 0 == Launch (default)

    # headers take two lines (blank + text), everything else one
    heights = [2 if r[0] == "header" else 1 for r in rows]
    offsets = []
    total = 0
    for hh in heights:
        offsets.append(total)
        total += hh
    top = 0

    while True:
        draw_title(scr, game_rel)
        h, w = scr.getmaxyx()
        list_top = 4
        list_h = max(1, h - list_top - 2)
        cur = selectable[sel]
        if offsets[cur] < top:
            top = offsets[cur]
        if offsets[cur] + heights[cur] > top + list_h:
            top = offsets[cur] + heights[cur] - list_h
        top = max(0, min(top, max(0, total - list_h)))

        def put(yv, x, text, attr=0):
            y = list_top + yv - top
            if list_top <= y < list_top + list_h:
                safe_addstr(scr, y, x, text, attr)

        for i, row in enumerate(rows):
            yv = offsets[i]
            is_sel = (selectable[sel] == i)
            if row[0] == "launch":
                text = "  Launch  "
                if is_sel:
                    put(yv, 4, ">" + text, color(C_SEL, curses.A_BOLD))
                else:
                    put(yv, 5, text, curses.A_BOLD)
            elif row[0] == "back":
                text = "  Back  "
                if is_sel:
                    put(yv, 4, ">" + text, color(C_SEL, curses.A_BOLD))
                else:
                    put(yv, 5, text)
            elif row[0] == "header":
                put(yv + 1, 2, "[ %s ]" % row[1],
                    color(C_HEADER, curses.A_BOLD))
            else:
                opt = row[1]
                label = "%-28s" % opt.label
                value = "< %s >" % opt.display(cfg)
                if is_sel:
                    put(yv, 4, "> " + label, color(C_SEL, curses.A_BOLD))
                    put(yv, 6 + len(label) + 2, value,
                        color(C_SEL, curses.A_BOLD))
                else:
                    put(yv, 6, label)
                    put(yv, 6 + len(label) + 2, value, color(C_VALUE))

        footer = "UP/DOWN: select   LEFT/RIGHT/ENTER/A: change"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        ch = nav_getch(scr)
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER and row[0] == "launch":
            return True
        elif ch in KEY_ENTER and row[0] == "back":
            return False
        elif ch in (curses.KEY_LEFT, curses.KEY_RIGHT) or ch in KEY_ENTER:
            if row[0] == "opt":
                row[1].cycle(cfg, -1 if ch == curses.KEY_LEFT else 1)
                save_cfg(cfg)


def ui(scr):
    """Runs the curses UI. Returns game path to launch, or None."""
    curses.curs_set(0)
    scr.keypad(True)
    try:
        curses.set_escdelay(50)
    except AttributeError:
        pass
    init_colors()

    # Storage selection is session-only; SD Card is selected by default
    # whenever DreamSTer starts. No additional launcher config is created.
    NAV[0] = NavPump()
    _selected_key, _selected_label, selected_path = storage_location_screen(
        scr, "sd")
    set_dc_dir(selected_path)

    missing = [p for p in (BOOT_BIN, FLASH_BIN) if not os.path.isfile(p)]
    if missing:
        error_screen(scr, ["ERROR: required file missing:"] +
                     ["  %s" % p for p in missing])
        NAV[0].close()
        NAV[0] = None
        return None

    cfg = load_cfg()
    load_input_config(cfg)

    games = scan_games()

    try:
        while True:
            res = main_menu_screen(scr, games)
            if res is None:
                return None
            if res[0] == "inputmap":
                input_mapper(scr, cfg)
                NAV[0].close()
                NAV[0] = NavPump()  # mappings may have changed
                continue
            game = "nodisk" if res[0] == "bios" else res[1]
            subtitle = ("Boot To Bios" if game == "nodisk"
                        else os.path.relpath(game, DC_DIR))
            if config_screen(scr, cfg, subtitle):
                return game
    finally:
        NAV[0].close()
        NAV[0] = None


# ---------------------------------------------------------------- launch ---

def run(cmd, **kw):
    print("+ " + " ".join(cmd))
    sys.stdout.flush()
    return subprocess.call(cmd, **kw)


def kill_mister():
    """Stops the MiSTer main binary so it releases input/video/audio."""
    subprocess.call(["killall", "MiSTer"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(20):  # wait up to 2s for it to actually go away
        if subprocess.call(["pidof", "MiSTer"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL) != 0:
            return
        time.sleep(0.1)


def restart_mister():
    """Reloads the menu core and brings the MiSTer main binary back up."""
    print("\nrestarting MiSTer...")
    try:
        run([LOAD_BITSTREAM, MENU_RBF], cwd=MINICAST_DIR)
    except OSError as e:
        print("menu core reload failed: %s" % e)
    try:
        with open(os.devnull, "rb+") as devnull:
            subprocess.Popen([MISTER_BIN], cwd=os.path.dirname(MISTER_BIN),
                             stdin=devnull, stdout=devnull, stderr=devnull,
                             start_new_session=True)
    except OSError as e:
        print("MiSTer restart failed: %s" % e)


def launch(game):
    print("\n=== %s ===" % TITLE)
    print("Launching: %s\n" % game)

    run(["insmod", MEM_WC], cwd=MINICAST_DIR)
    run([LOAD_BITSTREAM, BITSTREAM_RBF], cwd=MINICAST_DIR)
    run([SETUP_HDMI], cwd=MINICAST_DIR)
    run([MINICAST_ELF, game], cwd=MINICAST_DIR)


def main():
    # MiSTer launches Scripts-menu entries pinned to core 1 via taskset;
    # widen our affinity to both cores so minicast (and children) get core 0+1.
    try:
        os.sched_setaffinity(0, {0, 1})
    except OSError:
        pass

    signal.signal(signal.SIGINT, signal.SIG_IGN)

    # Take the box over up front: with MiSTer gone the console keyboard only
    # reaches us through the tty and gamepads are free for the nav pump.
    # Whatever happens after this point, MiSTer comes back on exit.
    kill_mister()
    try:
        game = curses.wrapper(ui)
        if game is not None:
            launch(game)
    finally:
        restart_mister()


if __name__ == "__main__":
    main()
