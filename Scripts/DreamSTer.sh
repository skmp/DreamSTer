#!/usr/bin/env python3
"""DreamSTer Hybrid Core - terminal UI for minicast / polly2-rtl.

Python 3.9 / curses. Scans gane dir for .cdi/.cue/.gdi images,
lets the user tweak the global and per-game settings (DreamSTer.CFG) and
launches minicast on the polly2-rtl bitstream with an emu.cfg generated from
them.

The MiSTer main binary is killed as soon as the script starts (so it stops
eating input/video) and is ALWAYS restarted when the script exits, on every
path. Menus navigate from the terminal keyboard (console tty or ssh pty) and
from any configured evdev device: mapped dpad moves, A confirms; leaving
a screen is always an explicit Back/Exit menu entry.
"""

import configparser
# NOTE: despite the ".sh" extension this file is Python 3. Keep the executable
# bit set (chmod +x) and keep the shebang above as the first line.
import curses
import fcntl
import glob
import os
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import time

TITLE = "DreamSTer Hybrid Core"

SYSTEM_DIR = "/media/fat/games/Dreamcast"
USB_GAME_DIR_GLOB = "/media/usb*/games/Dreamcast"
STARTUP_STORAGE_READY_AT = 30.0
STORAGE_POLL_INTERVAL = 0.5
BOOT_BIN = os.path.join(SYSTEM_DIR, "dc_boot.bin")
FLASH_BIN = os.path.join(SYSTEM_DIR, "dc_flash.bin")

# All DreamSTer settings: a [global] section plus one section per game (named
# by the game's path) holding only that game's overrides. Keys are emu.cfg
# "section.key" names, e.g. config.Dreamcast.Region.
STORE_PATH = "/media/fat/config/DreamSTer.CFG"
GLOBAL_SECTION = "global"
# The pre-DreamSTer.CFG global config; imported once if STORE_PATH is missing.
LEGACY_CFG_PATH = os.path.join(SYSTEM_DIR, "emu.cfg")
# emu.cfg is generated here for each launch (global, then the game's
# overrides), handed to minicast with -cfg-file and deleted afterwards.
GENERATED_CFG_PATH = "/tmp/DreamSTer/emu.cfg"

# VMU saves. minicast fills in {port} (A1, A2, ... D2) and {game_id} (the
# disc's IP.bin product number).
SAVES_DIR = "/media/fat/saves/DreamSTer"
VMU_PORTS = tuple(bus + slot for bus in "ABCD" for slot in "12")
VMU_NAMES = {"global": "global_{port}.sav", "game": "{game_id}_{port}.sav"}

# [dreamster] Version stamp; a cfg without exactly this value is from a
# different release and is reset (after a warning) before the UI runs.
CFG_VERSION = "r6"
DREAMSTER_VERSION = "r6b"

