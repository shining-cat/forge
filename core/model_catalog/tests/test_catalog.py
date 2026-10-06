import datetime as dt
import contextlib
import io
import json
import os
import runpy
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from model_catalog.cli import main as catalog_main
from model_catalog.catalog import SnapshotError, catalog_path, load_snapshot, migrate_config, publish_manual, resolve, tier_from_config, write_snapshot

def stamp(seconds=0): return (dt.datetime.now(dt.timezone.utc)+dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")
def rec(name="model", tier="standard", caps=("reasoning",), bindings=None, evidence=None):
    return {"identity": {"id": name, "vendor": "vendor"}, "tier": tier, "capabilities": list(caps), "evidence": evidence or [{"kind": "declared", "captured_at": stamp()}], "bindings": bindings if bindings is not None else [{"runtime": "claude", "active": True, "dispatch_id": "dispatch"}]}
def snap(records, captured=None): return {"schema_version": 1, "captured_at": captured or stamp(), "clock": {"source": "system", "timezone": "UTC"}, "records": records, "outcomes": [], "migration": {"status": "none"}}
class CatalogTests(unittest.TestCase):
    def test_exact_tier_and_capabilities(self):
        self.assertEqual(resolve(snap([rec(tier="economy")]), "standard")["status"], "no_match")
        self.assertEqual(resolve(snap([rec()]), "standard", ["missing"])["status"], "no_match")
        self.assertEqual(resolve(snap([rec()]), "inherit")["status"], "inherit")
    def test_malformed_nested_entries_are_snapshot_errors(self):
        bad = rec(); bad["identity"] = "bad"
        with self.assertRaises(SnapshotError): load_snapshot(self._write(snap([bad])))
        bad = rec(); bad["evidence"] = [{"kind": "wat"}]
        with self.assertRaises(SnapshotError): load_snapshot(self._write(snap([bad])))
        bad = rec(); bad["bindings"] = [{"active": True}]
        with self.assertRaises(SnapshotError): load_snapshot(self._write(snap([bad])))
    def test_outcomes_and_migration_nested_validation(self):
        bad = snap([]); bad["outcomes"] = [{"status": "wat"}]
        with self.assertRaises(SnapshotError): load_snapshot(self._write(bad))
        bad = snap([]); bad["migration"] = {"status": "complete", "roles": {"keeper": {"tier": "wat"}}}
        with self.assertRaises(SnapshotError): load_snapshot(self._write(bad))
        bad = snap([]); bad["migration"] = {"status": "complete", "roles": {"keeper": "vendor-model"}}
        with self.assertRaises(SnapshotError): load_snapshot(self._write(bad))
        bad = snap([]); bad["migration"] = {"status": "complete", "pending": {"keeper": "vendor-model"}}
        with self.assertRaises(SnapshotError): load_snapshot(self._write(bad))
        allowed = snap([]); allowed["migration"] = {"status": "complete", "roles": {"keeper": "premium"}}
        self.assertEqual(load_snapshot(self._write(allowed))["migration"]["roles"]["keeper"], "premium")
    def test_role_tier_resolution_and_explicit_precedence(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            config = os.path.join(d, "forge.conf")
            with open(config, "w") as stream: stream.write("MODEL_KEEPER=sonnet\n")
            migrate_config(config)
            self.assertEqual(tier_from_config(config, "keeper"), "pending")
            data = snap([rec(tier="premium")])
            self.assertEqual(resolve(data, tier="premium", role="keeper")["status"], "resolved")
    def test_canonical_precedence_and_legacy_fallback(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            shared = os.path.join(d, "_shared")
            os.makedirs(os.path.join(shared, "model-catalog"))
            legacy = os.path.join(shared, "capability-snapshot.json")
            json.dump(snap([rec(name="legacy")]), open(legacy, "w"))
            with mock.patch.dict(os.environ, {"VAULT_PATH": d}):
                self.assertEqual(load_snapshot()["records"][0]["identity"]["id"], "legacy")
                json.dump(snap([rec(name="canonical")]), open(catalog_path(d), "w"))
                self.assertEqual(load_snapshot()["records"][0]["identity"]["id"], "canonical")

    def test_canonical_invalid_does_not_fall_back(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            os.makedirs(os.path.join(d, "_shared", "model-catalog"))
            json.dump(snap([rec(name="legacy")]), open(os.path.join(d, "_shared", "capability-snapshot.json"), "w"))
            with mock.patch.dict(os.environ, {"VAULT_PATH": d}):
                open(catalog_path(d), "w").write("not json")
                with self.assertRaises(SnapshotError): load_snapshot()
                stale = snap([], stamp(-86401)); json.dump(stale, open(catalog_path(d), "w"))
                with self.assertRaises(SnapshotError): load_snapshot()

    def test_explicit_legacy_path_remains_supported(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            path = os.path.join(d, "capability-snapshot.json")
            json.dump(snap([rec(name="legacy")]), open(path, "w"))
            self.assertEqual(load_snapshot(path)["records"][0]["identity"]["id"], "legacy")

    def test_stale_and_future(self):
        with self.assertRaises(SnapshotError): load_snapshot(self._write(snap([], stamp(-86401))))
        with self.assertRaises(SnapshotError): load_snapshot(self._write(snap([], stamp(2))))
    def test_manual_persists_but_system_expires_and_future_is_rejected(self):
        for source in ("manual", "system"):
            data = snap([rec()], stamp(-86401)); data["clock"]["source"] = source
            if source == "manual":
                self.assertEqual(load_snapshot(self._write(data))["clock"]["source"], source)
            else:
                with self.assertRaises(SnapshotError): load_snapshot(self._write(data))
            data["captured_at"] = stamp(30)
            with self.assertRaises(SnapshotError): load_snapshot(self._write(data))

    def test_coverage_is_read_only(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            path = os.path.join(d, "catalog.json")
            config = os.path.join(d, "forge.conf")
            baseline = b"ONBOARDING_COMPLETE=false\nMODEL_TIER_KEEPER=premium\nMODEL_KEEPER=legacy\nOTHER=keep\n"
            Path(config).write_bytes(baseline)
            records = [rec(name=t, tier=t, bindings=[{"runtime": "claude", "active": True, "dispatch_id": t}]) for t in ("minimal", "economy", "standard", "premium")]
            data = snap(records); data["clock"]["source"] = "manual"
            json.dump(data, open(path, "w"))
            args = ["check-coverage", "--snapshot", path, "--binding", "claude"]
            self.assertEqual(catalog_main(args), 0)
            self.assertEqual(Path(config).read_bytes(), baseline)
            for change in ("missing", "inactive", "foreign", "invalid"):
                broken = json.loads(json.dumps(data))
                if change == "missing": broken["records"].pop()
                if change == "inactive": broken["records"][-1]["bindings"][0]["active"] = False
                if change == "foreign": broken["records"][-1]["bindings"][0]["runtime"] = "copilot-cli"
                if change == "invalid": broken["schema_version"] = 999
                json.dump(broken, open(path, "w"))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertNotEqual(catalog_main(args), 0, change)
                response = json.loads(output.getvalue())
                self.assertEqual(response["status"], "invalid" if change == "invalid" else "incomplete")
                if change != "invalid":
                    self.assertEqual(response["missing_tiers"], ["premium"])
                    self.assertEqual(response["tiers"]["premium"], "no_match")
                self.assertEqual(Path(config).read_bytes(), baseline, change)
            json.dump(data, open(path, "w"))
            self.assertEqual(catalog_main(["check-coverage", "--snapshot", path, "--binding", "copilot-cli"]), 2)

    def test_onboarding_routes_independently_of_completion_flag(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            config = Path(d) / "forge.conf"; path = Path(d) / "catalog.json"
            records = [rec(name=t, tier=t, bindings=[{"runtime": "claude", "active": True, "dispatch_id": t}])
                       for t in ("minimal", "economy", "standard", "premium")]
            data = snap(records); data["clock"]["source"] = "manual"
            for completed, covered, expected_action, skip in (
                (True, True, "continue", True),
                (True, False, "map-models-only", False),
                (False, True, "full-onboarding", True),
                (False, False, "full-onboarding", False),
            ):
                config.write_text(f"ONBOARDING_COMPLETE={'true' if completed else 'false'}\n")
                before = config.read_bytes()
                path.write_text(json.dumps(data if covered else {**data, "records": records[:-1]}))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(catalog_main(["onboarding-status", "--snapshot", str(path),
                                                   "--binding", "claude", "--config", str(config)]), 0)
                result = json.loads(output.getvalue())
                self.assertEqual((result["action"], result["skip_model_mapping"]), (expected_action, skip))
                self.assertEqual(config.read_bytes(), before)
            config.write_text("ONBOARDING_COMPLETE=true\n")
            path.write_text("not-json")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(catalog_main(["onboarding-status", "--snapshot", str(path),
                                               "--binding", "claude", "--config", str(config)]), 0)
            self.assertEqual(json.loads(output.getvalue())["action"], "map-models-only")
            self.assertEqual(config.read_text(), "ONBOARDING_COMPLETE=true\n")

    def test_full_first_run_completion_gate_changes_only_flag(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            config = Path(d) / "forge.conf"; catalog = Path(d) / "catalog.json"
            initial = b"VAULT_PATH=vault\r\nMODEL_TIER_KEEPER=premium\r\nMODEL_KEEPER=legacy\r\nONBOARDING_COMPLETE=false\r\nOTHER=unchanged\r\n"
            config.write_bytes(initial)
            records = [rec(name=t, tier=t, bindings=[{"runtime": "claude", "active": True, "dispatch_id": t}])
                       for t in ("minimal", "economy", "standard", "premium")]
            data = snap(records); data["clock"]["source"] = "manual"
            catalog.write_text(json.dumps(data))
            args = ["finish-onboarding", "--snapshot", str(catalog), "--binding", "claude", "--config", str(config)]
            for broken in ({**data, "records": records[:-1]},
                           {**data, "records": [dict(record, bindings=[{"runtime": "copilot-cli", "active": True, "dispatch_id": record["tier"]}]) for record in records]},
                           {**data, "schema_version": 999},
                           {**data, "captured_at": stamp(60)}):
                catalog.write_text(json.dumps(broken))
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertNotEqual(catalog_main(args), 0)
                self.assertEqual(config.read_bytes(), initial)
            catalog.write_text(json.dumps(data))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(catalog_main(["onboarding-status", "--snapshot", str(catalog), "--binding", "claude", "--config", str(config)]), 0)
            self.assertEqual(json.loads(output.getvalue())["action"], "full-onboarding")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(catalog_main(args), 0)
            self.assertEqual(config.read_bytes(), initial.replace(b"ONBOARDING_COMPLETE=false", b"ONBOARDING_COMPLETE=true"))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(catalog_main(args), 0)
            self.assertEqual(config.read_bytes(), initial.replace(b"ONBOARDING_COMPLETE=false", b"ONBOARDING_COMPLETE=true"))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(catalog_main(["onboarding-status", "--snapshot", str(catalog), "--binding", "claude", "--config", str(config)]), 0)
            self.assertEqual(json.loads(output.getvalue())["action"], "continue")
            config.write_bytes(b"MODEL_KEEPER=legacy")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(catalog_main(args), 0)
            self.assertEqual(config.read_bytes(), b"MODEL_KEEPER=legacy\nONBOARDING_COMPLETE=true\n")

    def test_legacy_setup_entry_points_fail_explicitly(self):
        root = Path(__file__).resolve().parents[3]
        backend = root / "core/tools/forge-model-catalog-setup.py"
        scripts = root / "core/skills/forge-setup-models/scripts"
        with tempfile.TemporaryDirectory(dir=root) as d:
            env = {**os.environ, "HOME": d, "VAULT_PATH": str(Path(d) / "vault"), "PYTHONDONTWRITEBYTECODE": "1"}
            for command in ("parse", "validate", "infer", "resolve-test"):
                result = subprocess.run([sys.executable, str(backend), command], input="model-a\n", env=env,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("explicit four-tier selection", result.stderr)
            for command in (["bash", str(scripts / "setup-models-noninteractive.sh"), "model-a"],
                            [sys.executable, str(scripts / "setup-models-batch.py"), "model-a"]):
                result = subprocess.run(command, env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("select all four tiers explicitly", result.stderr)
            module = runpy.run_path(str(backend), run_name="forge_setup_api_test")
            with self.assertRaisesRegex(RuntimeError, "Automatic tier inference is retired"):
                module["parse_models"]("model-a")
            self.assertFalse((Path(d) / "vault").exists())

    def test_claude_installer_ships_setup_assets(self):
        root = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(dir=root) as d:
            home = Path(d) / "home"
            (home / ".claude").mkdir(parents=True)
            env = {**os.environ, "HOME": str(home), "TMPDIR": d, "PYTHONDONTWRITEBYTECODE": "1"}
            result = subprocess.run(["bash", str(root / "adapters/claude-code/install.sh"),
                                     "--vault-path", str(Path(d) / "vault")], input="", text=True,
                                    capture_output=True, env=env, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout[-1000:] + result.stderr[-1000:])
            for asset in ("skills/forge-setup-models/SKILL.md", "skills/forge-setup-models/scripts/forge-setup-models.sh",
                          "scripts/forge-model-catalog-setup.py", "scripts/forge_capability/cli.py"):
                self.assertTrue((home / ".claude" / asset).is_file(), asset)
            config = home / ".claude/forge.conf"
            baseline = config.read_bytes()
            script = home / ".claude/skills/forge-setup-models/scripts/forge-setup-models.sh"
            runtime_env = {**env, "FORGE_RUNTIME": "claude", "VAULT_PATH": str(Path(d) / "vault")}
            runtime_env.pop("FORGE_CORE", None)
            mapped = subprocess.run(["bash", str(script)], input="model-a\n\n1\n1\n1\n1\n",
                                    text=True, capture_output=True, env=runtime_env)
            self.assertEqual(mapped.returncode, 0, mapped.stdout + mapped.stderr)
            self.assertEqual(config.read_bytes(), baseline, "installed setup must not edit role policy")
            self.assertEqual(catalog_main(["check-coverage", "--snapshot", str(Path(d) / "vault/_shared/model-catalog/catalog.json"), "--binding", "claude"]), 0)
            self.assertFalse(list((home / ".claude").glob("forge.conf.bak.*")))
            wrapper = home / ".claude/scripts/forge-model-catalog.sh"
            foreign = subprocess.run(["bash", str(wrapper), "finish-onboarding", "--snapshot",
                                      str(Path(d) / "vault/_shared/model-catalog/catalog.json"), "--binding", "copilot-cli",
                                      "--config", str(config)], env=runtime_env, text=True, capture_output=True)
            self.assertNotEqual(foreign.returncode, 0, "foreign runtime must not finish Claude onboarding")
            self.assertEqual(config.read_bytes(), baseline)
            other_config = Path(d) / "other-forge.conf"
            other_config.write_bytes(b"ONBOARDING_COMPLETE=false\n")
            foreign_config = subprocess.run(["bash", str(wrapper), "finish-onboarding", "--snapshot",
                                             str(Path(d) / "vault/_shared/model-catalog/catalog.json"), "--binding", "claude",
                                             "--config", str(other_config)], env=runtime_env, text=True, capture_output=True)
            self.assertNotEqual(foreign_config.returncode, 0, "foreign config must not be marked complete")
            self.assertEqual(other_config.read_bytes(), b"ONBOARDING_COMPLETE=false\n")
            complete = subprocess.run(["bash", str(wrapper), "finish-onboarding", "--snapshot",
                                       str(Path(d) / "vault/_shared/model-catalog/catalog.json"), "--binding", "claude",
                                       "--config", str(config)], env=runtime_env, text=True, capture_output=True)
            self.assertEqual(complete.returncode, 0, complete.stdout + complete.stderr)
            self.assertEqual(config.read_bytes(), baseline.replace(b"ONBOARDING_COMPLETE=false", b"ONBOARDING_COMPLETE=true"))

    def test_interactive_setup_guards_and_mixed_runtime(self):
        root = Path(__file__).resolve().parents[3]
        script = root / "core/skills/forge-setup-models/scripts/forge-setup-models.sh"
        with tempfile.TemporaryDirectory(dir=root) as d:
            home = Path(d) / "home"; vault = Path(d) / "vault"
            conf_dir = home / ".claude"; conf_dir.mkdir(parents=True)
            config = conf_dir / "forge.conf"
            config.write_text("VAULT_PATH=" + str(vault) + "\nONBOARDING_COMPLETE=false\nMODEL_TIER_KEEPER=premium\nMODEL_TIER_ARCHITECT=economy\nMODEL_KEEPER=legacy-value\n")
            catalog = vault / "_shared/model-catalog/catalog.json"; catalog.parent.mkdir(parents=True)
            old = snap([rec(name="other", tier="minimal", bindings=[{"runtime": "copilot-cli", "active": True, "dispatch_id": "other"}])])
            old["clock"]["source"] = "manual"; catalog.write_text(json.dumps(old))
            env = {**os.environ, "HOME": str(home), "VAULT_PATH": str(vault), "FORGE_RUNTIME": "claude", "FORGE_CORE": str(root / "core")}
            initial_catalog, initial_config = catalog.read_bytes(), config.read_bytes()
            for answers in ("", "1\n1\n", "1\n9\n1\n1\n"):
                result = subprocess.run(["bash", str(script)], input="model-a,model-b\n\n" + answers, text=True, capture_output=True, env=env)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(catalog.read_bytes(), initial_catalog)
                self.assertEqual(config.read_bytes(), initial_config)
            result = subprocess.run(["bash", str(script)], input="model-a,model-b\n\n1\n2\n1\n2\n", text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            updated = json.loads(catalog.read_text())
            self.assertEqual(len(updated["records"]), 5)
            self.assertEqual({r["tier"] for r in updated["records"] if r["bindings"][0]["runtime"] == "claude"}, set(("minimal", "economy", "standard", "premium")))
            self.assertEqual(updated["records"][0]["bindings"][0]["runtime"], "copilot-cli")
            self.assertEqual(config.read_bytes(), initial_config)
            self.assertFalse(list(conf_dir.glob("forge.conf.bak.*")))
            copilot_dir = home / ".copilot"
            copilot_dir.mkdir()
            copilot_config = copilot_dir / "forge.conf"
            copilot_config.write_text("VAULT_PATH=" + str(vault) + "\nONBOARDING_COMPLETE=false\nMODEL_TIER_KEEPER=economy\nMODEL_KEEPER=legacy-copilot\n")
            copilot_baseline = copilot_config.read_bytes()
            copilot_env = {**env, "FORGE_RUNTIME": "copilot-cli"}
            again = subprocess.run(["bash", str(script)], input="model-c\n\n1\n1\n1\n1\n", text=True,
                                   capture_output=True, env=copilot_env)
            self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
            self.assertEqual(copilot_config.read_bytes(), copilot_baseline)
            self.assertFalse(list(copilot_dir.glob("forge.conf.bak.*")))
            refreshed = json.loads(catalog.read_text())
            self.assertEqual(len(refreshed["records"]), 8)
            for runtime in ("claude", "copilot-cli"):
                self.assertEqual(catalog_main(["check-coverage", "--snapshot", str(catalog), "--binding", runtime]), 0)
            fresh_vault = Path(d) / "fresh-vault"
            fresh = subprocess.run(["bash", str(script)], input="single-model\n\n1\n1\n1\n1\n",
                                   text=True, capture_output=True, env={**copilot_env, "VAULT_PATH": str(fresh_vault)})
            self.assertEqual(fresh.returncode, 0, fresh.stdout + fresh.stderr)
            self.assertEqual(copilot_config.read_bytes(), copilot_baseline)
            fresh_records = json.loads((fresh_vault / "_shared/model-catalog/catalog.json").read_text())["records"]
            self.assertEqual(len(fresh_records), 4)
            self.assertEqual({r["tier"] for r in fresh_records}, set(("minimal", "economy", "standard", "premium")))
            self.assertEqual({r["bindings"][0]["runtime"] for r in fresh_records}, {"copilot-cli"})

    def test_stale_system_manual_remap_preserves_foreign_data_inactive(self):
        root = Path(__file__).resolve().parents[3]
        script = root / "core/skills/forge-setup-models/scripts/forge-setup-models.sh"
        with tempfile.TemporaryDirectory(dir=root) as d:
            home = Path(d) / "home"; conf_dir = home / ".claude"; conf_dir.mkdir(parents=True)
            config = conf_dir / "forge.conf"
            config.write_text("MODEL_TIER_KEEPER=standard\nMODEL_KEEPER=legacy\n")
            before_config = config.read_bytes()
            catalog = Path(d) / "vault/_shared/model-catalog/catalog.json"
            catalog.parent.mkdir(parents=True)
            stale = snap([rec(name="old-claude", tier="minimal", bindings=[{"runtime": "claude", "active": True, "dispatch_id": "old-claude"}]),
                          rec(name="old-copilot", tier="standard", bindings=[{"runtime": "copilot-cli", "active": True, "dispatch_id": "old-copilot"}])], stamp(-86402))
            catalog.write_text(json.dumps(stale))
            env = {**os.environ, "HOME": str(home), "VAULT_PATH": str(Path(d) / "vault"),
                   "FORGE_RUNTIME": "claude", "FORGE_CORE": str(root / "core"), "PYTHONDONTWRITEBYTECODE": "1"}
            baseline = catalog.read_bytes()
            def run(answers):
                return subprocess.run(["bash", str(script)], input="new-model\n\n" + answers,
                                      capture_output=True, text=True, env=env)
            self.assertNotEqual(run("1\n1\n").returncode, 0)
            self.assertEqual(catalog.read_bytes(), baseline)
            self.assertEqual(run("1\n1\n1\n1\n").returncode, 0)
            updated = json.loads(catalog.read_text())
            self.assertEqual(updated["clock"]["source"], "manual")
            self.assertEqual(len(updated["records"]), 5)
            foreign = next(record for record in updated["records"] if record["identity"]["id"] == "old-copilot")
            self.assertEqual(foreign["bindings"][0]["dispatch_id"], "old-copilot")
            self.assertFalse(foreign["bindings"][0]["active"])
            self.assertEqual(catalog_main(["check-coverage", "--snapshot", str(catalog), "--binding", "claude"]), 0)
            self.assertEqual(catalog_main(["check-coverage", "--snapshot", str(catalog), "--binding", "copilot-cli"]), 2)
            for invalid in ({**stale, "records": [dict(stale["records"][0], identity="bad")]},
                            {**stale, "captured_at": stamp(60)}):
                catalog.write_text(json.dumps(invalid))
                original = catalog.read_bytes()
                rejected = run("1\n1\n1\n1\n")
                self.assertNotEqual(rejected.returncode, 0, rejected.stdout + rejected.stderr)
                self.assertEqual(catalog.read_bytes(), original)
                self.assertEqual(config.read_bytes(), before_config)
            catalog.write_text("not-json")
            self.assertNotEqual(run("1\n1\n1\n1\n").returncode, 0)
            self.assertEqual(catalog.read_text(), "not-json")
            self.assertEqual(config.read_bytes(), before_config)

    def test_wrappers_default_to_own_runtime(self):
        root = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(dir=root) as d:
            home = Path(d) / "home"; vault = Path(d) / "vault"
            catalog = vault / "_shared/model-catalog/catalog.json"; catalog.parent.mkdir(parents=True)
            records = [rec(name="foreign", tier="minimal", bindings=[{"runtime": "copilot-cli", "active": True, "dispatch_id": "copilot-id"}]),
                       rec(name="local", tier="minimal", bindings=[{"runtime": "claude", "active": True, "dispatch_id": "claude-id"}])]
            data = snap(records); data["clock"]["source"] = "manual"; catalog.write_text(json.dumps(data))
            env = {**os.environ, "HOME": str(home), "VAULT_PATH": str(vault), "PYTHONDONTWRITEBYTECODE": "1"}
            for adapter, runtime, expected in (("claude-code", "claude", "claude-id"),
                                               ("copilot-cli", "copilot-cli", "copilot-id")):
                folder = home / (".claude" if runtime == "claude" else ".copilot")
                folder.mkdir(parents=True)
                (folder / "forge.conf").write_text("MODEL_TIER_KEEPER=minimal\n")
                wrapper = root / f"adapters/{adapter}/scripts/forge-model-catalog.sh"
                entry = subprocess.run(["bash", str(wrapper), "onboarding-status", "--snapshot", str(catalog),
                                        "--binding", runtime, "--config", str(folder / "forge.conf")],
                                       env=env, text=True, capture_output=True)
                self.assertEqual(entry.returncode, 0, entry.stdout + entry.stderr)
                self.assertEqual(json.loads(entry.stdout)["action"], "full-onboarding")
                def call(*args):
                    result = subprocess.run(["bash", str(wrapper), "resolve", *args], env=env,
                                            text=True, capture_output=True)
                    return result.returncode, json.loads(result.stdout)
                code, result = call("--role", "keeper")
                self.assertEqual((code, result["dispatch_id"]), (0, expected))
                code, result = call("keeper")
                self.assertEqual((code, result["dispatch_id"]), (0, expected))
                shorthand = subprocess.run(["bash", str(wrapper), "--role", "keeper"], env=env,
                                           text=True, capture_output=True)
                self.assertEqual(shorthand.returncode, 0, shorthand.stdout + shorthand.stderr)
                self.assertEqual(json.loads(shorthand.stdout)["dispatch_id"], expected)
                code, result = call("--tier", "minimal", "--binding", "copilot-cli" if runtime == "claude" else "claude")
                self.assertEqual((code, result["status"]), (3, "invalid"))
                without_local = snap([records[0] if runtime == "claude" else records[1]])
                without_local["clock"]["source"] = "manual"
                catalog.write_text(json.dumps(without_local))
                code, result = call("--role", "keeper")
                self.assertEqual((code, result["status"]), (2, "no_match"))
                catalog.write_text(json.dumps(data))

    def test_deterministic_binding_selection(self):
        bindings=[{"runtime":"z","active":True,"dispatch_id":"z"},{"runtime":"a","active":True,"dispatch_id":"a"}]
        result=resolve(snap([rec("same", bindings=bindings)]), "standard")
        self.assertEqual(result["dispatch_id"], "a")
    def test_atomic_write_and_manual_publish(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            path=os.path.join(d,"capability-snapshot.json"); write_snapshot(snap([rec()]), path); self.assertEqual(load_snapshot(path)["schema_version"],1)
            source=os.path.join(d,"input.json"); json.dump({"records": [rec()]}, open(source,"w")); publish_manual(source,path); self.assertEqual(load_snapshot(path)["clock"]["source"],"manual")
    def test_migration_backup_idempotence_and_preservation(self):
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
            config=os.path.join(d,"forge.conf"); open(config,"w").write("MODEL_KEEPER=sonnet\nMODEL_IMPL=\nOTHER=value\n")
            first=migrate_config(config); content=open(config).read(); backup=first["backup"]
            self.assertTrue(os.path.exists(backup)); self.assertIn("MODEL_TIER_KEEPER=pending", content); self.assertIn("MODEL_TIER_IMPL=inherit", content); self.assertIn("OTHER=value", content)
            migrate_config(config); self.assertEqual(content, open(config).read()); self.assertEqual(open(backup).read(), "MODEL_KEEPER=sonnet\nMODEL_IMPL=\nOTHER=value\n")
    def _write(self, data):
        fd,path=tempfile.mkstemp(dir=os.getcwd()); os.close(fd); json.dump(data, open(path,"w")); self.addCleanup(lambda: os.path.exists(path) and os.unlink(path)); return path
if __name__ == "__main__": unittest.main()
