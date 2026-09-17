"""No model aliases/default effort or mutable in-flight selections."""
import os
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime import models
from symphony_runtime.common import Rejected, atomic, canonical, private_dir


class ModelsTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=Path.home())
        self.addCleanup(temporary.cleanup)
        self.root = private_dir(temporary.name)
        self.choice = {"model": "available-fixture", "effort": "high"}
        self.catalog = [{"model": "available-fixture", "supportedReasoningEfforts": [{"reasoningEffort": "high"}, {"reasoningEffort": "medium"}]}]
        atomic(self.root / "model-catalog.json", canonical({"image": "image", "queried_at": int(time.time()), "models": models.normalize(self.catalog)}))

    def choose(self, choice=None):
        atomic(self.root / "model-selection.json", canonical(choice or self.choice))

    def test_no_choice_no_implicit_default_and_supported_effort_is_model_specific(self):
        self.assertEqual(models.ready(self.root, "image")["reasons"], ["model_selection_required"])
        self.choose()
        self.assertFalse(models.ready(self.root, "image")["reasons"])
        for choice, reason in [({"model": "missing", "effort": "high"}, "selected_model_unavailable"),
                               ({"model": "available-fixture", "effort": "extreme"}, "selected_effort_unavailable")]:
            self.choose(choice)
            self.assertEqual(models.ready(self.root, "image")["reasons"], [reason])

    def test_cycle_pins_survive_restart_and_prevent_changed_model_or_effort(self):
        self.choose()
        self.assertEqual(models.bind(self.root, "cycle", "Org/app", "image"), self.choice)
        self.assertEqual(models.bound(self.root, "cycle", "Org/app"), self.choice)
        self.choose({**self.choice, "effort": "medium"})
        with self.assertRaisesRegex(Rejected, "cycle_model_selection_changed"):
            models.bind(self.root, "cycle", "Org/app", "image")
        with self.assertRaisesRegex(Rejected, "cycle_model_selection_changed"):
            models.bound(self.root, "cycle", "Org/app")
        self.choose()
        self.assertEqual(models.bind(self.root, "cycle", "Org/app", "image"), self.choice)

    def test_only_exact_acknowledgement_is_persisted_and_scope_is_immutable(self):
        self.choose()
        models.bind(self.root, "cycle", "Org/app", "image")
        with self.assertRaisesRegex(Rejected, "application_mismatch"):
            models.applied(self.root, "cycle", "interval", "Org/app", {**self.choice, "effort": "medium"})
        self.assertFalse((self.root / "model-receipts").exists())
        self.assertEqual(models.applied(self.root, "cycle", "interval", "Org/app", self.choice), self.choice)
        self.assertEqual(models.applied(self.root, "cycle", "interval", "Org/app", self.choice), self.choice)
        with self.assertRaisesRegex(Rejected, "model_cycle_mismatch"):
            models.bound(self.root, "cycle", "Other/app")

    def test_catalog_expires_and_is_bound_to_accepted_worker_image(self):
        self.choose()
        self.assertEqual(models.ready(self.root, "other")["reasons"], ["model_catalog_refresh_required"])
        with patch("time.time", return_value=time.time() + 86402):
            self.assertEqual(models.ready(self.root, "image")["reasons"], ["model_catalog_refresh_required"])
        for data in [[], self.catalog * 2, [{**self.catalog[0], "hidden": True}], [{"model": "bad", "supportedReasoningEfforts": "high"}]]:
            with self.assertRaises(Rejected):
                models.normalize(data)
        for value in [{}, {"model": "x", "effort": None}, {"model": "x\n", "effort": "high"}]:
            with self.assertRaises(Rejected):
                models.pair(value)

    def test_real_stdio_catalog_paginates_without_starting_a_thread_or_turn(self):
        script = Path(__file__).resolve().parents[1] / "scripts/model_catalog.py"
        spec = importlib.util.spec_from_file_location("catalog_probe", script)
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        trace = self.root / "trace"
        executable = self.root / "codex"
        executable.write_text("#!/usr/bin/python3\n" + "\n".join([
            "import json,sys",
            "if sys.argv[1:]==['login','status']: raise SystemExit(0)",
            "for line in sys.stdin:",
            " value=json.loads(line)",
            " with open(" + repr(str(trace)) + ", 'a') as f: f.write(json.dumps(value)+'\\n')",
            " if 'id' not in value: continue",
            " result={}",
            " if value['method']=='model/list':",
            "  result={'data':[], 'nextCursor':'next'} if value['params']['cursor'] is None else {'data':" + repr(self.catalog) + ", 'nextCursor':None}",
            " print(json.dumps({'id':value['id'],'result':result}),flush=True)",
        ]) + "\n")
        executable.chmod(0o700)
        with patch.dict(os.environ, {"PATH": str(self.root) + ":" + os.environ["PATH"]}):
            self.assertEqual(probe.query()["data"], self.catalog)
        calls = [json.loads(line)["method"] for line in trace.read_text().splitlines()]
        self.assertEqual(calls, ["initialize", "initialized", "model/list", "model/list"])


if __name__ == "__main__":
    unittest.main()
