import datetime as dt
import json
import os
import tempfile
import unittest
from unittest import mock
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
        with tempfile.TemporaryDirectory() as d:
            config = os.path.join(d, "forge.conf")
            with open(config, "w") as stream: stream.write("MODEL_KEEPER=sonnet\n")
            migrate_config(config)
            self.assertEqual(tier_from_config(config, "keeper"), "pending")
            data = snap([rec(tier="premium")])
            self.assertEqual(resolve(data, tier="premium", role="keeper")["status"], "resolved")
    def test_canonical_precedence_and_legacy_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            shared = os.path.join(d, "_shared")
            os.makedirs(os.path.join(shared, "model-catalog"))
            legacy = os.path.join(shared, "capability-snapshot.json")
            json.dump(snap([rec(name="legacy")]), open(legacy, "w"))
            with mock.patch.dict(os.environ, {"VAULT_PATH": d}):
                self.assertEqual(load_snapshot()["records"][0]["identity"]["id"], "legacy")
                json.dump(snap([rec(name="canonical")]), open(catalog_path(d), "w"))
                self.assertEqual(load_snapshot()["records"][0]["identity"]["id"], "canonical")

    def test_canonical_invalid_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "_shared", "model-catalog"))
            json.dump(snap([rec(name="legacy")]), open(os.path.join(d, "_shared", "capability-snapshot.json"), "w"))
            with mock.patch.dict(os.environ, {"VAULT_PATH": d}):
                open(catalog_path(d), "w").write("not json")
                with self.assertRaises(SnapshotError): load_snapshot()
                stale = snap([], stamp(-86401)); json.dump(stale, open(catalog_path(d), "w"))
                with self.assertRaises(SnapshotError): load_snapshot()

    def test_explicit_legacy_path_remains_supported(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "capability-snapshot.json")
            json.dump(snap([rec(name="legacy")]), open(path, "w"))
            self.assertEqual(load_snapshot(path)["records"][0]["identity"]["id"], "legacy")

    def test_stale_and_future(self):
        with self.assertRaises(SnapshotError): load_snapshot(self._write(snap([], stamp(-86401))))
        with self.assertRaises(SnapshotError): load_snapshot(self._write(snap([], stamp(2))))
    def test_deterministic_binding_selection(self):
        bindings=[{"runtime":"z","active":True,"dispatch_id":"z"},{"runtime":"a","active":True,"dispatch_id":"a"}]
        result=resolve(snap([rec("same", bindings=bindings)]), "standard")
        self.assertEqual(result["dispatch_id"], "a")
    def test_atomic_write_and_manual_publish(self):
        with tempfile.TemporaryDirectory() as d:
            path=os.path.join(d,"capability-snapshot.json"); write_snapshot(snap([rec()]), path); self.assertEqual(load_snapshot(path)["schema_version"],1)
            source=os.path.join(d,"input.json"); json.dump({"records": [rec()]}, open(source,"w")); publish_manual(source,path); self.assertEqual(load_snapshot(path)["clock"]["source"],"manual")
    def test_migration_backup_idempotence_and_preservation(self):
        with tempfile.TemporaryDirectory() as d:
            config=os.path.join(d,"forge.conf"); open(config,"w").write("MODEL_KEEPER=sonnet\nMODEL_IMPL=\nOTHER=value\n")
            first=migrate_config(config); content=open(config).read(); backup=first["backup"]
            self.assertTrue(os.path.exists(backup)); self.assertIn("MODEL_TIER_KEEPER=pending", content); self.assertIn("MODEL_TIER_IMPL=inherit", content); self.assertIn("OTHER=value", content)
            migrate_config(config); self.assertEqual(content, open(config).read()); self.assertEqual(open(backup).read(), "MODEL_KEEPER=sonnet\nMODEL_IMPL=\nOTHER=value\n")
    def _write(self, data):
        fd,path=tempfile.mkstemp(); os.close(fd); json.dump(data, open(path,"w")); self.addCleanup(lambda: os.path.exists(path) and os.unlink(path)); return path
if __name__ == "__main__": unittest.main()