# Precompute the font dictionary once at module level
# This is reused on every draw_title() call
_FONT = {
    "D": ("####.", "#...#", "#...#", "#...#", "#...#", "####."),
    "r": (".....", "####.", "#...#", "#....", "#....", "#...."),
    "e": (".....", ".###.", "#...#", "#####", "#....", ".####"),
    "a": (".....", ".###.", "....#", ".####", "#...#", ".####"),
    "m": (".....", "##.##", "#.#.#", "#.#.#", "#.#.#", "#.#.#"),
    "S": (".####", "#....", ".###.", "....#", "#...#", ".###."),
    "T": ("#####", "..#..", "..#..", "..#..", "..#..", "..#.."),
    "H": ("#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
    "y": (".....", "#...#", "#...#", ".####", "....#", ".###."),
    "b": ("#....", "#....", "####.", "#...#", "#...#", "####."),
    "i": ("..#..", ".....", ".##..", "..#..", "..#..", ".###."),
    "d": ("....#", "....#", ".####", "#...#", "#...#", ".####"),
    "C": (".####", "#....", "#....", "#....", "#....", ".####"),
    "o": (".....", ".###.", "#...#", "#...#", "#...#", ".###."),
    "R": ("####.", "#...#", "####.", "#.#..", "#..#.", "#...#"),
    " ": (".....", ".....", ".....", ".....", ".....", "....."),
}
_DREAMCAST_ART = tuple(
    "  ".join(" ".join(_FONT[ch][y].replace(".", " ") for ch in word)
             for word in ("DreamSTer", " ", "Hybrid", " ", "Core"))
    for y in range(6)
)

MINICAST_DIR = "/media/fat/minicast"
LOAD_BITSTREAM = os.path.join(MINICAST_DIR, "load_fpga_bitstream")
BITSTREAM_RBF = os.path.join(MINICAST_DIR, "polly2-rtl.rbf")
MEM_WC = os.path.join(MINICAST_DIR, "mem_wc.ko")
SETUP_HDMI = os.path.join(MINICAST_DIR, "setup_hdmi")
MINICAST_ELF = os.path.join(MINICAST_DIR, "minicast.elf")
MISTER_BIN = "/media/fat/MiSTer"
MENU_RBF = "/media/fat/menu.rbf"

# everything a launch needs, checked up front so a missing file is reported
# before MiSTer gets killed
LAUNCH_FILES = (BOOT_BIN, FLASH_BIN, BITSTREAM_RBF, MEM_WC, SETUP_HDMI,
                MINICAST_ELF)

KEY_ENTER = (curses.KEY_ENTER, 10, 13)


def write_text_file(path, text):
    """Write text to path; return True on success. Never raises."""
    try:
        with open(path, "w") as fh:
            fh.write(text)
        return True
    except OSError:
        return False


def write_corename():
    # MiSTer's menu loader reads /tmp/CORENAME to pick the core to start.
    return write_text_file("/tmp/CORENAME", "DREAMCAST\n")


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
Dreamcast.Broadcast = 0
Dreamcast.Cable = 0
Dreamcast.ContentPath =
Dreamcast.FullMMU = no
Dreamcast.Language = 6
Dreamcast.Region = 1
Dynarec.DspEnabled = 1
Dynarec.Enabled = yes
Dynarec.ScpuEnabled = 1
Dynarec.SmcCheckLevel = 0
Dynarec.idleskip = yes
Dynarec.opt_anchored_loops = no
Dynarec.opt_constprop = 2
Dynarec.opt_cyclecheck_backwards_only = yes
Dynarec.opt_div1_som = yes
Dynarec.opt_fipr_w = yes
Dynarec.opt_readm_pairs = no
Dynarec.opt_sqw_on_pref = no
Dynarec.opt_sqw_rewrite = no
Dynarec.safe-mode = yes
Dynarec.unstable-opt = no
Freerunning = no
SavePopup.isShown = no
Social.HideCallToAction = no
aica.LimitFPS = yes
aica.NoBatch = no
aica.NoSound = no
polly2.AutoReset = yes
polly2.ClockSel = 3
polly2.DumpOnLockup = no
pvr.FPSTarget = 0
pvr.ForceGLES2 = no
pvr.MaxThreads = 3
pvr.MultithreadedTA = 2
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

[dreamster]
OptMode = balanced
Overclock = 0
Version = __CFG_VERSION__
VmuMode = global

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

# Single source of truth for the config format version: DEFAULT_CFG carries the
# same value as CFG_VERSION, so bumping one cannot silently wipe user configs.
DEFAULT_CFG = DEFAULT_CFG.replace("__CFG_VERSION__", CFG_VERSION)


# ---------------------------------------------------------------- config ---

class Option:
    def __init__(self, label, key, choices, default, enabled=None,
                 section="config"):
        self.label = label
        self.section = section
        self.key = key                 # key inside [section]
        self.choices = choices         # list of (value, display)
        self.default = default
        self._enabled = enabled        # callable(cfg) -> bool, None = always

    def enabled(self, cfg):
        return self._enabled(cfg) if self._enabled else True

    def flat_keys(self):
        """Every "section.key" set() writes; a per-game override stores and
        clears exactly these."""
        return ["%s.%s" % (self.section, self.key)]

    def current(self, cfg):
        return cfg.get(self.section, self.key, fallback=self.default).strip()

    def display(self, cfg):
        val = self.current(cfg)
        for v, name in self.choices:
            if v == val:
                return name
        return "? (%s)" % val

    def set(self, cfg, value):
        if not cfg.has_section(self.section):
            cfg.add_section(self.section)
        cfg.set(self.section, self.key, value)


class RegionOption(Option):
    """Console region; the matching Broadcast standard is written with it."""

    BROADCAST = {"1": "0", "0": "0", "2": "1"}  # US/JP -> NTSC, EU -> PAL

    def __init__(self):
        Option.__init__(self, "Region", "Dreamcast.Region",
                        [("1", "NTSC-US"), ("0", "NTSC-JP"), ("2", "PAL")],
                        "1")

    def flat_keys(self):
        return Option.flat_keys(self) + ["config.Dreamcast.Broadcast"]

    def set(self, cfg, value):
        Option.set(self, cfg, value)
        cfg.set("config", "Dreamcast.Broadcast", self.BROADCAST[value])


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

    def flat_keys(self):
        return Option.flat_keys(self) + ["audio.disable"]

    def current(self, cfg):
        if cfg.get("audio", "disable", fallback="0").strip() == "1":
            return "off"
        v = cfg.get("config", self.key, fallback="yes").strip().lower()
        return "synced" if v in ("yes", "true", "on", "1") else "unsynced"

    def set(self, cfg, value):
        for section in ("audio", "config"):
            if not cfg.has_section(section):
                cfg.add_section(section)
        cfg.set("audio", "disable", "1" if value == "off" else "0")
        if value != "off":
            cfg.set("config", self.key, "yes" if value == "synced" else "no")


def _is_freerunning(cfg):
    # same truthy set as minicast's cfgLoadBool
    v = cfg.get("config", "Freerunning", fallback="no").strip().lower()
    return v in ("yes", "true", "on", "1")


# ------------------------------------------------- optimization presets ---

def opt_mode(cfg):
    v = cfg.get("dreamster", "OptMode", fallback="balanced").strip().lower()
    return v if v in OPT_PRESETS or v == "custom" else "balanced"


def _opt_custom(cfg):
    return opt_mode(cfg) == "custom"


OPT_BOOL = [("no", "Off"), ("yes", "On")]

# the expanded optimization set; grayed out (values driven by the preset)
# unless Optimizations = Custom. Defaults are the Balanced preset.
OPT_ITEMS = [
    Option("  Async GDROM", "gdrom.AsyncDMA",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  Div1 Matching", "Dynarec.opt_div1_som",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  Constprop", "Dynarec.opt_constprop",
           [("0", "Off"), ("1", "Safe"), ("2", "Include same page")], "2",
           enabled=_opt_custom),
    Option("  FIPR Constant W", "Dynarec.opt_fipr_w",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  Multithreaded TA", "pvr.MultithreadedTA",
           [("0", "Off"), ("1", "Safe"), ("2", "Fully Async")], "2",
           enabled=_opt_custom),
    Option("  Reduced Cycle Checks", "Dynarec.opt_cyclecheck_backwards_only",
           OPT_BOOL, "yes", enabled=_opt_custom),
    Option("  SQW On Pref", "Dynarec.opt_sqw_on_pref",
           OPT_BOOL, "no", enabled=_opt_custom),
    Option("  SQW Static Rewrite", "Dynarec.opt_sqw_rewrite",
           OPT_BOOL, "no", enabled=_opt_custom),
    Option("  ReadMem Pairing", "Dynarec.opt_readm_pairs",
           OPT_BOOL, "no", enabled=_opt_custom),
    Option("  Anchored Loops", "Dynarec.opt_anchored_loops",
           OPT_BOOL, "no", enabled=_opt_custom),
    Option("  SMC Check Level", "Dynarec.SmcCheckLevel",
           [("0", "Full"), ("1", "Partial")], "0", enabled=_opt_custom),
]

# preset name -> {cfg key: value} over exactly the OPT_ITEMS keys
OPT_PRESETS = {
    "none": {
        "gdrom.AsyncDMA": "no",
        "Dynarec.opt_div1_som": "no",
        "Dynarec.opt_constprop": "0",
        "Dynarec.opt_fipr_w": "no",
        "pvr.MultithreadedTA": "0",
        "Dynarec.opt_cyclecheck_backwards_only": "no",
        "Dynarec.opt_sqw_on_pref": "no",
        "Dynarec.opt_sqw_rewrite": "no",
        "Dynarec.opt_readm_pairs": "no",
        "Dynarec.opt_anchored_loops": "no",
        "Dynarec.SmcCheckLevel": "0",
    },
    "safe": {
        "gdrom.AsyncDMA": "yes",
        "Dynarec.opt_div1_som": "yes",
        "Dynarec.opt_constprop": "1",
        "Dynarec.opt_fipr_w": "yes",
        "pvr.MultithreadedTA": "1",
        "Dynarec.opt_cyclecheck_backwards_only": "no",
        "Dynarec.opt_sqw_on_pref": "no",
        "Dynarec.opt_sqw_rewrite": "no",
        "Dynarec.opt_readm_pairs": "no",
        "Dynarec.opt_anchored_loops": "no",
        "Dynarec.SmcCheckLevel": "0",
    },
    "balanced": {
        "gdrom.AsyncDMA": "yes",
        "Dynarec.opt_div1_som": "yes",
        "Dynarec.opt_constprop": "2",
        "Dynarec.opt_fipr_w": "yes",
        "pvr.MultithreadedTA": "2",
        "Dynarec.opt_cyclecheck_backwards_only": "yes",
        "Dynarec.opt_sqw_on_pref": "no",
        "Dynarec.opt_sqw_rewrite": "no",
        "Dynarec.opt_readm_pairs": "no",
        "Dynarec.opt_anchored_loops": "no",
        "Dynarec.SmcCheckLevel": "0",
    },
    "max": {
        "gdrom.AsyncDMA": "yes",
        "Dynarec.opt_div1_som": "yes",
        "Dynarec.opt_constprop": "2",
        "Dynarec.opt_fipr_w": "yes",
        "pvr.MultithreadedTA": "2",
        "Dynarec.opt_cyclecheck_backwards_only": "yes",
        "Dynarec.opt_sqw_on_pref": "yes",
        "Dynarec.opt_sqw_rewrite": "yes",
        "Dynarec.opt_readm_pairs": "yes",
        "Dynarec.opt_anchored_loops": "no",
        "Dynarec.SmcCheckLevel": "0",
    },
    "experimental": {
        "gdrom.AsyncDMA": "yes",
        "Dynarec.opt_div1_som": "yes",
        "Dynarec.opt_constprop": "2",
        "Dynarec.opt_fipr_w": "yes",
        "pvr.MultithreadedTA": "2",
        "Dynarec.opt_cyclecheck_backwards_only": "yes",
        "Dynarec.opt_sqw_on_pref": "yes",
        "Dynarec.opt_sqw_rewrite": "yes",
        "Dynarec.opt_readm_pairs": "yes",
        "Dynarec.opt_anchored_loops": "yes",
        "Dynarec.SmcCheckLevel": "1",
    },
}


def _validate_presets():
    """Keep every preset aligned with OPT_ITEMS: drop keys that no longer have
    a row and fill keys a preset is missing (from the balanced preset, else the
    option's own default). A mismatch here would otherwise leave stale values
    in emu.cfg when a preset is applied."""
    keys = [o.key for o in OPT_ITEMS]
    balanced = OPT_PRESETS.get("balanced", {})
    for name, preset in OPT_PRESETS.items():
        for key in [k for k in preset if k not in keys]:
            del preset[key]
        for opt in OPT_ITEMS:
            preset.setdefault(opt.key, balanced.get(opt.key, opt.default))


_validate_presets()


class OptModeOption(Option):
    """Preset selector; choosing a preset writes its values to emu.cfg so
    minicast (and the grayed-out rows) always read the effective ones."""

    def __init__(self):
        Option.__init__(self, "Optimizations", "OptMode",
                        [("none", "None"), ("safe", "Safe"),
                         ("balanced", "Balanced"), ("max", "Max Speed"),
                         ("experimental", "Experimental"), ("custom", "Custom")], "balanced",
                        section="dreamster")

    def flat_keys(self):
        # a preset is the mode plus every value it writes
        return Option.flat_keys(self) + [k for o in OPT_ITEMS
                                         for k in o.flat_keys()]

    def current(self, cfg):
        return opt_mode(cfg)

    def set(self, cfg, value):
        Option.set(self, cfg, value)
        preset = OPT_PRESETS.get(value)
        if preset:
            for opt in OPT_ITEMS:
                opt.set(cfg, preset[opt.key])


REGION_OPT = RegionOption()
CABLE_OPT = Option("Cable Type", "Dreamcast.Cable",
                   [("0", "VGA"), ("3", "Composite")], "0")
# turned into Dreamcast.VmuName (VMU_NAMES) when emu.cfg is generated
VMU_OPT = Option("VMU Saves", "VmuMode",
                 [("global", "Shared"), ("game", "Per Game")], "global",
                 section="dreamster")
OVERCLOCK_OPT = Option("Overclock", "Overclock",
                       [("0", "No overclock"), ("1", "1 GHz")], "0",
                       section="dreamster")
TIMEREC_OPT = Option("Time Reconciliation", "Freerunning",
                     [("no", "Prefer Video"), ("yes", "Prefer Audio")], "no")
AUDIO_OPT = AudioOption()
FPS_OPT = Option("FPS Target", "pvr.FPSTarget",
                 [("0", "Auto"), ("66", "60 FPS"), ("55", "50 FPS"),
                  ("33", "30 FPS"), ("28", "25 FPS")], "0",
                 enabled=lambda cfg: not _is_freerunning(cfg))
OPTMODE_OPT = OptModeOption()
AUTORESET_OPT = Option("AutoReset", "polly2.AutoReset", OPT_BOOL, "yes")
# CLK register slots 0-3: the core PLL's 900 MHz VCO / 12, 10, 9, 8
# (polly2 sys_top); only 75 MHz is timing-closed
CLOCK_OPT = Option("Clock", "polly2.ClockSel",
                   [("0", "75 MHz"), ("1", "90 MHz"), ("2", "100 MHz"),
                    ("3", "112.5 MHz")], "3")
DUMP_OPT = Option("Store Crash Dump", "polly2.DumpOnLockup", OPT_BOOL, "no")

# every option Restore Defaults resets; OPTMODE last so the balanced preset
# is what ends up in the OPT_ITEMS keys
ALL_OPTIONS = [REGION_OPT, CABLE_OPT, VMU_OPT, OVERCLOCK_OPT, TIMEREC_OPT,
               AUDIO_OPT, FPS_OPT, AUTORESET_OPT, CLOCK_OPT, DUMP_OPT] \
              + OPT_ITEMS + [OPTMODE_OPT]


# ------------------------------------------------- dreamcast peripherals ---
# [input] deviceN main maple device + deviceN.1/.2 expansion slots;
# MDT values: 0 controller, 1 VMU, 3 vibration pack, 4 keyboard, 5 mouse,
# 8 none.

PERIPHERALS = [
    ("none", "None", ("8", "8", "8")),
    ("pad_vmu_vib", "Gamepad + VMU + Vibration", ("0", "1", "3")),
    ("pad_2vmu", "Gamepad + 2x VMU", ("0", "1", "1")),
    ("keyboard", "Keyboard", ("4", "8", "8")),
    ("mouse", "Mouse", ("5", "8", "8")),
]
PERIPHERAL_LABELS = dict((pid, label) for pid, label, _ in PERIPHERALS)


def _periph_keys(port):
    d = "device%d" % (port + 1)
    return (d, d + ".1", d + ".2")


def get_port_peripheral(cfg, port):
    """Peripheral id for a port, or None if the cfg holds something else."""
    keys = _periph_keys(port)
    vals = tuple(cfg.get("input", k, fallback="8").strip() for k in keys)
    for pid, _, v in PERIPHERALS:
        if v[0] != vals[0]:
            continue
        # expansion slots only distinguish the controller flavors
        if vals[0] != "0" or v[1:] == vals[1:]:
            return pid
    return None


def set_port_peripheral(cfg, port, pid):
    vals = dict((p, v) for p, _, v in PERIPHERALS)[pid]
    if not cfg.has_section("input"):
        cfg.add_section("input")
    for key, val in zip(_periph_keys(port), vals):
        cfg.set("input", key, val)


class PortOption(Option):
    """What maple device sits on one port ([input] deviceN, .1, .2)."""

    def __init__(self, port):
        Option.__init__(self, PORT_NAMES[port], "device%d" % (port + 1),
                        [(pid, label) for pid, label, _ in PERIPHERALS],
                        None, section="input")
        self.port = port

    def flat_keys(self):
        return ["input." + k for k in _periph_keys(self.port)]

    def current(self, cfg):
        return get_port_peripheral(cfg, self.port)

    def display(self, cfg):
        return PERIPHERAL_LABELS.get(self.current(cfg), "Custom")

    def set(self, cfg, value):
        set_port_peripheral(cfg, self.port, value)


def port_accepts(cfg, port, dev_kind):
    """Keyboard/Mouse ports only take matching devices; controller (and
    None/unknown) ports take anything - keyboards and mice can still act
    as gamepads there."""
    main = cfg.get("input", "device%d" % (port + 1), fallback="8").strip()
    if main == "4":
        return dev_kind == "keyboard"
    if main == "5":
        return dev_kind == "mouse"
    return True


def restore_defaults(cfg):
    """Everything back to stock: options, peripherals, input mappings."""
    for opt in ALL_OPTIONS:
        opt.set(cfg, opt.default)
    for port in range(4):
        set_port_peripheral(cfg, port, "pad_2vmu" if port == 0 else "none")
    for section in list(cfg.sections()):
        if re.match(r"input\d+$", section):
            cfg.remove_section(section)
    CONFIG.clear()
    PORTS.clear()
    # re-materialize the per-kind default mappings for connected devices
    # (all on Port A) so emu.cfg holds a working input config again
    save_input_config(cfg, scan_devices())


def clear_game_overrides(cfg):
    """Game view: drop every override, so the game uses the global
    configuration again."""
    cfg._over.clear()
    rebuild_view(cfg)
    CONFIG.clear()
    PORTS.clear()
    load_input_config(cfg)
    save_cfg(cfg)


def reset_all_configuration(store):
    """Version-mismatch reset: [global] from the pristine template (dropping
    any stale keys from other releases), every game's overrides dropped, then
    default input mappings re-materialized. Returns (cfg, ok) where ok is
    False if DreamSTer.CFG could not be written."""
    defaults = _emu_parser()
    defaults.read_string(DEFAULT_CFG)
    store.reset(flatten(defaults))
    cfg = global_view(store)
    CONFIG.clear()
    PORTS.clear()
    save_input_config(cfg, scan_devices())
    return cfg, save_cfg(cfg)


# -------------------------------------------------------- config storage ---
# DreamSTer.CFG keeps flat "section.key" names. The menus work on
# emu.cfg-shaped views of it: the global view is [global]; a game view is
# [global] with the game's overrides applied on top. A view carries its scope:
#   _store  the ConfigStore
#   _game   None for the global view, else the game path
#   _over   game views only: the game's overrides, {"section.key": value}

# "game" when a game has its own input mappings ([inputN] sections), which
# then replace the global ones as a whole
INPUT_MAPPING_KEY = "dreamster.InputMapping"
_INPUT_SECTION_KEY = re.compile(r"input\d+\.")

# per-game option value meaning "no override"
USE_GLOBAL = object()


def _emu_parser():
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str  # preserve key case
    return cfg


def _store_parser():
    # "=" only, since values hold ':' (input mappings, device ids);
    # strict=False so a hand-edited file with a repeated section still loads
    parser = configparser.ConfigParser(interpolation=None, strict=False,
                                       delimiters=("=",))
    parser.optionxform = str
    return parser


def flatten(cfg):
    """emu.cfg-shaped parser -> {"section.key": value}"""
    return {"%s.%s" % (section, key): value
            for section in cfg.sections()
            for key, value in cfg.items(section, raw=True)}


def apply_flat(cfg, flat):
    """Sets every "section.key" of flat in an emu.cfg-shaped parser."""
    for name, value in flat.items():
        section, _, key = name.partition(".")
        if not section or not key:
            continue
        if not cfg.has_section(section):
            cfg.add_section(section)
        cfg.set(section, key, value)


def merge_flat(global_flat, over):
    """The global configuration with a game's overrides applied."""
    flat = dict(global_flat)
    if over.get(INPUT_MAPPING_KEY) == "game":
        for name in [n for n in flat if _INPUT_SECTION_KEY.match(n)]:
            del flat[name]
    flat.update(over)
    return flat


class ConfigStore:
    """DreamSTer.CFG: [global] plus one section of overrides per game, named
    by the game's path."""

    def __init__(self, path=STORE_PATH):
        self.path = path
        self.parser = _store_parser()

    def read(self):
        """Loads the file. False (and an empty store) if it is unreadable."""
        try:
            with open(self.path, encoding="utf-8",
                      errors="surrogateescape") as f:
                self.parser.read_file(f)
            return True
        except (configparser.Error, OSError, ValueError):
            self.parser = _store_parser()
            return False

    def _get(self, section):
        if not self.parser.has_section(section):
            return {}
        return dict(self.parser.items(section, raw=True))

    def _put(self, section, flat):
        # in place, so the section keeps its position in the file
        if self.parser.has_section(section):
            for key in list(self.parser.options(section)):
                self.parser.remove_option(section, key)
        else:
            self.parser.add_section(section)
        for key, value in flat.items():
            self.parser.set(section, key, value)

    def global_flat(self):
        return self._get(GLOBAL_SECTION)

    def set_global(self, flat):
        self._put(GLOBAL_SECTION, flat)

    def game_flat(self, game):
        return self._get(game)

    def set_game(self, game, flat):
        """Stores a game's overrides; a game without any loses its section."""
        if flat:
            self._put(game, flat)
        else:
            self.parser.remove_section(game)

    def reset(self, global_flat):
        """Leaves only [global], holding global_flat."""
        self.parser = _store_parser()
        self._put(GLOBAL_SECTION, global_flat)

    def save(self):
        """Writes the file through a temp file, so a power cut cannot leave
        it half-written. Returns False on failure."""
        tmp = self.path + ".tmp"
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(tmp, "w", encoding="utf-8",
                      errors="surrogateescape") as f:
                self.parser.write(f)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
            return True
        except OSError:
            return False


def open_store(path=STORE_PATH, legacy_path=LEGACY_CFG_PATH):
    """Loads DreamSTer.CFG. A missing one starts from the old global emu.cfg
    if there is one (its version is then checked like any other), else from
    the stock template; an unreadable one starts from the stock template."""
    store = ConfigStore(path)
    if os.path.isfile(path):
        if store.read():
            return store
        legacy_path = None
    cfg = _emu_parser()
    if not (legacy_path and os.path.isfile(legacy_path)
            and _read_cfg_into(cfg, legacy_path) and cfg.sections()):
        cfg = _emu_parser()
        cfg.read_string(DEFAULT_CFG)
    store.set_global(flatten(cfg))
    store.save()
    return store


def global_view(store):
    cfg = _emu_parser()
    apply_flat(cfg, store.global_flat())
    if not cfg.has_section("config"):
        cfg.add_section("config")
    cfg._store, cfg._game, cfg._over = store, None, None
    return cfg


def game_view(store, game):
    """Boot To Bios ("nodisk") is not a game: it gets the global view."""
    if game == "nodisk":
        return global_view(store)
    cfg = _emu_parser()
    cfg._store, cfg._game, cfg._over = store, game, store.game_flat(game)
    rebuild_view(cfg)
    return cfg


def rebuild_view(cfg):
    """Refills a game view from [global] and its overrides, in place (the
    screens hold on to the object)."""
    for section in cfg.sections():
        cfg.remove_section(section)
    apply_flat(cfg, merge_flat(cfg._store.global_flat(), cfg._over))
    if not cfg.has_section("config"):
        cfg.add_section("config")


def save_cfg(cfg):
    """Writes a view back to DreamSTer.CFG. Returns False on failure so
    callers can warn instead of silently losing settings."""
    store = cfg._store
    if cfg._game is None:
        store.set_global(flatten(cfg))
    else:
        if cfg._over.get(INPUT_MAPPING_KEY) == "game":
            # the input pages edit the view's [inputN] sections directly
            for name in [n for n in cfg._over if _INPUT_SECTION_KEY.match(n)]:
                del cfg._over[name]
            cfg._over.update((n, v) for n, v in flatten(cfg).items()
                             if _INPUT_SECTION_KEY.match(n))
        store.set_game(cfg._game, cfg._over)
    return store.save()


def is_overridden(cfg, opt):
    return cfg._game is not None and any(n in cfg._over
                                         for n in opt.flat_keys())


def option_value(cfg, opt):
    """The option's value, or USE_GLOBAL in a game view without an override
    for it."""
    if cfg._game is not None and not is_overridden(cfg, opt):
        return USE_GLOBAL
    return opt.current(cfg)


def option_display(cfg, opt):
    if option_value(cfg, opt) is USE_GLOBAL:
        return "Use Global (%s)" % opt.display(cfg)
    return opt.display(cfg)


def next_option_value(cfg, opt, step):
    """The value LEFT (step -1) or RIGHT (+1) moves to. In a game view the
    choices start with USE_GLOBAL."""
    values = [v for v, _ in opt.choices]
    if cfg._game is not None:
        values = [USE_GLOBAL] + values
    cur = option_value(cfg, opt)
    idx = values.index(cur) if cur in values else -1
    return values[(idx + step) % len(values)]


def set_option_value(cfg, opt, value):
    """Applies a value from next_option_value. In a game view the option's
    keys become overrides, or stop being ones for USE_GLOBAL."""
    if value is USE_GLOBAL:
        for name in opt.flat_keys():
            cfg._over.pop(name, None)
        rebuild_view(cfg)
        return
    opt.set(cfg, value)
    if cfg._game is not None:
        for name in opt.flat_keys():
            section, _, key = name.partition(".")
            if cfg.has_option(section, key):
                cfg._over[name] = cfg.get(section, key)


def input_mapping_per_game(cfg):
    return cfg._game is not None and cfg._over.get(INPUT_MAPPING_KEY) == "game"


def set_input_mapping_per_game(cfg, per_game):
    """Game view: start per-game input mappings as a copy of the global ones,
    or drop them to use the global ones again."""
    for name in [n for n in cfg._over
                 if n == INPUT_MAPPING_KEY or _INPUT_SECTION_KEY.match(n)]:
        del cfg._over[name]
    if per_game:
        cfg._over[INPUT_MAPPING_KEY] = "game"
        cfg._over.update((n, v) for n, v in cfg._store.global_flat().items()
                         if _INPUT_SECTION_KEY.match(n))
    rebuild_view(cfg)
    CONFIG.clear()
    PORTS.clear()
    load_input_config(cfg)


def generated_cfg(view, game):
    """The emu.cfg minicast runs with: the view (global, plus the game's
    overrides) and where the VMU files live."""
    cfg = _emu_parser()
    apply_flat(cfg, flatten(view))
    mode = view.get("dreamster", "VmuMode", fallback="global").strip()
    if game == "nodisk" or mode not in VMU_NAMES:
        mode = "global"  # Boot To Bios has no game id
    if not cfg.has_section("config"):
        cfg.add_section("config")
    cfg.set("config", "Dreamcast.VmuPath", SAVES_DIR)
    cfg.set("config", "Dreamcast.VmuName", VMU_NAMES[mode])
    return cfg


def write_generated_cfg(cfg, path=GENERATED_CFG_PATH):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            cfg.write(f)
        return True
    except OSError as e:
        print("ERROR: cannot write %s: %s" % (path, e))
        return False


def migrate_vmus(legacy_dir=MINICAST_DIR, saves_dir=SAVES_DIR):
    """Moves VMU files from minicast's old default location (vmu_save_<port>
    .bin in its own directory) to saves_dir/global_<port>.sav. An existing
    global_<port>.sav is never overwritten; the old file then stays put."""
    try:
        os.makedirs(saves_dir, exist_ok=True)
    except OSError as e:
        print("warning: cannot create %s: %s" % (saves_dir, e))
        return
    for port in VMU_PORTS:
        old = os.path.join(legacy_dir, "vmu_save_%s.bin" % port)
        new = os.path.join(saves_dir, VMU_NAMES["global"].format(port=port))
        if os.path.isfile(old) and not os.path.exists(new):
            try:
                shutil.move(old, new)
                print("moved %s -> %s" % (old, new))
            except OSError as e:
                print("warning: could not move %s: %s" % (old, e))


def _read_cfg_into(cfg, path):
    """Read one config file into cfg. Returns True if it parsed, False if the
    file was unreadable/corrupt (a binary or half-written emu.cfg must not
    abort the launcher)."""
    try:
        with open(path, encoding="utf-8") as f:
            cfg.read_file(f)
        return True
    except (configparser.Error, UnicodeDecodeError, OSError, ValueError):
        return False


# ----------------------------------------------------------------- games ---

def _existing_absolute_dirs(paths):
    directories = []
    seen = set()
    for path in paths:
        path = os.path.normpath(path.strip())
        if (not path or not os.path.isabs(path) or path in seen or
                not os.path.isdir(path)):
            continue
        seen.add(path)
        directories.append(path)
    return directories


def _configured_game_dirs(cfg):
    content_paths = ""
    if cfg.has_section("config"):
        content_paths = cfg.get(
            "config", "Dreamcast.ContentPath", fallback="")
    return _existing_absolute_dirs(content_paths.split(";"))


def _first_external_game_dir(usb_glob=USB_GAME_DIR_GLOB):
    external = _existing_absolute_dirs(sorted(glob.glob(usb_glob)))
    return external[0] if external else None


def resolve_game_dirs(cfg, system_dir=SYSTEM_DIR,
                      usb_glob=USB_GAME_DIR_GLOB):
    """Returns configured game roots, then USB/NVMe, then microSD."""
    configured = _configured_game_dirs(cfg)
    if configured:
        return configured

    external = _first_external_game_dir(usb_glob)
    if external:
        return [external]

    return [os.path.normpath(system_dir)]


def should_wait_for_external(cfg, game_dirs, games,
                             system_dir=SYSTEM_DIR):
    return (not _configured_game_dirs(cfg) and not games and
            game_dirs == [os.path.normpath(system_dir)])


def startup_storage_wait_seconds(
        uptime_path="/proc/uptime",
        ready_at=STARTUP_STORAGE_READY_AT):
    try:
        with open(uptime_path, "r", encoding="ascii") as uptime_file:
            uptime = float(uptime_file.read().split()[0])
    except (OSError, ValueError, IndexError):
        return 0.0
    return max(0.0, ready_at - uptime)


def wait_for_external_game_dir(
        timeout, usb_glob=USB_GAME_DIR_GLOB,
        poll_interval=STORAGE_POLL_INTERVAL,
        clock_func=time.monotonic, sleep_func=time.sleep):
    if timeout <= 0:
        return None

    deadline = clock_func() + timeout
    while True:
        external = _first_external_game_dir(usb_glob)
        if external:
            return external
        remaining = deadline - clock_func()
        if remaining <= 0:
            return None
        sleep_func(min(poll_interval, remaining))


# trash / filesystem bookkeeping directories that must never show up in the
# game list (Samba's "Recycle" VFS module, freedesktop trash, ext4 lost+found)
PRUNED_DIR_NAMES = frozenset((
    "#recycle", "$recycle.bin", "recycle", ".trash-1000", ".trash-0",
    ".trash", "lost+found", ".system_volume_info", ".fseventsd",
))


def scan_games(game_dirs):
    games = []
    seen = set()
    for game_dir in game_dirs:
        game_dir = os.path.normpath(game_dir)
        for root, dirs, files in os.walk(game_dir):
            # prune trash/hidden trees in place so os.walk skips them whole
            dirs[:] = sorted(d for d in dirs
                             if d.lower() not in PRUNED_DIR_NAMES
                             and not d.startswith("."))
            # a directory holding GDI images is a dump: list every .gdi in it
            # (a folder can hold more than one dump) and nothing else
            gdi_files = sorted(name for name in files
                               if name.lower().endswith(".gdi"))
            other_files = sorted(name for name in files
                                 if name.lower().endswith((".cdi", ".cue")))
            candidates = gdi_files if gdi_files else other_files
            for name in candidates:
                path = os.path.abspath(os.path.join(root, name))
                path_key = os.path.normcase(os.path.realpath(path))
                if path_key not in seen:
                    seen.add(path_key)
                    games.append((os.path.relpath(path, game_dir), path))
    games.sort(key=lambda game: (game[0].lower(), game[1].lower()))
    return games


# ---------------------------------------------------------- input mapper ---
# evdev access is stdlib-only (raw ioctls); works on 32-bit ARM MiSTer.

CAPTURE_SECONDS = 5

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
        except (OSError, ValueError, struct.error):
            # a device that vanishes or reports a short ioctl mid-scan must
            # not abort the whole enumeration
            continue
        n = seen.get(dev.id, 0)
        seen[dev.id] = n + 1
        if n:
            # two identical devices with no unique id: disambiguate with the
            # event index rather than a positional counter, so unplugging one
            # does not rename the survivor and orphan its saved mappings
            dev.id += "#event%s" % path.rsplit("event", 1)[-1]
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
# device id -> maple port 0..3 (A..D); missing = 0/A. Persisted as `Port`
# in the device's [inputN] section; minicast routes the device's state to
# kcode[port] etc.
PORTS = {}
PORT_NAMES = ("Port A", "Port B", "Port C", "Port D")
PORT_OPTS = [PortOption(port) for port in range(4)]


def device_port(dev_id):
    return PORTS.get(dev_id, 0)

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
    ("btn_exit", "Exit Emulator"),
    ("btn_screenshot", "Screenshot"),
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
    ("btn_exit", "ButtonExit"),
    ("btn_screenshot", "ButtonScreenshot"),
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
#   key:<code>                     button/key press
#   keys:<neg>:<pos>               key pair driving an axis (-1 = unset)
#   abs:<code>:<dir>               absolute axis, dir 1 or -1
#   abs:<code>:<dir>:<min>:<max>   same, plus the calibrated range to map from
#   rel:<code>:<dir>               relative axis (mouse motion)
# Readers must ignore extra trailing fields; the optional min/max let a
# hand-calibrated stick keep its range across restarts.

def encode_mapping(m):
    if m["kind"] == "key":
        return "key:%d" % m["code"]
    if m["kind"] == "keypair":
        return "keys:%d:%d" % (m["neg"] if m["neg"] is not None else -1,
                               m["pos"] if m["pos"] is not None else -1)
    if m["kind"] == "abs":
        lo, hi = m.get("min"), m.get("max")
        if lo is not None and hi is not None:
            return "abs:%d:%d:%d:%d" % (m["code"], m["dir"], lo, hi)
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
        if parts[0] == "abs" and len(parts) in (3, 5):
            m = {"kind": "abs", "code": int(parts[1]),
                 "dir": 1 if int(parts[2]) >= 0 else -1}
            if len(parts) == 5:
                lo, hi = int(parts[3]), int(parts[4])
                if hi > lo:  # a bogus range is ignored, not stored
                    m["min"], m["max"] = lo, hi
            return m
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
        try:
            port = int(cfg.get(section, "Port", fallback="0"))
        except ValueError:
            port = 0
        PORTS[dev_id] = port if 0 <= port <= 3 else 0


def save_input_config(cfg, devices):
    """Rewrites [input0]..[inputN] in the config view and saves.
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
        cfg.set(section, "Port", str(device_port(dev_id)))
        for target, cfg_key in TARGET_CFG_KEYS:
            m = mappings.get(target)
            if m is not None:
                cfg.set(section, cfg_key, encode_mapping(m))
        n += 1
    # NOTE: what maple device sits on each port is owned by the Dreamcast
    # Peripherals page ([input] deviceN); mapping a device to a port does
    # not force a controller onto that bus.
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
    """Translates mapped dpad / confirm (A) presses on non-keyboard evdevs
    into cursor keys, so the menus are usable without a keyboard."""

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
    empty = 0
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
        # stdin at EOF makes select report it readable forever; back off so a
        # detached launcher does not spin a core reading nothing
        empty = empty + 1 if 0 in r else 0
        if empty >= 4:
            time.sleep(0.05)


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


def port_label(cfg, port):
    pid = get_port_peripheral(cfg, port)
    return "%s [%s]" % (PORT_NAMES[port],
                        PERIPHERAL_LABELS.get(pid, "Custom"))


def device_list_screen(scr, devices, cfg):
    """Returns ("test", None), ("open", dev), or None to exit."""
    rows = [("back", None),
            ("header", "General"),
            ("test", None),
            ("header", "Input Devices")]
    rows += [("dev", d) for d in devices]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0
    top = 0
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
            else:
                active = ("[Active: %s]" % PORT_NAMES[device_port(payload.id)]
                          if effective_config(payload) else "")
                text = "%-32s %-10s %s  %s" % (payload.name[:32],
                                               payload.kind,
                                               "[%s]" % payload.id, active)
            if i == cur:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_SEL))
                safe_addstr(scr, y, 2, "> " + text, color(C_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, text)

        footer = ("UP/DOWN: select   ENTER/A: open"
                  "   (changes save automatically)")
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        ch = nav_getch(scr)
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER:
            kind, payload = rows[selectable[sel]]
            if kind == "back":
                return None
            return (kind, payload)


def device_screen(scr, dev, cfg, devices):
    # rows: ("back",), ("test",), ("header", text), ("map", key, label),
    #       ("remove",)
    # every mutation is saved immediately (auto-save)
    rows = [("back",), ("header", "General"), ("test",), ("port",),
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
            elif row[0] == "port":
                text = "%-26s" % "Mapped to"
                value = "< %s >" % port_label(cfg, device_port(dev.id))
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
        footer = "UP/DOWN: select   ENTER/A: map/activate   LEFT/RIGHT: port"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))

    while True:
        draw()
        scr.refresh()

        ch = nav_getch(scr)
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif (ch in (curses.KEY_LEFT, curses.KEY_RIGHT) or ch in KEY_ENTER) \
                and row[0] == "port":
            step = -1 if ch == curses.KEY_LEFT else 1
            p = device_port(dev.id)
            for _ in range(4):
                p = (p + step) % 4
                if port_accepts(cfg, p, dev.kind):
                    break
            if port_accepts(cfg, p, dev.kind):
                PORTS[dev.id] = p
                save_input_config(cfg, devices)
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
                save_input_config(cfg, devices)
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
                    save_input_config(cfg, devices)
                nav_flush()  # the captured press also landed in the nav fds


def input_mapper(scr, cfg):
    """Input configuration UI (auto-saves). Returns when the user backs
    out."""
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
            device_screen(scr, dev, cfg, devices)


# -------------------------------------------------------------- curses ui ---

C_TITLE = 1
C_ERROR = 2
C_SEL = 3
C_HEADER = 4
C_DIM = 5
C_VALUE = 6
C_BG_SEL = 9
C_TEXT_SUB = 11
C_GAME_SEL = 18
C_LOGO = 19


def init_colors():
    if not curses.has_colors():
        return
    curses.start_color()
    curses.use_default_colors()
    # init_pair can fail on terminals with very few colour pairs; the UI then
    # falls back to attributes only instead of dying at startup
    def pair(idn, fg, bg):
        try:
            curses.init_pair(idn, fg, bg)
        except curses.error:
            pass

    pair(C_TITLE, curses.COLOR_CYAN, -1)
    pair(C_ERROR, curses.COLOR_RED, -1)
    pair(C_SEL, curses.COLOR_BLACK, curses.COLOR_WHITE)
    pair(C_HEADER, curses.COLOR_YELLOW, -1)
    pair(C_DIM, curses.COLOR_WHITE, -1)
    pair(C_VALUE, curses.COLOR_GREEN, -1)
    pair(C_BG_SEL, curses.COLOR_BLACK, curses.COLOR_MAGENTA)
    pair(C_TEXT_SUB, curses.COLOR_CYAN, -1)
    pair(C_GAME_SEL, curses.COLOR_BLACK, curses.COLOR_CYAN)
    pair(C_LOGO, 208 if curses.COLORS > 208 else curses.COLOR_YELLOW, -1)


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


def draw_title(scr, subtitle="", dreamcast_art=False):
    _, w = scr.getmaxyx()
    scr.erase()
    if dreamcast_art:
        for y, line in enumerate(_DREAMCAST_ART):
            safe_addstr(scr, y, max(0, (w - len(line)) // 2), line,
                        color(C_LOGO, curses.A_BOLD))
        subtitle_y = len(_DREAMCAST_ART)
        safe_addstr(scr, subtitle_y, max(0, (w - len(DREAMSTER_VERSION)) // 2), DREAMSTER_VERSION,
                    color(C_DIM))
        subtitle_y = subtitle_y + 1
    else:
        safe_addstr(scr, 0, max(0, (w - len(TITLE)) // 2), TITLE,
                    color(C_TITLE, curses.A_BOLD))
        subtitle_y = 1
    if subtitle:
        safe_addstr(scr, subtitle_y, max(0, (w - len(subtitle)) // 2), subtitle,
                    color(C_DIM))
    safe_addstr(scr, subtitle_y + 1, 0, "-" * (w - 1), color(C_DIM))


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
    # nav_getch, not scr.getch(): a gamepad-only setup must be able to dismiss
    # this screen (MiSTer has already been killed by the time we get here)
    nav_getch(scr)


def main_menu_screen(scr, games, game_dirs):
    """Returns ("configure",), ("bios",), ("game", label, path), or None
    to exit."""
    system_rows = [("configure", "Configure"),
                   ("bios", "Boot To Bios"),
                   ("exit", "Exit To MiSTer")]
    # default to the first disc image if any, otherwise Boot To Bios
    sel = len(system_rows) if games else 1
    game_top = 0
    while True:
        source = (game_dirs[0] if len(game_dirs) == 1
                  else "%d folders" % len(game_dirs))
        draw_title(scr, "%d game(s) found in %s" % (len(games), source),
                   dreamcast_art=True)
        h, w = scr.getmaxyx()
        list_top = 8
        game_header_y = list_top + len(system_rows) + 1
        game_list_top = game_header_y + 1
        game_list_h = max(1, h - game_list_top - 2)
        if sel >= len(system_rows):
            game_sel = sel - len(system_rows)
            if game_sel < game_top:
                game_top = game_sel
            elif game_sel >= game_top + game_list_h:
                game_top = game_sel - game_list_h + 1
            game_top = max(0, min(game_top, max(0, len(games) - game_list_h)))

        safe_addstr(scr, list_top, 2, "[ System ]",
                    color(C_HEADER, curses.A_BOLD))
        for i, (kind, text) in enumerate(system_rows):
            y = list_top + i + 1
            if i == sel:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_GAME_SEL))
                safe_addstr(scr, y, 2, "> " + text,
                            color(C_GAME_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, text)

        safe_addstr(scr, game_header_y, 2, "[ Disc Images ]",
                    color(C_HEADER, curses.A_BOLD))
        for i in range(game_top, min(len(games), game_top + game_list_h)):
            y = game_list_top + i - game_top
            text = games[i][0]
            if i + len(system_rows) == sel:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_GAME_SEL))
                safe_addstr(scr, y, 2, "> " + text,
                            color(C_GAME_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, text)

        footer = "UP/DOWN: select   LEFT/RIGHT: page   ENTER/A: select"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        ch = nav_getch(scr)
        if ch == curses.KEY_UP:
            sel = (sel - 1) % (len(system_rows) + len(games))
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % (len(system_rows) + len(games))
        elif (ch in (curses.KEY_LEFT, curses.KEY_RIGHT)
                and sel >= len(system_rows)):
            delta = max(1, game_list_h // 2)
            game_sel = sel - len(system_rows)
            target = game_sel + (-delta if ch == curses.KEY_LEFT else delta)
            game_sel = max(0, min(len(games) - 1, target))
            sel = len(system_rows) + game_sel
        elif ch in KEY_ENTER:
            if sel < len(system_rows):
                kind, _ = system_rows[sel]
                return None if kind == "exit" else (kind,)
            payload = games[sel - len(system_rows)]
            return ("game", payload[0], payload[1])


def rebuild_nav():
    """Recreates the evdev nav pump after input mappings may have changed."""
    if NAV[0] is not None:
        NAV[0].close()
        NAV[0] = NavPump()


def confirm_screen(scr, lines, subtitle="Are you sure?", yes="Yes", no="No"):
    """Modal two-way dialog; returns True on the yes option. Defaults to
    the no option."""
    sel = 1  # 0 = yes, 1 = no
    while True:
        draw_title(scr, subtitle)
        h, w = scr.getmaxyx()
        y = max(4, h // 2 - len(lines) // 2 - 2)
        for i, line in enumerate(lines):
            safe_addstr(scr, y + i, max(0, (w - len(line)) // 2), line,
                        curses.A_BOLD if i == 0 else 0)
        yb = min(h - 3, y + len(lines) + 2)
        labels = ("  %s  " % yes, "  %s  " % no)
        x = max(0, w // 2 - 14)
        for i, lab in enumerate(labels):
            if i == sel:
                safe_addstr(scr, yb, x, "> " + lab,
                            color(C_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, yb, x, "  " + lab)
            x += len(lab) + 8
        footer = "UP/DOWN: select   LEFT/RIGHT/ENTER/A: change"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()
        ch = nav_getch(scr)
        if ch in (curses.KEY_LEFT, curses.KEY_RIGHT,
                  curses.KEY_UP, curses.KEY_DOWN):
            sel ^= 1
        elif ch in KEY_ENTER:
            return sel == 0


OVERCLOCK_WARNING = [
    "Enable the 1 GHz CPU overclock?",
    "",
    "This runs the DE10-Nano's HPS above its stock",
    "800 MHz. It may be unstable on some boards:",
    "crashes, corrupted data or hangs are possible.",
    "The stock clock is restored when the emulator",
    "exits.",
]

def restore_warning(scope):
    """Danger-Zone confirmation for the global configuration."""
    return [
        "Restore %s settings to their defaults?" % scope,
        "",
        "Every Configure option, the Dreamcast peripheral",
        "assignments and all saved input mappings will be",
        "reset. This cannot be undone.",
    ]

RESET_TO_GLOBAL_WARNING = [
    "Reset this game's settings?",
    "",
    "Every Configure option, the Dreamcast peripheral",
    "assignments and the input mappings go back to",
    "Use Global. This cannot be undone.",
]

VERSION_WARNING = [
    "Configuration reset required",
    "",
    "Your DreamSTer configuration was written by a",
    "different release (expected version %s)." % CFG_VERSION,
    "",
    "OK resets ALL configuration to defaults.",
    "Exit returns to MiSTer, leaving it untouched.",
]


def peripherals_screen(scr, cfg):
    """Dreamcast Peripherals: what maple device sits on each port."""
    rows = [("back",), ("header", "Maple Ports")]
    rows += [("port", p) for p in range(4)]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0
    while True:
        draw_title(scr, "Dreamcast Peripherals")
        h, w = scr.getmaxyx()
        list_top = 5
        for i, row in enumerate(rows):
            y = list_top + i
            is_sel = (selectable[sel] == i)
            if row[0] == "header":
                header_line = "[" + row[1].ljust(w - 8) + "]"
                safe_addstr(scr, y, 2, header_line,
                            color(C_HEADER, curses.A_BOLD))
                continue
            if row[0] == "back":
                text = "Back"
                value = ""
            else:
                opt = PORT_OPTS[row[1]]
                text = "%-26s" % opt.label
                value = "< %s >" % option_display(cfg, opt)
            attr = (color(C_BG_SEL, curses.A_BOLD) if is_sel
                    else color(C_TEXT_SUB))
            if is_sel:
                safe_addstr(scr, y, 1, " " * (w - 5), color(C_BG_SEL))
            safe_addstr(scr, y, 3 if is_sel else 2, text, attr)
            safe_addstr(scr, y, 6 + len(text) + 2, value, attr)
        safe_addstr(scr, h - 1, 1,
                    "UP/DOWN: select   LEFT/RIGHT/ENTER/A: change",
                    color(C_DIM))
        scr.refresh()

        ch = nav_getch(scr)
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch in KEY_ENTER and row[0] == "back":
            return
        elif (ch in (curses.KEY_LEFT, curses.KEY_RIGHT) or ch in KEY_ENTER) \
                and row[0] == "port":
            opt = PORT_OPTS[row[1]]
            step = -1 if ch == curses.KEY_LEFT else 1
            set_option_value(cfg, opt, next_option_value(cfg, opt, step))
            save_cfg(cfg)


def configure_screen(scr, cfg, subtitle, launch=False):
    """The Configure menu, on the global view or a game view (every option
    then has a Use Global choice). With launch=True a Launch entry is pinned
    on top (pre-launch flow); returns True to launch, False/None otherwise."""
    game_scope = cfg._game is not None
    # rows: ("launch",), ("back",), ("header", text), ("opt", Option),
    #       ("inputsrc",), ("page", label, target), ("restore",)
    rows = [("launch",)] if launch else []
    rows += [("back",)]
    rows += [("header", "Dreamcast"),
             ("opt", REGION_OPT), ("opt", CABLE_OPT), ("opt", VMU_OPT),
             ("page", "Dreamcast Peripherals", "periph")]
    rows += [("header", "DE10-Nano"), ("opt", OVERCLOCK_OPT)]
    if game_scope:
        rows += [("inputsrc",), ("page", "Edit Input Mapping", "inputmap")]
    else:
        rows += [("page", "Input Mapping", "inputmap")]
    rows += [("header", "Minicast"),
             ("opt", TIMEREC_OPT), ("opt", AUDIO_OPT), ("opt", FPS_OPT),
             ("opt", OPTMODE_OPT)]
    rows += [("opt", o) for o in OPT_ITEMS]
    rows += [("header", "polly2"),
             ("opt", AUTORESET_OPT), ("opt", CLOCK_OPT), ("opt", DUMP_OPT)]
    rows += [("header", "Danger Zone"), ("restore",)]
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0  # Launch (pre-launch flow) / Back

    def row_enabled(r):
        if r[0] == "opt":
            return r[1].enabled(cfg)
        if r[0] == "page" and r[2] == "inputmap" and game_scope:
            # a game edits only its own mappings
            return input_mapping_per_game(cfg)
        return True

    # headers take two lines (blank + text), everything else one
    heights = [2 if r[0] == "header" else 1 for r in rows]
    offsets = []
    total = 0
    for hh in heights:
        offsets.append(total)
        total += hh
    top = 0

    while True:
        draw_title(scr, subtitle)
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
            elif row[0] in ("page", "restore"):
                if row[0] == "restore":
                    text = ("Reset To Global Settings" if game_scope
                            else "Restore Defaults")
                else:
                    text = "%s ..." % row[1]
                if not row_enabled(row):
                    put(yv, 6, text, color(C_DIM))
                elif is_sel:
                    put(yv, 4, "> " + text, color(C_SEL, curses.A_BOLD))
                else:
                    put(yv, 6, text)
            else:
                if row[0] == "inputsrc":
                    label = "%-28s" % "Input Mapping"
                    value = "< %s >" % ("Per Game"
                                        if input_mapping_per_game(cfg)
                                        else "Use Global")
                else:
                    label = "%-28s" % row[1].label
                    value = "< %s >" % option_display(cfg, row[1])
                if not row_enabled(row):
                    put(yv, 6, label, color(C_DIM))
                    put(yv, 6 + len(label) + 2, value, color(C_DIM))
                elif is_sel:
                    put(yv, 4, "> " + label, color(C_SEL, curses.A_BOLD))
                    put(yv, 6 + len(label) + 2, value,
                        color(C_SEL, curses.A_BOLD))
                else:
                    put(yv, 6, label)
                    put(yv, 6 + len(label) + 2, value, color(C_VALUE))

        footer = "UP/DOWN: select   LEFT/RIGHT/ENTER/A: change"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        def move_sel(delta):
            # skip disabled rows (grayed out, not selectable)
            s = sel
            for _ in range(len(selectable)):
                s = (s + delta) % len(selectable)
                if row_enabled(rows[selectable[s]]):
                    return s
            return sel

        ch = nav_getch(scr)
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = move_sel(-1)
        elif ch == curses.KEY_DOWN:
            sel = move_sel(1)
        elif ch in KEY_ENTER and row[0] == "launch":
            return True
        elif ch in KEY_ENTER and row[0] == "back":
            return False
        elif ch in KEY_ENTER and row[0] == "page":
            if not row_enabled(row):
                continue
            if row[2] == "periph":
                peripherals_screen(scr, cfg)
            else:
                input_mapper(scr, cfg)
                rebuild_nav()
        elif ch in KEY_ENTER and row[0] == "restore":
            if game_scope:
                if confirm_screen(scr, RESET_TO_GLOBAL_WARNING, "Danger Zone"):
                    clear_game_overrides(cfg)
                    rebuild_nav()
            elif confirm_screen(scr, restore_warning("all global"),
                                "Danger Zone"):
                restore_defaults(cfg)
                rebuild_nav()
        elif ch in (curses.KEY_LEFT, curses.KEY_RIGHT) or ch in KEY_ENTER:
            if row[0] == "inputsrc":
                set_input_mapping_per_game(cfg,
                                           not input_mapping_per_game(cfg))
                rebuild_nav()
                save_cfg(cfg)
            elif row[0] == "opt" and row[1].enabled(cfg):
                opt = row[1]
                new = next_option_value(cfg, opt,
                                        -1 if ch == curses.KEY_LEFT else 1)
                # 1 GHz only engages after an explicit warning
                if opt is OVERCLOCK_OPT and new == "1" and not confirm_screen(
                        scr, OVERCLOCK_WARNING, "DE10-Nano Overclock"):
                    continue
                set_option_value(cfg, opt, new)
                save_cfg(cfg)


def ui(scr):
    """Runs the curses UI. Returns (store, game path) to launch, or None."""
    curses.curs_set(0)
    scr.keypad(True)
    try:
        curses.set_escdelay(50)
    except AttributeError:
        pass
    init_colors()
    # The nav pump must exist before any dialog: without a keyboard it is the
    # only way to dismiss the error/confirm screens below.
    NAV[0] = NavPump()
    try:
        return ui_loop(scr)
    finally:
        if NAV[0] is not None:
            NAV[0].close()
            NAV[0] = None


def ui_loop(scr):
    store = open_store()
    cfg = global_view(store)
    if cfg.get("dreamster", "Version", fallback="").strip() != CFG_VERSION:
        if not confirm_screen(scr, VERSION_WARNING, "Configuration Reset",
                              yes="OK", no="Exit"):
            return None
        cfg, ok = reset_all_configuration(store)
        if not ok:
            error_screen(scr, ["ERROR: cannot write", STORE_PATH,
                               "(read-only media?)"])
            return None
    load_input_config(cfg)

    game_dirs = resolve_game_dirs(cfg)
    games = scan_games(game_dirs)
    if should_wait_for_external(cfg, game_dirs, games):
        wait_seconds = startup_storage_wait_seconds()
        if wait_seconds > 0:
            draw_title(scr, "Waiting for USB/NVMe game storage...")
            scr.refresh()
            external = wait_for_external_game_dir(wait_seconds)
            if external:
                game_dirs = [external]
                games = scan_games(game_dirs)

    while True:
        CONFIG.clear()
        PORTS.clear()
        load_input_config(cfg)
        res = main_menu_screen(scr, games, game_dirs)
        if res is None:
            return None
        if res[0] == "configure":
            configure_screen(scr, cfg, "Configure")
            continue
        if res[0] == "bios":
            game = "nodisk"
            subtitle = "Boot To Bios"
        else:
            game = res[2]
            subtitle = res[1]
        # Boot To Bios edits the global configuration: the same view object,
        # so the main menu's Configure never saves over its changes
        view = cfg if game == "nodisk" else game_view(store, game)
        CONFIG.clear()
        PORTS.clear()
        load_input_config(view)
        if configure_screen(scr, view, subtitle, launch=True):
            return store, game


# ---------------------------------------------------------------- launch ---

def run(cmd, **kw):
    print("+ " + " ".join(cmd))
    sys.stdout.flush()
    return subprocess.call(cmd, **kw)


# The MiSTer main binary that launched us: pid = our parent, exe read from
# /proc/<ppid>/exe. Falls back to killall + MISTER_BIN when the parent is
# something else (e.g. a shell during development).
MISTER = {"pid": None, "exe": MISTER_BIN}


def detect_parent_mister():
    ppid = os.getppid()
    try:
        exe = os.readlink("/proc/%d/exe" % ppid)
    except OSError:
        return
    exe = exe.replace(" (deleted)", "")
    if os.path.basename(exe) == os.path.basename(MISTER_BIN):
        MISTER["pid"] = ppid
        MISTER["exe"] = exe


def _proc_running(pid):
    """True while pid exists and is not a zombie."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(") ", 1)[1][0] != "Z"
    except (OSError, IndexError):
        return False


