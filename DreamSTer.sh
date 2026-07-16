#!/usr/bin/env python3
"""DreamSTer Hybrid Core - terminal UI for minicast / polly2-rtl.

Python 3.9 / curses. Scans gane dir for .cdi/.cue/.gdi images,
lets the user tweak emu.cfg and launches minicast on the polly2-rtl bitstream.
"""

import configparser
import curses
import os
import signal
import subprocess
import sys

TITLE = "DreamSTer Hybrid Core"

DC_DIR = "/media/fat/games/Dreamcast"
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
KEY_ESC = 27

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
    curses.init_pair(C_SEL, curses.COLOR_BLACK, curses.COLOR_CYAN)
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


def game_list_screen(scr, games):
    """Returns selected game path, or None to exit."""
    sel = 0
    top = 0
    while True:
        draw_title(scr, "%d game(s) found in %s" % (len(games) - 1, DC_DIR))
        h, w = scr.getmaxyx()
        list_top = 4
        list_h = max(1, h - list_top - 2)

        if sel < top:
            top = sel
        if sel >= top + list_h:
            top = sel - list_h + 1

        for i in range(top, min(len(games), top + list_h)):
            rel, _ = games[i]
            y = list_top + (i - top)
            if i == sel:
                safe_addstr(scr, y, 1, " " * (w - 3), color(C_SEL))
                safe_addstr(scr, y, 2, "> " + rel, color(C_SEL, curses.A_BOLD))
            else:
                safe_addstr(scr, y, 4, rel)

        footer = "UP/DOWN: select   ENTER: configure & launch   ESC: exit"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        ch = scr.getch()
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(games)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(games)
        elif ch in KEY_ENTER:
            return games[sel][1]
        elif ch == KEY_ESC:
            return None


def config_screen(scr, cfg, game_rel):
    """Returns True to launch, False to go back to the games list."""
    # rows: ("launch",), ("header", text), ("opt", Option)
    rows = [("launch",)]
    for group, opts in OPTION_GROUPS:
        rows.append(("header", group))
        for opt in opts:
            rows.append(("opt", opt))
    selectable = [i for i, r in enumerate(rows) if r[0] != "header"]
    sel = 0  # index into selectable; 0 == Launch (default)

    while True:
        draw_title(scr, game_rel)
        h, w = scr.getmaxyx()
        y = 4
        for i, row in enumerate(rows):
            is_sel = (selectable[sel] == i)
            if row[0] == "launch":
                text = "  Launch  "
                if is_sel:
                    safe_addstr(scr, y, 4, ">" + text, color(C_SEL, curses.A_BOLD))
                else:
                    safe_addstr(scr, y, 5, text, curses.A_BOLD)
                y += 1
            elif row[0] == "header":
                y += 1
                safe_addstr(scr, y, 2, "[ %s ]" % row[1],
                            color(C_HEADER, curses.A_BOLD))
                y += 1
            else:
                opt = row[1]
                label = "%-28s" % opt.label
                value = "< %s >" % opt.display(cfg)
                if is_sel:
                    safe_addstr(scr, y, 4, "> " + label, color(C_SEL, curses.A_BOLD))
                    safe_addstr(scr, y, 6 + len(label), value,
                                color(C_SEL, curses.A_BOLD))
                else:
                    safe_addstr(scr, y, 6, label)
                    safe_addstr(scr, y, 6 + len(label) + 2, value, color(C_VALUE))
                y += 1

        footer = "UP/DOWN: select   LEFT/RIGHT/ENTER: change   ESC: back"
        safe_addstr(scr, h - 1, 1, footer, color(C_DIM))
        scr.refresh()

        ch = scr.getch()
        row = rows[selectable[sel]]
        if ch == curses.KEY_UP:
            sel = (sel - 1) % len(selectable)
        elif ch == curses.KEY_DOWN:
            sel = (sel + 1) % len(selectable)
        elif ch == KEY_ESC:
            return False
        elif ch in KEY_ENTER and row[0] == "launch":
            return True
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

    missing = [p for p in (BOOT_BIN, FLASH_BIN) if not os.path.isfile(p)]
    if missing:
        error_screen(scr, ["ERROR: required file missing:"] +
                     ["  %s" % p for p in missing])
        return None

    cfg = load_cfg()

    games = scan_games()
    if not games:
        error_screen(scr, ["ERROR: no games (.cdi/.cue/.gdi) found in",
                           DC_DIR])
        return None
    games.insert(0, ("Boot To Bios", "nodisk"))

    while True:
        game = game_list_screen(scr, games)
        if game is None:
            return None
        subtitle = ("Boot To Bios" if game == "nodisk"
                    else os.path.relpath(game, DC_DIR))
        if config_screen(scr, cfg, subtitle):
            return game


# ---------------------------------------------------------------- launch ---

def run(cmd, **kw):
    print("+ " + " ".join(cmd))
    sys.stdout.flush()
    return subprocess.call(cmd, **kw)


def launch(game):
    print("\n=== %s ===" % TITLE)
    print("Launching: %s\n" % game)

    subprocess.call(["killall", "MiSTer"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    run(["insmod", MEM_WC], cwd=MINICAST_DIR)
    run([LOAD_BITSTREAM, BITSTREAM_RBF], cwd=MINICAST_DIR)
    run([SETUP_HDMI], cwd=MINICAST_DIR)
    run([MINICAST_ELF, game], cwd=MINICAST_DIR)

    print("\nminicast exited, restarting MiSTer...")
    run([LOAD_BITSTREAM, MENU_RBF], cwd=MINICAST_DIR)
    with open(os.devnull, "rb+") as devnull:
    	subprocess.Popen([MISTER_BIN], cwd=os.path.dirname(MISTER_BIN),
                         stdin=devnull, stdout=devnull, stderr=devnull,
                         start_new_session=True)

def main():
    # MiSTer launches Scripts-menu entries pinned to core 1 via taskset;
    # widen our affinity to both cores so minicast (and children) get core 0+1.
    try:
        os.sched_setaffinity(0, {0, 1})
    except OSError:
        pass

    signal.signal(signal.SIGINT, signal.SIG_IGN)
    game = curses.wrapper(ui)
    if game is not None:
        launch(game)


if __name__ == "__main__":
    main()
