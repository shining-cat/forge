#!/usr/bin/env python3
"""Hermetic migration, safety and cross-adapter storage contract."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class LocationTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.vault = self.root / "vault"
        (self.vault / "_shared").mkdir(parents=True)
        self.shared = self.vault / "_shared"

    def load(self, adapter):
        conf = self.root / "forge.conf"
        conf.write_text(f"VAULT_PATH={self.vault}\nWELLNESS_ENABLED=true\n")
        key = "COPILOT_HOME" if adapter == "copilot-cli" else "CLAUDE_HOME"
        path = ROOT / f"adapters/{adapter}/modules/wellness-coach/hooks/wellness_location.py"
        with patch.dict(os.environ, {key: str(self.root), "FORGE_CONF_OVERRIDE": str(conf)}):
            spec = importlib.util.spec_from_file_location("wellness_location_test", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        return module, conf

    def test_consent_migration_and_preservation(self):
        for adapter in ("copilot-cli", "claude-code"):
            with self.subTest(adapter=adapter):
                module, conf = self.load(adapter)
                legacy = self.shared / "wellness-preferences.json"
                legacy.write_text('{"wellness_onboarding_complete": true, "activity_monitor_enabled": true}')
                with patch.dict(os.environ, {"FORGE_CONF_OVERRIDE": str(conf)}):
                    self.assertEqual(module.location(), self.shared)
                    with self.assertRaises(ValueError):
                        module.prepare("wellness-coach")
                    self.assertFalse((self.shared / "wellness-location.json").exists())
                    target = module.prepare("wellness-coach", True)
                    self.assertEqual(module.location(), target)
                    copied = json.loads((target / legacy.name).read_text())
                    self.assertFalse(copied["wellness_onboarding_complete"])
                    self.assertFalse(copied["activity_monitor_enabled"])
                    self.assertTrue(json.loads(legacy.read_text())["wellness_onboarding_complete"])
                    self.assertEqual(json.loads((self.shared / "wellness-location.json").read_text()),
                                     {"directory": "wellness-coach"})
                    self.assertEqual(module.file_path("wellness-idle-log.json").parent, target)
                (self.shared / "wellness-location.json").unlink()
                (target / legacy.name).unlink()
                target.rmdir()

    def test_malformed_and_escape_fail_closed(self):
        module, conf = self.load("copilot-cli")
        outside = self.root / "outside"
        outside.mkdir()
        (self.shared / "link").symlink_to(outside, target_is_directory=True)
        with patch.dict(os.environ, {"FORGE_CONF_OVERRIDE": str(conf)}):
            for directory in ("../outside", "/outside", "link", "a/../../outside", ""):
                with self.subTest(directory=directory), self.assertRaises(ValueError):
                    module.validated_directory(self.shared, directory)
            locator = self.shared / "wellness-location.json"
            for raw in ("{", '[]', '{"directory":"../outside"}',
                        '{"directory":"link"}', '{"directory":2}'):
                with self.subTest(raw=raw):
                    locator.write_text(raw)
                    with self.assertRaises((ValueError, json.JSONDecodeError, TypeError)):
                        module.location()
            locator.unlink()
            (self.shared / "wellness-preferences.json").symlink_to(outside / "prefs")
            with self.assertRaises(ValueError):
                module.file_path("wellness-preferences.json")

    def test_failed_migration_never_publishes_locator(self):
        module, conf = self.load("claude-code")
        legacy = self.shared / "wellness-preferences.json"
        legacy.write_text("{broken")
        with patch.dict(os.environ, {"FORGE_CONF_OVERRIDE": str(conf)}):
            with self.assertRaises(json.JSONDecodeError):
                module.prepare("wellness-coach", True)
        self.assertEqual(legacy.read_text(), "{broken")
        self.assertFalse((self.shared / "wellness-location.json").exists())
        self.assertFalse((self.shared / "wellness-coach").exists())

    def test_competing_preparations_publish_only_one_locator(self):
        for adapter in ("copilot-cli", "claude-code"):
            with self.subTest(adapter=adapter):
                _, conf = self.load(adapter)
                script = ROOT / f"adapters/{adapter}/modules/wellness-coach/hooks/wellness_location.py"
                env = {**os.environ, "FORGE_CONF_OVERRIDE": str(conf)}
                commands = [
                    [sys.executable, str(script), "prepare", "--directory", name,
                     "--consent", "--old-tooling-stopped"]
                    for name in ("first", "second")
                ]
                processes = [subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE, text=True)
                             for command in commands]
                results = [process.communicate(timeout=10) for process in processes]
                winner = [i for i, process in enumerate(processes) if process.returncode == 0]
                self.assertEqual(len(winner), 1, results)
                chosen = ("first", "second")[winner[0]]
                self.assertEqual(json.loads((self.shared / "wellness-location.json").read_text()),
                                 {"directory": chosen})
                self.assertFalse((self.shared / "wellness-location.json.pending").exists())
                self.assertFalse((self.shared / ("second" if chosen == "first" else "first")).exists())
                (self.shared / "wellness-location.json").unlink()
                (self.shared / chosen).rmdir()

    def test_proposed_destination_is_read_only_and_validated(self):
        for adapter in ("copilot-cli", "claude-code"):
            with self.subTest(adapter=adapter):
                _, conf = self.load(adapter)
                script = ROOT / f"adapters/{adapter}/modules/wellness-coach/hooks/wellness_location.py"
                env = {**os.environ, "FORGE_CONF_OVERRIDE": str(conf)}
                for args, expected in (([], self.shared / "wellness-coach"),
                                       (["--directory", "personal/breaks"],
                                        self.shared / "personal/breaks")):
                    result = subprocess.run([sys.executable, str(script), "propose", *args],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), str(expected))
                    self.assertFalse(expected.exists())
                invalid = subprocess.run([sys.executable, str(script), "propose",
                                          "--directory", "../outside"], env=env,
                                         capture_output=True, text=True)
                self.assertNotEqual(invalid.returncode, 0)
                self.assertFalse((self.shared / "wellness-location.json").exists())

    def test_existing_empty_destination_can_be_approved(self):
        for adapter in ("copilot-cli", "claude-code"):
            with self.subTest(adapter=adapter):
                module, conf = self.load(adapter)
                empty = self.shared / "existing"
                empty.mkdir()
                with patch.dict(os.environ, {"FORGE_CONF_OVERRIDE": str(conf)}):
                    self.assertEqual(module.prepare("existing", True), empty)
                (self.shared / "wellness-location.json").unlink()
                self.assertTrue(empty.is_dir())
                empty.rmdir()

    def test_broken_locator_does_not_prevent_monitor_uninstall(self):
        for adapter in ("copilot-cli", "claude-code"):
            with self.subTest(adapter=adapter):
                _, conf = self.load(adapter)
                (self.shared / "wellness-location.json").write_text("{broken")
                home = self.root / "home"
                runtime = home / (".copilot" if adapter == "copilot-cli" else ".claude")
                binary = runtime / "bin" / "screen_state"
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_text("binary")
                label = f"com.{ 'copilot' if adapter == 'copilot-cli' else 'claude' }.wellness-idle-sampler"
                plist = home / "Library" / "LaunchAgents" / f"{label}.plist"
                plist.parent.mkdir(parents=True, exist_ok=True)
                plist.write_text("agent")
                fake_bin = home / "fake-bin"
                fake_bin.mkdir(exist_ok=True)
                launchctl = fake_bin / "launchctl"
                launchctl.write_text("#!/bin/sh\nexit 0\n")
                launchctl.chmod(0o755)
                script = ROOT / f"adapters/{adapter}/modules/wellness-coach/scripts/uninstall-monitor.sh"
                env = {**os.environ, "HOME": str(home), "FORGE_CONF_OVERRIDE": str(conf),
                       "PATH": f"{fake_bin}:{os.environ['PATH']}"}
                env["COPILOT_HOME" if adapter == "copilot-cli" else "CLAUDE_HOME"] = str(runtime)
                result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(binary.exists())
                self.assertFalse(plist.exists())
                self.assertIn("repair the vault locator", result.stderr)
                (self.shared / "wellness-location.json").unlink()

    def test_no_preconsent_write_and_sidecars_stay_inside_vault(self):
        for adapter in ("copilot-cli", "claude-code"):
            with self.subTest(adapter=adapter):
                module, conf = self.load(adapter)
                hooks = ROOT / f"adapters/{adapter}/modules/wellness-coach/hooks"
                with patch.dict(os.environ, {"FORGE_CONF_OVERRIDE": str(conf)}):
                    with patch.dict(sys.modules, {"wellness_location": module}):
                        spec = importlib.util.spec_from_file_location("preferences_test", hooks / "preferences.py")
                        prefs = importlib.util.module_from_spec(spec)
                        spec.loader.exec_module(prefs)
                        with self.assertRaises(ValueError):
                            prefs.read_modify_write(lambda values: values)
                        self.assertFalse((self.shared / "wellness-preferences.lock").exists())
                        legacy = self.shared / "wellness-preferences.json"
                        legacy.write_text('{"wellness_onboarding_complete":true}')
                        with self.assertRaises(ValueError):
                            prefs.read_modify_write(lambda values: values)
                        self.assertEqual(legacy.read_text(), '{"wellness_onboarding_complete":true}')
                        target = module.prepare("wellness-coach", True)
                        outside = self.root / "outside"
                        outside.write_text("untouched")
                        (target / "wellness-preferences.tmp").symlink_to(outside)
                        with self.assertRaises(ValueError):
                            prefs.write_prefs({"wellness_onboarding_complete": False})
                        self.assertEqual(outside.read_text(), "untouched")
                        (target / "wellness-preferences.tmp").unlink()
                        (target / "wellness-preferences.json").unlink(missing_ok=True)
                        with patch.object(prefs.fcntl, "flock", side_effect=TimeoutError):
                            with self.assertRaises(TimeoutError):
                                prefs.read_modify_write(lambda values: values)
                        self.assertFalse((target / "wellness-preferences.json").exists())
                        (self.shared / "wellness-location.json").unlink()
                        (target / "wellness-preferences.lock").unlink()
                        target.rmdir()
                        legacy.unlink()

    def test_migrated_setup_never_activates_older_preferences(self):
        module, conf = self.load("claude-code")
        (self.shared / "wellness-preferences.json").write_text(
            '{"wellness_onboarding_complete":true,"interruption_level":"escalating_strike"}'
        )
        with patch.dict(os.environ, {"FORGE_CONF_OVERRIDE": str(conf)}):
            module.prepare("wellness-coach", True)
        hook = ROOT / "adapters/claude-code/modules/wellness-coach/hooks/wellness-timer.py"
        env = {**os.environ, "HOME": str(self.root), "CLAUDE_HOME": str(self.root),
               "FORGE_CONF_OVERRIDE": str(conf)}
        result = subprocess.run([sys.executable, str(hook)], input='{"hook_event_name":"Stop"}',
                                capture_output=True, text=True, env=env, cwd=ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_activity_overrides_and_trim_marker_remain_in_destination(self):
        for adapter in ("copilot-cli", "claude-code"):
            with self.subTest(adapter=adapter):
                module, conf = self.load(adapter)
                hooks = ROOT / f"adapters/{adapter}/modules/wellness-coach/hooks"
                with patch.dict(os.environ, {"FORGE_CONF_OVERRIDE": str(conf)}):
                    target = module.prepare("wellness-coach", True)
                    with patch.dict(sys.modules, {"wellness_location": module}):
                        spec = importlib.util.spec_from_file_location("activity_log_test", hooks / "activity_log.py")
                        activity = importlib.util.module_from_spec(spec)
                        spec.loader.exec_module(activity)
                        prefs = {"activity_log_path": "custom/activity.md"}
                        activity.log_event(prefs, "test", "inside vault")
                        self.assertTrue((target / "custom/activity.md").exists())
                        self.assertTrue((target / "custom/activity.md.trimmed").exists())
                        with self.assertRaises(ValueError):
                            activity.activity_log_path({"activity_log_path": str(self.root / "outside.md")})
                        outside = self.root / "outside"
                        outside.write_text("untouched")
                        marker = target / "custom/activity.md.trimmed"
                        marker.unlink()
                        marker.symlink_to(outside)
                        activity.log_event(prefs, "test", "still inside")
                        self.assertEqual(outside.read_text(), "untouched")
                (self.shared / "wellness-location.json").unlink()
                (target / "custom/activity.md.trimmed").unlink()
                (target / "custom/activity.md").unlink()
                (target / "custom").rmdir()
                target.rmdir()


if __name__ == "__main__":
    unittest.main()
