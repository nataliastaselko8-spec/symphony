"""Actual Git/SSH-key/filesystem contracts around a framed fake worker."""
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime import config
from symphony_runtime.common import Rejected, atomic, canonical, command, digest, locked, private_dir, private_file, read_json
from symphony_runtime.controller import Controller
from symphony_runtime.guardian import PREFIX
from symphony_runtime.seed import create
from symphony_runtime.storage import GIB, bounded_log, capacity, collect, retire


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pr13-", dir=Path.home())
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        template = self.root / "project/WORKFLOW.template.md"
        template.parent.mkdir()
        template.write_text('---\n{"tracker":{"kind":"github_projects","provider":{"repo":"ExampleOrg/app","project_number":1,"item_ids":"${runtime.pilot_item_ids}"}}}\n---\nTask.\n')
        self.config = config.configure(self.root / "config/local.json", {"symphony_root": str(self.root / "source"),
            "state_root": str(self.root / "state"), "project_template": str(template)})
        config.render(self.config)
        self.image = "sha256:" + "a" * 64
        config.pin(self.config, "b" * 40, "c" * 40, self.image)
        state = Path(self.config["state_root"])
        atomic(state / "model-selection.json", canonical({"model": "fixture-model", "effort": "high"}))
        atomic(state / "model-catalog.json", canonical({"image": self.image, "queried_at": int(time.time()), "models": [{"model": "fixture-model", "efforts": ["medium", "high"]}]}))
        self.remote = self.root / "remote"
        self.remote.mkdir()
        command(["git", "init", "-qb", "dev"], cwd=self.remote)
        (self.remote / "code.txt").write_text("product fixture")
        command(["git", "add", "."], cwd=self.remote)
        command(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"], cwd=self.remote)
        self.sha = command(["git", "rev-parse", "HEAD"], cwd=self.remote).decode().strip()
        self.context = {"repo": "ExampleOrg/app", "project_number": 1, "cycle_id": "cycle", "interval_id": "interval",
                        "branch": "agent/task", "expected_dev_sha": self.sha}
        self.proof = {"phase": "idle"}
        self.calls = []
        self.ctl = Controller(self.config, transport=self.rpc,
                              seed=lambda directory, repo, expected, token: create(directory, repo, expected, token, test_remote=str(self.remote)))

    def rpc(self, config_file, host, request, body=b""):
        self.calls.append(dict(request))
        action = request["action"]
        if action == "prepare":
            self.assertNotIn("token", request)
            self.assertEqual(digest(body), request["bundle_sha256"])
            self.proof = {key: request[key] for key in ("cycle", "branch", "interval", "generation")}
            self.proof["phase"] = "prepared"
        if action == "start":
            self.proof.update(phase="running", port=12345,
                             host_public_key="ssh-ed25519 " + base64.b64encode(PREFIX + bytes(32)).decode())
        if action == "stop":
            self.proof["phase"] = "stopped"
        if action == "export":
            raw = b"candidate-fixture"
            return {**self.proof, "sha": request["sha"], "size": len(raw), "sha256": digest(raw)}, raw
        if action == "retire":
            return {"retired": request["cycle"]}, b""
        return {**self.proof, "image": self.image, "profile_revision": "c" * 40, "runtime_contract": "2", "network_ready": True, "auth_present": True, "free_bytes": 100 * GIB}, b""

    def prepare(self):
        return self.ctl.prepare({"action": "prepare", "context": self.context, "token": "fixture-secret"})

    def operation(self, action, **extra):
        return self.ctl.operation({"action": action, "cycle": "cycle", "interval": "interval", "generation": "interval", **extra})

    def test_prepare_transfers_actual_full_history_without_checkout_or_token_persistence(self):
        self.assertTrue(self.ctl.ready()["ready"])
        self.prepare()
        directory = self.ctl.directory("interval")
        heads = command(["git", "bundle", "list-heads", str(directory / "seed.bundle")]).decode().strip()
        self.assertEqual(heads, self.sha + " refs/heads/dev")
        self.assertFalse((directory / "code.txt").exists())
        for file in self.root.joinpath("state").rglob("*"):
            if file.is_file():
                self.assertNotIn(b"fixture-secret", file.read_bytes())
        self.assertEqual(self.prepare()["phase"], "prepared")

    def test_windows_capacity_blocks_admission_and_active_heartbeat_without_losing_owner(self):
        from symphony_runtime import windows_storage
        self.config["windows_installation_id"] = "a" * 32
        self.assertIn("windows_disk_unknown", self.ctl.ready()["reasons"])
        with self.assertRaisesRegex(Rejected, "worker_not_ready"):
            self.prepare()
        root = Path(self.config["state_root"])
        atomic(root / "launcher.json", canonical({"token": "fixture"}))
        frame = {"schema_version": 1, "installation_id": "a" * 32, "manager_token": "b" * 32,
                 "measured_at_ms": int(time.time() * 1000), "disks": {
                     role: {"distro": None, "volume": "volume:12345678-1234-1234-1234-123456789abc",
                            "free_bytes": 100 * GIB, "error": None} for role in ("controller", "worker")}}
        windows_storage.retain(frame, self.config, "b" * 32, "fixture")
        self.prepare()
        self.operation("start", active_ms=120000)
        saved = (root / "worker.json").read_bytes()
        frame["disks"]["worker"]["free_bytes"] = 2 * GIB
        windows_storage.retain(frame, self.config, "b" * 32, "fixture")
        health = self.operation("heartbeat")
        self.assertFalse(health["ready"])
        self.assertIn("windows_disk_space_low", health["reasons"])
        self.operation("stop")
        self.assertEqual((root / "worker.json").read_bytes(), saved)
        self.assertTrue((root / "bindings/interval.json").exists())

    def test_start_binds_pinned_ssh_and_remaining_budget_and_stop_revokes_endpoint(self):
        self.prepare()
        result = self.operation("start", active_ms=20100)
        self.assertEqual(self.calls[-1]["active_seconds"], 20)
        self.assertEqual(result["workspace"], "/workspace/repo")
        text = private_file(result["ssh_config"]).read_text()
        for required in ("HostName 127.0.0.1", "StrictHostKeyChecking yes", "ForwardAgent no", "ClearAllForwardings yes"):
            self.assertIn(required, text)
        self.operation("stop")
        with self.assertRaisesRegex(Rejected, "revoked"):
            self.operation("start", active_ms=20000)
        with self.assertRaisesRegex(Rejected, "revoked"):
            self.prepare()

    def test_foreign_interval_and_generation_never_reach_remote(self):
        self.prepare()
        count = len(self.calls)
        with self.assertRaisesRegex(Rejected, "stale"):
            self.ctl.operation({"action": "stop", "cycle": "cycle", "interval": "foreign", "generation": "interval"})
        self.assertEqual(len(self.calls), count)

    def test_loss_after_prepare_retains_intent_and_same_key_for_readback(self):
        actual = self.ctl.rpc
        def lost(request, body=b""):
            proof = actual(request, body)
            if request["action"] == "prepare":
                raise Rejected("reply_lost")
            return proof
        with patch.object(self.ctl, "rpc", side_effect=lost), self.assertRaises(Rejected):
            self.prepare()
        first_key = private_file(self.ctl.directory("interval") / "task_key").read_bytes()
        self.assertEqual(self.ctl.current()["interval"], "interval")
        self.prepare()
        self.assertEqual(first_key, private_file(self.ctl.directory("interval") / "task_key").read_bytes())

    def test_stop_during_prepare_cannot_confirm_idle_until_sender_is_quiescent(self):
        self.prepare()
        self.proof = {"phase": "idle"}
        with locked(self.ctl.root / "prepare.lock"), self.assertRaisesRegex(Rejected, "already_running"):
            self.operation("stop")
        self.assertTrue((self.ctl.directory("interval") / "revoked").exists())
        self.assertEqual(self.operation("stop")["phase"], "stopped")

    def test_changed_dev_rejects_seed_and_no_worker_is_prepared(self):
        self.context["expected_dev_sha"] = "f" * 40
        with self.assertRaisesRegex(Rejected, "dev_changed"):
            self.prepare()
        self.assertFalse(any(call["action"] == "prepare" for call in self.calls))
        self.assertEqual(self.ctl.current()["base_sha"], "f" * 40)

    def test_export_is_persisted_and_matches_the_requested_head(self):
        self.prepare()
        self.operation("start", active_ms=20000)
        self.operation("stop")
        result = self.operation("export", sha=self.sha)
        self.assertEqual(private_file(result["path"]).read_bytes(), b"candidate-fixture")
        self.assertEqual(self.operation("export", sha=self.sha), result)

    def test_old_inspection_manifest_and_empty_pilot_do_not_activate_execution(self):
        self.assertEqual(config.workflow_settings(self.config)["tracker"]["provider"]["item_ids"], [])
        with self.assertRaisesRegex(Rejected, "controller_role"):
            config.pin(self.config, "a" * 40, "b" * 40, self.image, execute=True)
        with self.assertRaises(Rejected):
            self.ctl.dispatch({"action": "prepare", "context": self.context, "token": "fixture"})

    def test_low_disk_closes_new_admission_without_deleting_work(self):
        self.prepare()
        self.operation("stop")
        usage = type("Usage", (), {"free": 1})()
        with patch("symphony_runtime.storage.shutil.disk_usage", return_value=usage):
            report = self.ctl.ready()
            self.assertFalse(report["ready"])
            self.assertIn("disk_space_low", report["reasons"])
        self.assertTrue((self.ctl.directory("interval") / "seed.bundle").exists())


class StorageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pr13-storage-", dir=Path.home())
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def task(self, cycle):
        private_dir(self.root / "workspaces", create=True)
        path = private_dir(self.root / "workspaces" / cycle, create=True)
        (path / "unpublished.txt").write_text("preserve")
        return path

    def test_only_completed_cycle_after_retention_is_collected_and_report_survives(self):
        completed, cancelled = self.task("completed"), self.task("cancelled")
        report = {"cycle": "completed", "outcome": "completed", "generations": []}
        retire(self.root, "completed", report, now=100)
        self.assertEqual(collect(self.root, now=100 + 6 * 86400, dry_run=False), [])
        self.assertEqual(collect(self.root, active_cycle="completed", now=100 + 8 * 86400, dry_run=False), [])
        self.assertEqual(collect(self.root, now=100 + 8 * 86400), ["workspaces/completed"])
        self.assertTrue(completed.exists())
        collect(self.root, now=100 + 8 * 86400, dry_run=False)
        self.assertFalse(completed.exists())
        self.assertTrue(cancelled.exists())
        self.assertTrue((self.root / "reports/completed.json").exists())
        with self.assertRaises(Rejected):
            retire(self.root, "cancelled", {"cycle": "cancelled", "outcome": "cancelled"})

    def test_cleanup_rejects_tampering_or_linked_root_and_cannot_follow_inner_symlink(self):
        task = self.task("cycle")
        external = private_dir(self.root / "external", create=True)
        (external / "keep").write_text("keep")
        (task / "link").symlink_to(external, target_is_directory=True)
        retire(self.root, "cycle", {"cycle": "cycle", "outcome": "completed"}, now=100)
        collect(self.root, now=100 + 8 * 86400, dry_run=False)
        self.assertEqual((external / "keep").read_text(), "keep")
        report = self.root / "reports/cycle.json"
        value = read_json(report)
        value["report"]["cycle"] = "other"
        atomic(report, canonical(value))
        with self.assertRaises(Rejected):
            collect(self.root, now=100 + 8 * 86400, dry_run=False)

    def test_log_rotation_and_capacity_are_bounded(self):
        path = self.root / "log"
        for _ in range(20):
            bounded_log(path, b"x" * 100, maximum=100, copies=2)
        self.assertEqual(len(list(self.root.glob("log*"))), 3)
        self.assertLessEqual(sum(p.stat().st_size for p in self.root.glob("log*")), 300)
        self.assertIn(capacity(self.root)["status"], ("ready", "warning", "blocked"))
