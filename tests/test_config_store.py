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

open_store = DREAMSTER["open_store"]
ConfigStore = DREAMSTER["ConfigStore"]
global_view = DREAMSTER["global_view"]
game_view = DREAMSTER["game_view"]
save_cfg = DREAMSTER["save_cfg"]
option_value = DREAMSTER["option_value"]
option_display = DREAMSTER["option_display"]
next_option_value = DREAMSTER["next_option_value"]
set_option_value = DREAMSTER["set_option_value"]
set_input_mapping_per_game = DREAMSTER["set_input_mapping_per_game"]
clear_game_overrides = DREAMSTER["clear_game_overrides"]
reset_all_configuration = DREAMSTER["reset_all_configuration"]
generated_cfg = DREAMSTER["generated_cfg"]
migrate_vmus = DREAMSTER["migrate_vmus"]
USE_GLOBAL = DREAMSTER["USE_GLOBAL"]
REGION_OPT = DREAMSTER["REGION_OPT"]
CABLE_OPT = DREAMSTER["CABLE_OPT"]
VMU_OPT = DREAMSTER["VMU_OPT"]
OPTMODE_OPT = DREAMSTER["OPTMODE_OPT"]
OPT_ITEMS = DREAMSTER["OPT_ITEMS"]
PORT_OPTS = DREAMSTER["PORT_OPTS"]
CFG_VERSION = DREAMSTER["CFG_VERSION"]
SAVES_DIR = DREAMSTER["SAVES_DIR"]

# brackets and spaces, as in redump-style names
GAME = "/media/fat/games/Dreamcast/Foo (USA) [!]/foo.gdi"
OTHER_GAME = "/media/usb0/games/Dreamcast/Bar/bar.cdi"

LEGACY_EMU_CFG = """\
[config]
Dreamcast.Region = 2
Dreamcast.Broadcast = 1

[dreamster]
Version = %s

[input0]
DeviceId = 0003:045e:028e:0110
Port = 0
DpadUp = abs:17:-1
""" % CFG_VERSION


class ConfigStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.store_path = str(self.root / "config" / "DreamSTer.CFG")
        self.legacy_path = str(self.root / "emu.cfg")

    def tearDown(self):
        self.temp_dir.cleanup()

    def open(self):
        return open_store(self.store_path, self.legacy_path)

    def reopen(self):
        store = ConfigStore(self.store_path)
        self.assertTrue(store.read())
        return store

    def test_new_store_starts_from_the_template(self):
        store = self.open()
        self.assertTrue(os.path.isfile(self.store_path))
        flat = self.reopen().global_flat()
        self.assertEqual(flat["config.Dreamcast.Region"], "1")
        self.assertEqual(flat["dreamster.Version"], CFG_VERSION)
        self.assertEqual(flat["dreamster.VmuMode"], "global")
        self.assertEqual(store.parser.sections(), ["global"])

    def test_new_store_imports_the_old_emu_cfg(self):
        Path(self.legacy_path).write_text(LEGACY_EMU_CFG)
        self.open()
        flat = self.reopen().global_flat()
        self.assertEqual(flat["config.Dreamcast.Region"], "2")
        self.assertEqual(flat["input0.DeviceId"], "0003:045e:028e:0110")
        self.assertEqual(flat["input0.DpadUp"], "abs:17:-1")

    def test_existing_store_is_not_reimported(self):
        self.open()
        Path(self.legacy_path).write_text(LEGACY_EMU_CFG)
        flat = self.open().global_flat()
        self.assertEqual(flat["config.Dreamcast.Region"], "1")

    def test_unreadable_store_starts_from_the_template(self):
        Path(self.legacy_path).write_text(LEGACY_EMU_CFG)
        os.makedirs(os.path.dirname(self.store_path))
        Path(self.store_path).write_text("no section header\n")
        flat = self.open().global_flat()
        self.assertEqual(flat["config.Dreamcast.Region"], "1")

    def test_game_override_and_use_global(self):
        store = self.open()
        view = game_view(store, GAME)
        self.assertIs(option_value(view, REGION_OPT), USE_GLOBAL)
        self.assertEqual(option_display(view, REGION_OPT),
                         "Use Global (NTSC-US)")

        set_option_value(view, REGION_OPT, "2")
        self.assertTrue(save_cfg(view))
        store = self.reopen()
        self.assertEqual(store.game_flat(GAME),
                         {"config.Dreamcast.Region": "2",
                          "config.Dreamcast.Broadcast": "1"})
        self.assertEqual(store.global_flat()["config.Dreamcast.Region"], "1")
        self.assertEqual(game_view(store, GAME).get(
            "config", "Dreamcast.Region"), "2")

        view = game_view(store, GAME)
        set_option_value(view, REGION_OPT, USE_GLOBAL)
        self.assertEqual(view.get("config", "Dreamcast.Region"), "1")
        save_cfg(view)
        self.assertFalse(self.reopen().parser.has_section(GAME))

    def test_choices_start_with_use_global_only_for_games(self):
        store = self.open()
        view = game_view(store, GAME)
        seen = []
        for _ in range(4):
            value = next_option_value(view, REGION_OPT, 1)
            set_option_value(view, REGION_OPT, value)
            seen.append(value)
        self.assertEqual(seen, ["1", "0", "2", USE_GLOBAL])
        self.assertEqual(next_option_value(global_view(store), REGION_OPT, 1),
                         "0")

    def test_global_changes_reach_games_without_an_override(self):
        store = self.open()
        overriding = game_view(store, OTHER_GAME)
        set_option_value(overriding, CABLE_OPT, "0")
        save_cfg(overriding)

        cfg = global_view(store)
        set_option_value(cfg, CABLE_OPT, "3")
        save_cfg(cfg)

        store = self.reopen()
        self.assertEqual(game_view(store, GAME).get(
            "config", "Dreamcast.Cable"), "3")
        self.assertEqual(game_view(store, OTHER_GAME).get(
            "config", "Dreamcast.Cable"), "0")

    def test_opt_mode_override_owns_the_preset_values(self):
        store = self.open()
        view = game_view(store, GAME)
        set_option_value(view, OPTMODE_OPT, "max")
        self.assertEqual(view._over["dreamster.OptMode"], "max")
        for opt in OPT_ITEMS:
            self.assertIn("config." + opt.key, view._over)
        set_option_value(view, OPTMODE_OPT, USE_GLOBAL)
        self.assertEqual(view._over, {})
        self.assertEqual(view.get("dreamster", "OptMode"), "balanced")

    def test_port_override(self):
        store = self.open()
        view = game_view(store, GAME)
        set_option_value(view, PORT_OPTS[1], "keyboard")
        self.assertEqual(view._over, {"input.device2": "4",
                                      "input.device2.1": "8",
                                      "input.device2.2": "8"})
        self.assertEqual(option_display(view, PORT_OPTS[0]),
                         "Use Global (Gamepad + 2x VMU)")

    def test_per_game_input_mappings_replace_the_global_ones(self):
        Path(self.legacy_path).write_text(
            LEGACY_EMU_CFG + "\n[input1]\nDeviceId = kbd\nPort = 1\n")
        store = self.open()
        view = game_view(store, GAME)
        set_input_mapping_per_game(view, True)
        self.assertEqual(view._over["input0.DeviceId"],
                         "0003:045e:028e:0110")
        # what save_input_config does after an edit: rewrite the sections
        view.remove_section("input1")
        view.set("input0", "DpadUp", "key:103")
        save_cfg(view)

        store = self.reopen()
        merged = game_view(store, GAME)
        self.assertEqual(merged.get("input0", "DpadUp"), "key:103")
        self.assertFalse(merged.has_section("input1"))
        self.assertEqual(store.global_flat()["input0.DpadUp"], "abs:17:-1")
        self.assertEqual(store.global_flat()["input1.DeviceId"], "kbd")

        set_input_mapping_per_game(merged, False)
        self.assertEqual(merged.get("input0", "DpadUp"), "abs:17:-1")
        self.assertTrue(merged.has_section("input1"))

    def test_clear_game_overrides(self):
        store = self.open()
        view = game_view(store, GAME)
        set_option_value(view, REGION_OPT, "2")
        set_input_mapping_per_game(view, True)
        save_cfg(view)
        clear_game_overrides(view)
        self.assertFalse(self.reopen().parser.has_section(GAME))
        self.assertEqual(view.get("config", "Dreamcast.Region"), "1")

    def test_reset_drops_every_game(self):
        store = self.open()
        view = game_view(store, GAME)
        set_option_value(view, REGION_OPT, "2")
        save_cfg(view)
        cfg, ok = reset_all_configuration(store)
        self.assertTrue(ok)
        store = self.reopen()
        self.assertEqual(store.parser.sections(), ["global"])
        self.assertEqual(store.global_flat()["dreamster.Version"],
                         CFG_VERSION)

    def test_generated_cfg_vmu_location(self):
        store = self.open()
        cfg = generated_cfg(game_view(store, GAME), GAME)
        self.assertEqual(cfg.get("config", "Dreamcast.VmuPath"), SAVES_DIR)
        self.assertEqual(cfg.get("config", "Dreamcast.VmuName"),
                         "global_{port}.sav")

        view = game_view(store, GAME)
        set_option_value(view, VMU_OPT, "game")
        cfg = generated_cfg(view, GAME)
        self.assertEqual(cfg.get("config", "Dreamcast.VmuName"),
                         "{game_id}_{port}.sav")
        self.assertEqual(cfg.get("config", "Dreamcast.Region"), "1")

        # Boot To Bios has no game id
        set_option_value(global_view(store), VMU_OPT, "game")
        cfg = generated_cfg(global_view(store), "nodisk")
        self.assertEqual(cfg.get("config", "Dreamcast.VmuName"),
                         "global_{port}.sav")

    def test_migrate_vmus(self):
        legacy = self.root / "minicast"
        saves = self.root / "saves" / "DreamSTer"
        legacy.mkdir()
        (legacy / "vmu_save_A1.bin").write_bytes(b"old A1")
        (legacy / "vmu_save_B1.bin").write_bytes(b"old B1")
        saves.mkdir(parents=True)
        (saves / "global_B1.sav").write_bytes(b"kept B1")

        migrate_vmus(str(legacy), str(saves))

        self.assertEqual((saves / "global_A1.sav").read_bytes(), b"old A1")
        self.assertFalse((legacy / "vmu_save_A1.bin").exists())
        self.assertEqual((saves / "global_B1.sav").read_bytes(), b"kept B1")
        self.assertEqual((legacy / "vmu_save_B1.bin").read_bytes(), b"old B1")


if __name__ == "__main__":
    unittest.main()
