import configparser
import os
from pathlib import Path
import runpy
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
DREAMSTER = runpy.run_path(
    str(REPO_ROOT / "Scripts" / "DreamSTer.sh"),
    run_name="dreamster_test",
)

resolve_game_dirs = DREAMSTER["resolve_game_dirs"]
scan_games = DREAMSTER["scan_games"]
should_wait_for_external = DREAMSTER["should_wait_for_external"]
startup_storage_wait_seconds = DREAMSTER["startup_storage_wait_seconds"]
wait_for_external_game_dir = DREAMSTER["wait_for_external_game_dir"]


def make_cfg(content_paths=""):
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str
    cfg.add_section("config")
    cfg.set("config", "Dreamcast.ContentPath", content_paths)
    return cfg


class GameDirectoryTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.system_dir = self.root / "media" / "fat" / "games" / "Dreamcast"
        self.system_dir.mkdir(parents=True)
        self.usb_glob = str(
            self.root / "media" / "usb*" / "games" / "Dreamcast")

    def tearDown(self):
        self.temp_dir.cleanup()

    def resolve(self, cfg):
        return resolve_game_dirs(
            cfg,
            system_dir=str(self.system_dir),
            usb_glob=self.usb_glob,
        )

    def make_usb_dir(self, device):
        game_dir = self.root / "media" / device / "games" / "Dreamcast"
        game_dir.mkdir(parents=True)
        return game_dir

    def test_all_existing_configured_directories_take_precedence(self):
        first = self.root / "custom" / "one"
        second = self.root / "custom" / "two"
        first.mkdir(parents=True)
        second.mkdir(parents=True)
        self.make_usb_dir("usb0")

        configured = ";".join([
            str(self.root / "missing"),
            " " + str(first) + " ",
            str(first / "."),
            "relative/path",
            str(second),
        ])

        self.assertEqual(self.resolve(make_cfg(configured)),
                         [str(first), str(second)])

    def test_valid_empty_configured_directory_is_authoritative(self):
        configured = self.root / "empty"
        configured.mkdir()
        self.make_usb_dir("usb0")

        self.assertEqual(self.resolve(make_cfg(str(configured))),
                         [str(configured)])

    def test_unavailable_configuration_falls_back_to_first_usb(self):
        usb2 = self.make_usb_dir("usb2")
        usb1 = self.make_usb_dir("usb1")

        resolved = self.resolve(make_cfg(
            str(self.root / "missing") + ";relative/path"))

        self.assertEqual(resolved, [str(usb1)])
        self.assertNotEqual(resolved, [str(usb2)])

    def test_no_external_directory_falls_back_to_system_directory(self):
        self.assertEqual(self.resolve(make_cfg()), [str(self.system_dir)])

    def test_wait_gate_only_for_empty_unconfigured_system_fallback(self):
        fallback = [str(self.system_dir)]

        self.assertTrue(should_wait_for_external(
            make_cfg(), fallback, [], system_dir=str(self.system_dir)))
        self.assertFalse(should_wait_for_external(
            make_cfg(), fallback, [("Game.gdi", "/Game.gdi")],
            system_dir=str(self.system_dir)))

        configured = self.root / "configured"
        configured.mkdir()
        self.assertFalse(should_wait_for_external(
            make_cfg(str(configured)), [str(configured)], [],
            system_dir=str(self.system_dir)))

    def test_startup_wait_uses_remaining_boot_window(self):
        uptime_file = self.root / "uptime"
        uptime_file.write_text("19.25 18.00", encoding="ascii")
        self.assertEqual(DREAMSTER["STARTUP_STORAGE_READY_AT"], 30.0)
        self.assertAlmostEqual(startup_storage_wait_seconds(
            uptime_path=str(uptime_file)), 10.75)

        uptime_file.write_text("31.00 30.00", encoding="ascii")
        self.assertEqual(startup_storage_wait_seconds(
            uptime_path=str(uptime_file), ready_at=30.0), 0.0)

        uptime_file.write_text("invalid", encoding="ascii")
        self.assertEqual(startup_storage_wait_seconds(
            uptime_path=str(uptime_file), ready_at=30.0), 0.0)

    def test_wait_retries_until_external_mount_appears(self):
        usb1 = self.root / "media" / "usb1" / "games" / "Dreamcast"
        clock_values = iter([0.0, 0.0])

        def create_mount(_delay):
            usb1.mkdir(parents=True)

        found = wait_for_external_game_dir(
            1.0,
            usb_glob=self.usb_glob,
            poll_interval=0.5,
            clock_func=lambda: next(clock_values),
            sleep_func=create_mount,
        )

        self.assertEqual(found, str(usb1))

    def test_wait_times_out_without_external_mount(self):
        clock_values = iter([0.0, 0.25, 0.75, 1.0])
        sleep_delays = []

        found = wait_for_external_game_dir(
            1.0,
            usb_glob=self.usb_glob,
            poll_interval=0.5,
            clock_func=lambda: next(clock_values),
            sleep_func=sleep_delays.append,
        )

        self.assertIsNone(found)
        self.assertEqual(sleep_delays, [0.5, 0.25])

    def test_scan_games_merges_roots_recursively_and_deduplicates(self):
        first = self.root / "library-one"
        second = self.root / "library-two"
        nested = first / "Nested"
        nested.mkdir(parents=True)
        second.mkdir()

        (nested / "Alpha.GDI").write_text("", encoding="utf-8")
        (nested / "track01.bin").write_text("", encoding="utf-8")
        (first / "Beta.cue").write_text("", encoding="utf-8")
        (second / "Gamma.CdI").write_text("", encoding="utf-8")
        (second / "README.txt").write_text("", encoding="utf-8")

        games = scan_games([str(first), str(first), str(second)])

        self.assertEqual([display for display, _ in games], [
            "Beta.cue",
            "Gamma.CdI",
            os.path.join("Nested", "Alpha.GDI"),
        ])
        self.assertEqual(len(games), 3)
        self.assertTrue(all(os.path.isabs(path) for _, path in games))

    def test_system_files_remain_on_micro_sd(self):
        self.assertEqual(DREAMSTER["SYSTEM_DIR"],
                         "/media/fat/games/Dreamcast")
        self.assertEqual(DREAMSTER["BOOT_BIN"],
                         "/media/fat/games/Dreamcast/dc_boot.bin")
        self.assertEqual(DREAMSTER["FLASH_BIN"],
                         "/media/fat/games/Dreamcast/dc_flash.bin")
        self.assertEqual(DREAMSTER["CFG_PATH"],
                         "/media/fat/games/Dreamcast/emu.cfg")


if __name__ == "__main__":
    unittest.main()
