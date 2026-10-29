import json
import os
import tempfile
import unittest
from pathlib import Path
from model_catalog.agents import current_model, render_agents, with_model
from model_catalog.cli import main as catalog_main
from model_catalog.catalog import write_snapshot
from model_catalog.tests.test_catalog import rec, snap

AGENT = "---\nname: forge-{role}\ndescription: d\ntools: [\"read\"]\n---\n\n# Body\nmodel: not frontmatter\n"


class RenderAgentsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.agents = root / "agents"
        self.agents.mkdir()
        for role in ("keeper", "reviewer"):
            (self.agents / f"forge-{role}.agent.md").write_text(AGENT.format(role=role))
        self.snapshot = str(root / "catalog.json")
        write_snapshot(snap([
            rec("small", "minimal", bindings=[{"runtime": "copilot-cli", "active": True, "dispatch_id": "small-1"}]),
            rec("big", "standard", bindings=[{"runtime": "copilot-cli", "active": True, "dispatch_id": "big-1"}]),
        ]), self.snapshot)
        self.config = root / "forge.conf"
        self.config.write_text("MODEL_TIER_KEEPER=minimal\nMODEL_TIER_REVIEWER=standard\n")

    def render(self, **kwargs):
        return render_agents(self.snapshot, str(self.config), "copilot-cli", str(self.agents), **kwargs)

    def text(self, role):
        return (self.agents / f"forge-{role}.agent.md").read_text()

    def test_writes_model_into_frontmatter_only(self):
        rows = {row["role"]: row for row in self.render()}
        self.assertEqual(rows["keeper"]["action"], "written")
        self.assertEqual(current_model(self.text("keeper")), "small-1")
        self.assertEqual(current_model(self.text("reviewer")), "big-1")
        self.assertIn("model: not frontmatter", self.text("keeper"))
        self.assertEqual(self.text("keeper").count("model:"), 2)

    def test_idempotent_and_check_reports_drift(self):
        self.render()
        self.assertTrue(all(row["action"] == "unchanged" for row in self.render()))
        self.config.write_text("MODEL_TIER_KEEPER=standard\nMODEL_TIER_REVIEWER=standard\n")
        rows = {row["role"]: row for row in self.render(check=True)}
        self.assertEqual(rows["keeper"]["action"], "drift")
        self.assertEqual(current_model(self.text("keeper")), "small-1")

    def test_inherit_removes_model(self):
        self.render()
        self.config.write_text("MODEL_TIER_KEEPER=inherit\nMODEL_TIER_REVIEWER=standard\n")
        self.render()
        self.assertIsNone(current_model(self.text("keeper")))
        self.assertEqual(current_model(self.text("reviewer")), "big-1")

    def test_unresolvable_binding_leaves_file_untouched(self):
        before = self.text("keeper")
        self.config.write_text("MODEL_TIER_KEEPER=premium\nMODEL_TIER_REVIEWER=standard\n")
        rows = {row["role"]: row for row in self.render()}
        self.assertEqual(rows["keeper"]["action"], "error")
        self.assertEqual(self.text("keeper"), before)

    def test_stale_binding_is_an_error(self):
        rows = {row["role"]: row for row in self.render(available=["big-1"])}
        self.assertEqual(rows["keeper"]["action"], "error")
        self.assertEqual(rows["keeper"]["status"], "stale_binding")
        self.assertEqual(rows["reviewer"]["action"], "written")

    def test_cli_exit_codes(self):
        base = ["render-agents", "--snapshot", self.snapshot, "--config", str(self.config),
                "--binding", "copilot-cli", "--src-dir", str(self.agents)]
        self.assertEqual(catalog_main([*base, "--check"]), 5)
        self.assertEqual(catalog_main(base), 0)
        self.assertEqual(catalog_main([*base, "--check"]), 0)

    def test_with_model_requires_frontmatter(self):
        with self.assertRaises(ValueError):
            with_model("no frontmatter\n", "x")


if __name__ == "__main__":
    unittest.main()
