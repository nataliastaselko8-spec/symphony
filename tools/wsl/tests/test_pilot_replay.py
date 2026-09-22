"""Opt-in real Python -> Elixir -> private Store integration; no GitHub or worker calls."""
import importlib.util
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "runtime/lib"))
from symphony_runtime.common import atomic, canonical, private_dir

spec = importlib.util.spec_from_file_location("pilot_operator", REPO / "tools/wsl/operator.py")
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)
spec = importlib.util.spec_from_file_location("pilot_update", REPO / "tools/wsl/update.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


@unittest.skipUnless(os.environ.get("SYMPHONY_PILOT_REPLAY") == "1", "set SYMPHONY_PILOT_REPLAY=1 with Elixir/OTP available")
class PilotReplayTest(unittest.TestCase):
    def test_actual_completed_journal_legacy_pending_confirmed_and_corruption(self):
        with tempfile.TemporaryDirectory(prefix="symphony-pilot-replay-", dir=Path.home()) as directory:
            root = private_dir(directory)
            path = root / "delivery.json"
            workflow = root / "WORKFLOW.md"
            raw = {"tracker": {"kind": "github_projects", "provider": {
                "organization": "ExampleOrg", "repo": "ExampleOrg/app", "project_number": 1,
                "token": "fixture-inspection-token", "item_ids": ["item-A"], "agent_allowed_value": "yes",
                "states": {"ready": "Ready for agent", "working": "Agent working", "blocked": "Needs human decision", "handoff": "PR ready"}},
                "active_states": ["Ready for agent", "Agent working"], "terminal_states": ["Done"]},
                "workspace": {"root": "/worker/workspaces"}, "delivery": {"state_path": str(path)}}
            atomic(workflow, b"---\n" + canonical(raw) + b"\n---\nFixture.\n")
            config = {"state_root": str(root), "workflow": str(workflow), "symphony_root": str(REPO), "app_key": str(root / "unused-fixture.pem")}
            data = {"controller": {"mise": shutil.which("mise")}, "github_app": {"app_id": "123", "client_id": "Fixture", "installation_id": "456"}}
            expression = r'''
            Code.require_file("test/support/delivery_gate_support.exs")
            alias SymphonyElixir.{Config.Schema, Workflow}
            alias SymphonyElixir.DeliveryGate.{Settings, Snapshot, Store}
            alias SymphonyElixir.DeliveryGateSupport, as: G
            {:ok, workflow} = Workflow.load(System.fetch_env!("PILOT_TEST_WORKFLOW"))
            {:ok, config} = Schema.parse(workflow.config)
            {:ok, gate} = Settings.from_config(config)
            mode = System.fetch_env!("PILOT_TEST_MODE")
            commands = [{"bootstrap", G.validation()}, {"reserve", G.task()}, {"reserve_ci", G.ci_request()},
              {"observe_ci", G.ci_result()}, {"handoff", %{"pr_number" => 7, "sha" => G.sha("b")}},
              {"merged", %{"pr_number" => 7, "sha" => G.sha("c")}}, {"deployment", G.deployment()}, {"validate_dev", G.passed()}]
            complete = if mode == "legacy", do: {"complete", G.proof("c")}, else:
              {"status_transition", %{"action" => "complete", "args" => G.proof("c"), "from" => "Dev validation", "repo" => "ExampleOrg/app", "reason" => "Validated"}}
            snapshot = Enum.reduce(commands ++ [complete], Snapshot.new(gate.scope), fn {action, args}, snapshot ->
              n = snapshot["revision"]
              {:ok, next, :new} = Snapshot.append(snapshot, "event-#{n}", n, action, args, n)
              next
            end)
            snapshot = if mode == "confirmed" do
              args = %{"operation_id" => "event-8", "outcome" => "confirmed", "observed" => "Ready for production", "error" => nil, "at_ms" => 100, "retry_at_ms" => 0}
              {:ok, next, :new} = Snapshot.append(snapshot, "confirmation", 9, "status_result", args, 100)
              next
            else
              snapshot
            end
            {:ok, port} = Store.open(gate.path)
            {:ok, _} = Store.request(port, %{"op" => "read"})
            {:ok, true} = Store.request(port, %{"op" => "write", "snapshot" => snapshot})
            Store.close(port)
            '''
            for mode in ("legacy", "pending", "confirmed"):
                env = {**os.environ, "PILOT_TEST_WORKFLOW": str(workflow), "PILOT_TEST_MODE": mode}
                result = subprocess.run([data["controller"]["mise"], "exec", "--", "mix", "run", "--no-start", "-e", expression],
                                        cwd=REPO / "elixir", env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                atomic(root / "last_shutdown.json", canonical({"stopped": True, "identity": operator.stop_identity(config)}))
                original = path.read_bytes()
                if mode == "pending":
                    with self.assertRaisesRegex(operator.Refused, "requires_operator_recovery"):
                        operator.pilot_source_idle(data, config)
                else:
                    proof = operator.pilot_source_idle(data, config)
                    self.assertEqual(proof["kind"], "completed")
                    if mode == "legacy":
                        self.assertEqual(proof["status_sync"], "legacy_not_recorded")
                        destination = private_dir(root / "new", create=True)
                        new_workflow = destination / "WORKFLOW.md"
                        proposed = copy.deepcopy(raw)
                        proposed["delivery"]["state_path"] = str(destination / "delivery.json")
                        proposed["codex"] = {"read_timeout_ms": 60000, "turn_sandbox_policy": {
                            "type": "workspaceWrite", "writableRoots": ["/workspace", "/workspace/repo", "/workspace/repo/.git"],
                            "readOnlyAccess": {"type": "fullAccess"}, "networkAccess": False,
                            "excludeTmpdirEnvVar": False, "excludeSlashTmp": False}}
                        proposed["tracker"]["provider"]["states"].update(review="Human review", dev_validation="Dev validation", production_ready="Ready for production")
                        atomic(new_workflow, b"---\n" + canonical(proposed) + b"\n---\nUpdated prompt.\n")
                        before = {**data, "runtime_config": config}
                        after = {**data, "runtime_config": {**config, "workflow": str(new_workflow), "state_root": str(destination)}}
                        for _ in range(2):
                            def fixture_run(args, **kwargs):
                                result = subprocess.run(args, capture_output=True, text=True, **kwargs)
                                self.assertEqual(result.returncode, 0, result.stderr)
                                return result.stdout.strip()
                            with patch.object(operator, "run", side_effect=fixture_run):
                                report = updater.migration(before, after, operator)
                            self.assertTrue(report["migrated"])
                            self.assertEqual(report["revision"], report["source_revision"] + 1)
                        migrated = json.loads((destination / "delivery.json").read_bytes())["snapshot"]
                        source = json.loads(original)["snapshot"]
                        self.assertEqual(migrated["migration"]["source"], source)
                        self.assertEqual(migrated["state"]["last_cycle"], source["state"]["last_cycle"])
                        self.assertIsNone(migrated["state"]["baseline"])
                    else:
                        self.assertEqual(proof["status_sync"]["status"], "confirmed")
                self.assertEqual(path.read_bytes(), original)
            atomic(path, b'{"invalid":"journal"}')
            with self.assertRaisesRegex(operator.Refused, "requires_operator_recovery"):
                operator.pilot_source_idle(data, config)


if __name__ == "__main__":
    unittest.main()
