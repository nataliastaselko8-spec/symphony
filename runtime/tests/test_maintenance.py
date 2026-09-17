"""Retention and credential lifetimes are independent from business-task terminal states."""
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import base64
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.common import Rejected, atomic, canonical, command, private_dir, read_json
from symphony_runtime.guardian import Guardian, PREFIX
from symphony_runtime.controller import Controller
from symphony_runtime import maintenance
from symphony_runtime.images import namespace, collect_images
from symphony_runtime.storage import collect, retire


class MaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.home(), prefix="pr13-maintenance-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def guardian(self):
        value = object.__new__(Guardian)
        value.root = self.root
        value.image = "sha256:" + "a" * 64
        value.cgroup = "/system.slice/symphony-fixture.service"
        value.clock = lambda: 1
        value.started_at = None
        value.mutex = threading.RLock()
        value.record = {"cycle": "cycle", "interval": "interval", "generation": "generation", "branch": "agent/task", "repo": "Example/app", "container": "symphony-job-generation", "cgroup": None, "phase": "running", "reason": None}
        return value

    def test_auth_refresh_survives_stopped_session_and_never_copies_entire_home(self):
        value = self.guardian()
        central = private_dir(self.root / "auth", create=True)
        auth = value.path("codex", "cycle")
        atomic(central / "auth.json", b'{"fixture":"old"}')
        atomic(auth / "auth.json", b'{"fixture":"new"}')
        atomic(auth / "history.jsonl", b"private run history")
        with patch.object(value, "pod"), patch.object(value, "summary", side_effect=lambda: dict(value.record)):
            proof = value.stop("handoff")
        self.assertEqual(proof["phase"], "stopped")
        self.assertEqual(read_json(central / "auth.json"), {"fixture": "new"})
        self.assertFalse((central / "history.jsonl").exists())
        self.assertTrue((auth / "history.jsonl").exists())

    def test_login_restores_stopped_task_and_removes_only_bootstrap_data(self):
        value = self.guardian()
        previous = {**value.record, "phase": "exported"}
        task = value.path("workspaces", "cycle")
        (task / "unpublished").write_text("keep")
        generation = "login-fixture"
        value.record = {**value.record, "purpose": "login", "previous": previous, "cycle": generation,
                        "generation": generation, "interval": generation, "container": "symphony-job-" + generation}
        for category in ("workspaces", "keys", "codex"):
            value.path(category, generation)
        atomic(value.path("codex", generation) / "auth.json", b'{"fixture":"login"}')
        with patch.object(value, "pod"), patch.object(value, "summary", side_effect=lambda: dict(value.record)):
            proof = value.stop("login_complete")
        self.assertEqual(proof["generation"], generation)
        self.assertEqual(value.record, previous)
        self.assertFalse((self.root / "keys" / generation).exists())
        self.assertEqual((task / "unpublished").read_text(), "keep")
        self.assertEqual(read_json(self.root / "auth/auth.json"), {"fixture": "login"})
        repeated, _ = value.dispatch({"action": "stop", "generation": generation, "interval": generation})
        self.assertEqual(repeated["phase"], "stopped")
        # Re-checking the old product resource must not overwrite the newer login.
        atomic(value.path("codex", "cycle") / "auth.json", b'{"fixture":"stale"}')
        with patch.object(value, "pod"), patch.object(value, "summary", side_effect=lambda: dict(value.record)):
            value.stop("again")
        self.assertEqual(read_json(self.root / "auth/auth.json"), {"fixture": "login"})

    def test_catalog_bootstrap_removes_only_confirmed_stopped_login_keys(self):
        calls = []
        current = {}
        def rpc(request):
            calls.append(request["action"])
            if request["action"] == "login_prepare":
                current.update(request)
            return {"generation": current["generation"], "phase": "running" if request["action"] == "start" else "stopped",
                    "port": 23456, "host_public_key": "ssh-ed25519 " + base64.b64encode(PREFIX + bytes(32)).decode()}, b""
        ctl = SimpleNamespace(root=self.root, manifest={"worker_image": "image"},
                              recover=lambda: {"phase": "idle", "reasons": []}, rpc=rpc, ssh_config=Controller.ssh_config)
        def run(argv, **kwargs):
            if argv[0] == "ssh-keygen":
                return command(argv, **kwargs)
            if argv[-1] == "true":
                return b""
            self.assertEqual(argv[-1], "python3 -I -B -")
            self.assertIn(b'"model/list"', kwargs["input_data"])
            return canonical({"data": [{"model": "fixture", "supportedReasoningEfforts": [{"reasoningEffort": "high"}]}]})
        with patch.object(maintenance, "Controller", return_value=ctl), patch.object(maintenance, "command", side_effect=run):
            result = maintenance.login({}, discover=True)
            self.assertTrue(result["worker_stopped"])
            self.assertEqual(list((self.root / "login").iterdir()), [])
            self.assertEqual(maintenance.select_model({}, "fixture", "high")["selected"], {"model": "fixture", "effort": "high"})
        self.assertEqual(calls, ["login_prepare", "start", "stop"])
        self.assertTrue((self.root / "model-catalog.json").exists())

    def test_retirement_cannot_claim_foreign_generation_or_cancelled_cycle(self):
        value = self.guardian()
        value.record["phase"] = "stopped"
        keys = value.path("keys", "generation")
        atomic(keys / "binding.json", canonical({"generation": "generation", "cycle": "foreign"}))
        request = {"action": "retire", "cycle": "cycle", "retention_days": 7,
                   "report": {"cycle": "cycle", "outcome": "completed", "generations": ["generation"]}}
        with self.assertRaisesRegex(Rejected, "owner_mismatch"):
            value.dispatch(request)
        self.assertFalse((self.root / "reports").exists())

    def test_recorded_retention_cannot_be_shortened_by_restart_defaults(self):
        private_dir(self.root / "workspaces", create=True)
        task = private_dir(self.root / "workspaces/cycle", create=True)
        retire(self.root, "cycle", {"cycle": "cycle", "outcome": "completed"}, now=1, retention_days=30)
        self.assertEqual(collect(self.root, now=8 * 86400, dry_run=False), [])
        self.assertTrue(task.exists())

    def test_image_cleanup_uses_owned_tags_skips_containers_and_never_prunes_shared_store(self):
        image = "sha256:" + "b" * 64
        tag = namespace(self.root) + "b" * 64
        atomic(self.root / "images.json", canonical({tag: {"image": image, "registered_at": 1}}))
        calls = []
        def pod(*args):
            calls.append(args)
            if args[:2] == ("image", "inspect"):
                return json.dumps([{"Id": image, "RepoTags": [tag, "localhost/other-install:kept"]}]).encode()
            return b"[]"
        self.assertEqual(collect_images(self.root, "sha256:" + "a" * 64, pod, now=8 * 86400), [tag])
        self.assertFalse(any(args[:2] == ("image", "rm") for args in calls))
        collect_images(self.root, "sha256:" + "a" * 64, pod, now=8 * 86400, dry_run=False)
        self.assertIn(("image", "rm", "--no-prune", tag), calls)
        self.assertFalse(any("prune" in args or "--force" in args or image in args for args in calls))
        atomic(self.root / "images.json", canonical({"localhost/foreign:tag": {"image": image, "registered_at": 1}}))
        with self.assertRaisesRegex(Rejected, "foreign_image"):
            collect_images(self.root, "current", pod, now=8 * 86400, dry_run=False)