def kill_mister():
    """Stops the MiSTer main binary so it releases input/video/audio."""
    pid = MISTER["pid"]
    if pid is not None:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        for _ in range(20):  # wait up to 2s for it to actually go away
            if not _proc_running(pid):
                return
            time.sleep(0.1)
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        return
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
    mister = MISTER["exe"] or MISTER_BIN
    try:
        with open(os.devnull, "rb+") as devnull:
            subprocess.Popen([mister], cwd=os.path.dirname(mister),
                             stdin=devnull, stdout=devnull, stderr=devnull,
                             start_new_session=True)
    except OSError as e:
        print("MiSTer restart failed: %s" % e)


CPUFREQ_DIR = "/sys/devices/system/cpu/cpu0/cpufreq"
# MiSTer's cpufreq driver; its 1 GHz step is a boost frequency, only allowed
# while boost is enabled
CPUFREQ_MODULE = "socfpga-cpufreq"
CPUFREQ_BOOST = "/sys/devices/system/cpu/cpufreq/boost"
# non-overclocked ceiling of the DE10-NSoC used here (kHz)
STOCK_MAX_FREQ = "800000"


# name is relative to CPUFREQ_DIR, or an absolute path (CPUFREQ_BOOST)
def _cpufreq_read(name):
    try:
        with open(os.path.join(CPUFREQ_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return None


def _cpufreq_write(name, value):
    try:
        with open(os.path.join(CPUFREQ_DIR, name), "w") as f:
            f.write(value)
        return True
    except OSError as e:
        print("cpufreq: %s <- %s failed: %s" % (name, value, e))
        return False


def launch(store, game):
    print("\n=== %s ===" % TITLE)
    print("Launching: %s\n" % game)

    view = game_view(store, game)
    overclock = view.get("dreamster", "Overclock",
                         fallback="0").strip() == "1"
    migrate_vmus()
    if not write_generated_cfg(generated_cfg(view, game)):
        return 1
    minicast_cmd = [MINICAST_ELF, "-cfg-file", GENERATED_CFG_PATH, game]
    status = 0

    basename = os.path.splitext(os.path.basename(game))[0]
    dirname = os.path.dirname(game)
    # minicast/the menu pick these up from the tty files
    write_text_file("/tmp/FILESELECT", "selected\n")
    write_text_file("/tmp/CURRENTPATH", "%s\n" % basename)
    write_text_file("/tmp/FULLPATH", "%s\n" % dirname)

    prev_gov = None
    prev_max = None
    prev_boost = None
    if overclock:
        # the driver creates CPUFREQ_DIR and the boost knob; load it first
        try:
            run(["modprobe", CPUFREQ_MODULE])
        except OSError as e:
            print("overclock: modprobe %s failed: %s" % (CPUFREQ_MODULE, e))
        prev_boost = _cpufreq_read(CPUFREQ_BOOST)
        prev_gov = _cpufreq_read("scaling_governor")
        prev_max = _cpufreq_read("scaling_max_freq")
        print("overclock: boost on, CPU -> 1 GHz, governor -> performance")
        _cpufreq_write(CPUFREQ_BOOST, "1")
        _cpufreq_write("scaling_governor", "performance")
        _cpufreq_write("scaling_max_freq", "1000000")

    try:
        run(["insmod", MEM_WC], cwd=MINICAST_DIR)
        run([LOAD_BITSTREAM, BITSTREAM_RBF], cwd=MINICAST_DIR)
        run([SETUP_HDMI], cwd=MINICAST_DIR)
        status = run(minicast_cmd, cwd=MINICAST_DIR)
    finally:
        if overclock:
            # restore whatever ceiling was there before, not a hardcoded one;
            # fall back to the stock (non-overclocked) ceiling
            restore = prev_max or STOCK_MAX_FREQ
            try:
                label = "%s MHz" % (int(restore) // 1000)
            except ValueError:
                label = restore
            print("overclock: restoring CPU to %s" % label)
            _cpufreq_write("scaling_max_freq", restore)
            # never leave the governor on performance, even if we could not
            # read the previous value
            _cpufreq_write("scaling_governor", prev_gov or "conservative")
            # likewise boost: back to what it was, else off
            _cpufreq_write(CPUFREQ_BOOST, prev_boost or "0")
        # regenerated on every launch; nothing reads it afterwards
        try:
            os.remove(GENERATED_CFG_PATH)
        except OSError:
            pass
    if status:
        print("minicast exited with status %d" % status)
    return status


def main():
    # MiSTer launches Scripts-menu entries pinned to core 1 via taskset;
    # widen our affinity to both cores so minicast (and children) get core 0+1.
    try:
        os.sched_setaffinity(0, {0, 1})
    except (OSError, AttributeError):
        pass

    # Check the payload before taking the box over: if we cannot emulate,
    # MiSTer must keep running instead of being killed for nothing.
    missing = [p for p in LAUNCH_FILES if not os.path.isfile(p)]
    if missing:
        print("ERROR: required file missing:")
        for path in missing:
            print("  %s" % path)
        return 1

    if not write_corename():
        print("warning: could not write /tmp/CORENAME")

    # actually, i like terminating via sigint ~ skmp
    # signal.signal(signal.SIGINT, signal.SIG_IGN)

    # Take the box over up front: with MiSTer gone the console keyboard only
    # reaches us through the tty and gamepads are free for the nav pump.
    # Whatever happens after this point, MiSTer comes back on exit.
    detect_parent_mister()
    kill_mister()
    try:
        picked = curses.wrapper(ui)
        if picked is not None:
            store, game = picked
            return launch(store, game)
        return 0
    finally:
        restart_mister()


if __name__ == "__main__":
    sys.exit(main())
