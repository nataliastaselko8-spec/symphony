"""Private state migration, interruption and rollback boundaries; no live services."""
import copy
import importlib.util
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch

import test_operator as fixture

spec = importlib.util.spec_from_file_location("symphony_update", Path(__file__).parents[1] / "update.py")
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)
operator, config = fixture.operator, fixture.config
atomic, canonical, private_dir = fixture.atomic, fixture.canonical, fixture.private_dir


class UpdateTest(unittest.TestCase):
    def setUp(self):
        fixture.OperatorTest.setUp(self)
        operator.setup(self.data, self.info)
        self.config = config.load(self.file)
        self.source_state = Path(self.config["state_root"])
        self.data.update(installation_id="d" * 32, install_home="C:\\fixture")
        atomic(self.source_state / "delivery.json", b"retained original journal")
        atomic(self.source_state / "model-selection.json", canonical({"model": "fixture", "effort": "high"}))
        atomic(self.source_state / "model-catalog.json", b"old image catalog")
        atomic(self.source_state / "last_shutdown.json", canonical({"stopped": True, "identity": operator.stop_identity(self.config)}))
        private_dir(self.source_state / "reports", create=True)
        atomic(self.source_state / "reports/complete", b"old evidence")
        self.after = copy.deepcopy(self.data)
        directory = self.root / "update"
        self.after["controller"]["config"] = str(directory / "local.json")
        self.after["pins"]["worker_image"] = "sha256:" + "e" * 64
        self.after["runtime_config"] = {**self.config, "windows_installation_id": self.data["installation_id"],
            "state_root": str(self.root / "updated-state"), "workflow": str(directory / "WORKFLOW.md"), "manifest": str(directory / "deployment.json")}
        self.request = {"before": self.data, "after": self.after, "release": "f" * 24}
        self.target = Path(self.after["runtime_config"]["state_root"])
        for target in (patch.object(operator, "pilot_source_idle", return_value={"kind": "completed", "cycle_id": "old"}),
                       patch.object(update, "migration", side_effect=self.migrate)):
            target.start()
            self.addCleanup(target.stop)

    def migrate(self, before, after, _):
        update.immutable(self.target / "delivery.json", b"new replayed journal")
        return {"migrated": True, "revision": 10}

    def prepared(self):
        return update.prepare(self.request, operator)

    def finish_maintenance(self):
        atomic(self.target / "model-catalog.json", canonical({"image": self.after["pins"]["worker_image"],
            "queried_at": int(time.time()), "models": [{"model": "fixture", "efforts": ["high"]}]}))
        atomic(self.target / "last_shutdown.json", canonical({"stopped": True, "identity": operator.stop_identity(self.after["runtime_config"])}))

    def test_repeated_prepare_preserves_original_and_backup(self):
        original = update.inventory(self.source_state)
        for _ in range(2):
            self.assertTrue(self.prepared()["prepared"])
            self.assertEqual(update.inventory(self.source_state), original)
        backup = Path(self.after["controller"]["config"]).parent / "backup/state"
        self.assertEqual(update.inventory(backup), original)
        self.assertEqual((self.target / "reports/complete").read_bytes(), b"old evidence")
        self.assertFalse((self.target / "model-catalog.json").exists())
        self.assertEqual((self.target / "model-selection.json").read_bytes(), (self.source_state / "model-selection.json").read_bytes())

    def test_interrupted_migration_resumes_and_changed_source_is_refused(self):
        with patch.object(update, "migration", side_effect=ValueError("interrupted")):
            with self.assertRaisesRegex(ValueError, "interrupted"):
                self.prepared()
        self.assertTrue(self.prepared()["prepared"])
        atomic(self.source_state / "reports/complete", b"new retained evidence")
        with self.assertRaisesRegex(ValueError, "prepared_update_changed"):
            self.prepared()
        self.assertEqual((self.target / "reports/complete").read_bytes(), b"old evidence")

    def test_rollback_refuses_use_new_state_or_original_state_changes(self):
        self.prepared()
        self.finish_maintenance()
        self.assertTrue(update.checkpoint(self.request, operator)["rollback_allowed"])
        self.assertTrue(update.checkpoint(self.request, operator, verify=True)["rollback_allowed"])
        atomic(self.target / "update-used.json", b"started")
        with self.assertRaisesRegex(ValueError, "rollback_after_start_forbidden"):
            update.checkpoint(self.request, operator, verify=True)
        (self.target / "update-used.json").unlink()
        atomic(self.target / "reports/new", b"new task output")
        with self.assertRaisesRegex(ValueError, "rollback_state_changed"):
            update.checkpoint(self.request, operator, verify=True)
        (self.target / "reports/new").unlink()
        atomic(self.source_state / "reports/complete", b"changed source")
        with self.assertRaisesRegex(ValueError, "rollback_state_changed"):
            update.checkpoint(self.request, operator, verify=True)

    def test_missing_model_changed_settings_active_source_and_links_are_rejected(self):
        for key, value in (("pilot_item_ids", ["different"]), ("disk_minimum_bytes", 8 * 1024**3)):
            changed = copy.deepcopy(self.request)
            changed["after"]["runtime_config"][key] = value
            with self.assertRaisesRegex(ValueError, "operator_settings"):
                update.prepare(changed, operator)
        (self.source_state / "reports/link").symlink_to(self.file)
        with self.assertRaises(fixture.Rejected):
            self.prepared()
        (self.source_state / "reports/link").unlink()
        with patch.object(operator, "pilot_source_idle", side_effect=operator.Refused("active_cycle")):
            with self.assertRaisesRegex(operator.Refused, "active_cycle"):
                self.prepared()
        self.prepared()
        with self.assertRaisesRegex(fixture.Rejected, "model_catalog_required"):
            update.checkpoint(self.request, operator)


if __name__ == "__main__":
    unittest.main()
