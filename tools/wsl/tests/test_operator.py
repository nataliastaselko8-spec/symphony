"""Real private files/flock; external WSL, SSH and service operations are mocked."""
import base64
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "runtime/lib"))
from symphony_runtime import cli, config, maintenance
from symphony_runtime.common import Rejected, atomic, canonical, locked, private_dir, read_json
from symphony_runtime.controller import Controller
from symphony_runtime.guardian import PREFIX

spec = importlib.util.spec_from_file_location("symphony_operator", REPO / "tools/wsl/operator.py")
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)
PUBLIC_KEY = "ssh-ed25519 " + base64.b64encode(PREFIX + bytes(32)).decode()
OTHER_KEY = "ssh-ed25519 " + base64.b64encode(PREFIX + bytes([1]) * 32).decode()


class OperatorTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="symphony-operator-test-", dir=Path.home())
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.file = self.root / "config/local.json"
        self.source = private_dir(self.root / "source", create=True)
        (self.source / "runtime/scripts").mkdir(parents=True)
        (self.source / "runtime/scripts/controller.py").write_text("# fixture\n")
        (self.source / "elixir/bin").mkdir(parents=True)
        (self.source / "elixir/bin/symphony").write_text("fixture executable")
        (self.source / "elixir/bin/symphony").chmod(0o700)
        project = private_dir(self.root / "profile", create=True)
        template = project / "WORKFLOW.template.md"
        template.write_text('---\n{"tracker":{"kind":"github_projects","provider":{"repo":"ExampleOrg/app","states":{"ready":"Ready for agent"},"item_ids":"${runtime.pilot_item_ids}"}}}\n---\nPrompt.\n')
        ssh = private_dir(self.root / "ssh", create=True)
        credential = private_dir(self.root / "credentials", create=True)
        atomic(credential / "app.pem", b"fixture app key")
        atomic(ssh / "identity", b"fixture SSH identity")
        (ssh / "identity.pub").write_text(PUBLIC_KEY + " comment")
        self.data = {
            "schema_version": 1,
            "controller": {"distro": "Test Controller", "user": "tester", "config": str(self.file), "mise": "/example/mise"},
            "worker": {"distro": "Test Worker", "config": "/etc/symphony/test.json"},
            "github_app": {"app_id": "123", "client_id": "IvExample", "installation_id": "456"},
            "pins": {"symphony_commit": "a" * 40, "profile_revision": "b" * 40, "worker_image": "sha256:" + "c" * 64},
            "ssh": {"identity": str(ssh / "identity"), "known_hosts": str(ssh / "known_hosts")},
            "runtime_config": {
                "schema_version": 2, "role": "controller", "runtime_kind": "wsl2-podman",
                "controller_distro": "Test Controller", "controller_user": "tester",
                "worker_distro": "Test Worker", "worker_user": "worker",
                "symphony_root": str(self.source), "project_template": str(template),
                "state_root": str(self.root / "state"), "workflow": str(self.file.parent / "WORKFLOW.md"),
                "manifest": str(self.file.parent / "manifest.json"), "ssh_config": str(ssh / "config"),
                "app_key": str(credential / "app.pem"), "operator_credential": str(credential / "operator-token")}}
        self.info = {"ready": True, "runtime_sha256": config.package_digest(self.source / "runtime"),
                     "public_key": PUBLIC_KEY, "ownership": "external",
                     "host": {"image": self.data["pins"]["worker_image"], "user": "worker",
                              "management_port": 2345, "management_public_key": PUBLIC_KEY}}
        for target in (patch.object(operator, "runtime", return_value=(config, cli)),
                       patch.object(cli, "verify_source")):
            target.start()
            self.addCleanup(target.stop)

    def setup(self):
        operator.setup(self.data, self.info)
        self.config = config.load(self.file)

    def action(self, action, **options):
        return operator.controller_action(self.data, action, options)

    def test_repeated_setup_preserves_credentials_manifest_and_work(self):
        self.setup()
        state = Path(self.config["state_root"])
        for name in ("delivery.json", "model-selection.json", "worker.json", "unpublished"):
            atomic(state / name, b"existing bytes")
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertFalse(operator.setup(self.data, self.info)["execution_started"])
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()})
        self.assertEqual(Path(self.config["operator_credential"]).stat().st_mode & 0o777, 0o600)

    def test_changed_existing_configuration_preserves_original(self):
        self.setup()
        before = self.file.read_bytes()
        self.data["runtime_config"]["pilot_item_ids"] = ["new-card"]
        with self.assertRaisesRegex(operator.Refused, "existing_config_differs"):
            operator.setup(self.data, self.info)
        self.assertEqual(self.file.read_bytes(), before)

    def test_existing_manifest_cannot_be_repinned(self):
        self.setup()
        self.data["pins"]["profile_revision"] = "d" * 40
        before = Path(self.config["manifest"]).read_bytes()
        with self.assertRaisesRegex(Rejected, "manifest_exists"):
            operator.setup(self.data, self.info)
        self.assertEqual(Path(self.config["manifest"]).read_bytes(), before)

    def test_rotated_trusted_host_key_keeps_strict_ssh_settings(self):
        self.setup()
        self.info["public_key"] = OTHER_KEY
        self.action("sync", host_info=self.info)
        self.assertEqual(Path(self.data["ssh"]["known_hosts"]).read_text().strip(), "[127.0.0.1]:2345 " + OTHER_KEY)
        text = Path(self.config["ssh_config"]).read_text()
        for value in ("StrictHostKeyChecking yes", "ForwardAgent no", "GlobalKnownHostsFile /dev/null"):
            self.assertIn(value, text)

    def test_wrong_runtime_image_identity_or_user_cannot_replace_host_key(self):
        self.setup()
        before = Path(self.data["ssh"]["known_hosts"]).read_bytes()
        for change in ("runtime", "image", "identity", "user", "not-ready", "bad-key"):
            info = copy.deepcopy(self.info)
            if change == "runtime": info["runtime_sha256"] = "bad"
            if change == "image": info["host"]["image"] = "sha256:" + "d" * 64
            if change == "identity": info["host"]["management_public_key"] = OTHER_KEY
            if change == "user": info["host"]["user"] = "other"
            if change == "not-ready": info["ready"] = False
            if change == "bad-key": info["public_key"] += "\nHost injected"
            with self.subTest(change=change), self.assertRaises((operator.Refused, Rejected)):
                self.action("sync", host_info=info)
            self.assertEqual(Path(self.data["ssh"]["known_hosts"]).read_bytes(), before)

    def test_setup_and_sync_refuse_running_launcher_or_maintenance(self):
        self.setup()
        for name in ("launcher.lock", "prepare.lock"):
            with locked(Path(self.config["state_root"]) / name):
                for operation in (lambda: operator.setup(self.data, self.info), lambda: self.action("sync", host_info=self.info)):
                    with self.subTest(lock=name), self.assertRaisesRegex(Rejected, "already_running"):
                        operation()
        self.action("sync", host_info=self.info)  # Failed nested acquisition released launcher.lock.

    def test_stop_recovery_can_acquire_prepare_lock_and_retains_launcher_lock(self):
        self.setup()
        def confirm(cfg):
            with self.assertRaisesRegex(Rejected, "already_running"):
                with locked(Path(cfg["state_root"]) / "launcher.lock"): pass
            with locked(Path(cfg["state_root"]) / "prepare.lock"):
                return {"stopped": True, "workspace_preserved": True}
        with patch.object(cli, "stop_inspection", return_value={"stopped": True}), patch.object(cli, "confirm_shutdown", side_effect=confirm) as proof:
            self.assertTrue(self.action("stop")["stopped"])
            proof.assert_called_once()

    def test_no_launcher_pid_does_not_imply_stopped_worker(self):
        self.setup()
        with patch.object(cli, "stop_inspection", return_value={"stopped": True}), patch.object(cli, "confirm_shutdown", return_value={"stopped": False}):
            with self.assertRaisesRegex(operator.Refused, "worker_stop_unconfirmed"):
                self.action("stop")

    def test_orphaned_prepare_blocks_stop_confirmation(self):
        self.setup()
        with locked(Path(self.config["state_root"]) / "prepare.lock"), patch.object(cli, "stop_inspection", return_value={"stopped": True}), patch.object(cli, "confirm_shutdown") as proof:
            with self.assertRaisesRegex(Rejected, "already_running"):
                self.action("stop")
            proof.assert_not_called()

    def test_failed_controller_stop_does_not_try_worker_recovery(self):
        self.setup()
        with patch.object(cli, "stop_inspection", return_value={"stopped": False}), patch.object(cli, "confirm_shutdown") as proof:
            with self.assertRaisesRegex(operator.Refused, "controller_stop_unconfirmed"):
                self.action("stop")
            proof.assert_not_called()

    def test_selected_pilot_needs_explicit_execute(self):
        self.data["runtime_config"]["pilot_item_ids"] = ["agreed-card"]
        self.setup()
        with patch.object(cli, "launch") as launch:
            with self.assertRaisesRegex(operator.Refused, "use_execute_for_selected_pilot"):
                self.action("start")
            launch.assert_not_called()

    def test_start_uses_exact_app_scope_and_runtime_without_choosing_a_card(self):
        self.setup()
        erlang = self.root / "erlang"
        (erlang / "bin").mkdir(parents=True)
        (erlang / "bin/escript").touch()
        with patch.dict(os.environ), patch.object(operator, "run", return_value=str(erlang)), patch.object(cli, "launch", return_value=0) as launch:
            with self.assertRaises(SystemExit) as result:
                self.action("start")
            self.assertEqual(result.exception.code, 0)
            self.assertEqual(os.environ["SYMPHONY_GITHUB_INSTALLATION_ID"], "456")
            self.assertEqual(launch.call_args.kwargs["execute"], True)
            self.assertEqual(launch.call_args.args[0]["pilot_item_ids"], [])

    def test_model_and_effort_are_passed_together(self):
        self.setup()
        with patch.object(maintenance, "select_model", return_value={}) as select:
            self.action("select-model", model="explicit-model", effort="high")
            self.assertEqual(select.call_args.args[1:], ("explicit-model", "high"))

    def pilot_fixture(self):
        self.setup()
        (self.root / "erlang/bin").mkdir(parents=True)
        (self.root / "erlang/bin/escript").touch()
        state = Path(self.config["state_root"])
        atomic(state / "model-selection.json", json.dumps({"model": "test-model", "effort": "high"}).encode())
        atomic(state / "model-catalog.json", json.dumps({"image": self.data["pins"]["worker_image"], "queried_at": int(time.time()),
                                                       "models": [{"model": "test-model", "efforts": ["high"]}]}).encode())
        self.report = {"project": {"repo": "ExampleOrg/app"}, "schema": {"agent_allowed_option_id": "yes-id"}, "items": [{
            "item_id": "PVTI_test", "archived": False, "issue_state": "OPEN", "state": "Ready for agent",
            "url": "https://github.com/ExampleOrg/app/issues/132", "reasons": ["outside_item_scope"],
            "native_ref": {"repo": "ExampleOrg/app", "issue_number": 132, "agent_allowed_option_id": "yes-id"}}]}
        # The existing finite inspect command is used, no worker or project write.
        return self.report

    def select_fixture(self, issue=132, proof=None):
        def fake_run(args, **kwargs):
            return str(self.root / "erlang") if "where" in args else json.dumps(self.report)
        with patch.dict(os.environ), patch.object(operator, "pilot_source_idle", return_value=proof or {"kind": "initial"}), patch.object(operator, "run", side_effect=fake_run):
            return self.action("select-pilot", issue=issue)

    def test_pilot_selection_preserves_old_profile_keys_store_and_uses_one_new_scope(self):
        self.pilot_fixture()
        old_state = Path(self.config["state_root"])
        atomic(old_state / "delivery.json", b"retained old journal")
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = self.select_fixture()
        self.assertFalse(result["execution_started"])
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        updated = result["installation"]
        cfg = config.load(updated["controller"]["config"])
        self.assertNotEqual(cfg["state_root"], self.config["state_root"])
        self.assertEqual(cfg["pilot_item_ids"], ["PVTI_test"])
        self.assertEqual(config.workflow_settings(cfg)["tracker"]["provider"]["item_ids"], ["PVTI_test"])
        self.assertEqual(config.validate_manifest(cfg)["symphony_commit"], self.data["pins"]["symphony_commit"])
        self.assertFalse((Path(cfg["state_root"]) / "delivery.json").exists())
        for key in ("app_key", "operator_credential", "ssh_config"):
            self.assertEqual(cfg[key], self.config[key])
        for name in ("model-selection.json", "model-catalog.json"):
            self.assertEqual((Path(cfg["state_root"]) / name).read_bytes(), (old_state / name).read_bytes())

    def test_selection_can_resume_before_descriptor_commit_without_repinning(self):
        self.pilot_fixture()
        original = self.select_fixture()
        self.assertEqual(original, self.select_fixture())
        self.data = original["installation"]
        with patch.object(operator, "run") as run:
            self.assertEqual(self.action("select-pilot", issue=132), original)
            run.assert_not_called()
        with self.assertRaisesRegex(operator.Refused, "confirmed_stop_required"):
            self.action("select-pilot", issue=133)

    def test_selection_resume_does_not_erase_started_pilot_or_model_change(self):
        self.pilot_fixture()
        selected = self.select_fixture()["installation"]
        state = Path(selected["runtime_config"]["state_root"])
        atomic(state / "delivery.json", b"unpublished work must survive")
        with self.assertRaisesRegex(operator.Refused, "prepared_pilot_already_used"):
            self.select_fixture()
        self.assertEqual((state / "delivery.json").read_bytes(), b"unpublished work must survive")

    def test_interrupted_selection_resumes_without_changing_the_source(self):
        self.pilot_fixture()
        before = self.file.read_bytes()
        with patch.object(config, "pin", side_effect=OSError("interrupted before manifest")), self.assertRaises(OSError):
            self.select_fixture()
        self.assertEqual(self.file.read_bytes(), before)
        result = self.select_fixture()
        cfg = config.load(result["installation"]["controller"]["config"])
        config.validate_manifest(cfg)

    def test_prepared_profile_with_changed_bytes_is_not_adopted(self):
        self.pilot_fixture()
        selected = self.select_fixture()["installation"]
        cfg = selected["runtime_config"]
        original = Path(cfg["workflow"]).read_bytes()
        atomic(cfg["workflow"], original + b"unapproved change")
        with self.assertRaisesRegex(Rejected, "workflow_changed"):
            self.select_fixture()
        self.assertTrue(Path(cfg["workflow"]).read_bytes().endswith(b"unapproved change"))

    def test_selection_refuses_denied_closed_wrong_status_duplicate_and_missing_cards(self):
        self.pilot_fixture()
        original = copy.deepcopy(self.report)
        for change in ("denied", "closed", "status", "duplicate", "missing", "labels", "repository"):
            self.report = copy.deepcopy(original)
            row = self.report["items"][0]
            if change == "denied": row["native_ref"]["agent_allowed_option_id"] = "no-id"
            if change == "closed": row["issue_state"] = "CLOSED"
            if change == "status": row["state"] = "Backlog"
            if change == "duplicate": self.report["items"].append(copy.deepcopy(row))
            if change == "missing": self.report["items"] = []
            if change == "labels": row["reasons"].append("missing_required_label")
            if change == "repository": self.report["project"]["repo"] = "Other/app"
            with self.subTest(change=change), self.assertRaises(operator.Refused):
                self.select_fixture()
        self.assertEqual(list(self.file.parent.glob("pilot-*")), [])

    def test_selection_refuses_busy_source_recovery_and_stale_model_catalog(self):
        self.pilot_fixture()
        for name in ("launcher.lock", "prepare.lock"):
            with locked(Path(self.config["state_root"]) / name), self.assertRaisesRegex(Rejected, "already_running"):
                self.select_fixture()
        with patch.object(operator, "pilot_source_idle", side_effect=operator.Refused("pilot_source_requires_operator_recovery")), \
                self.assertRaisesRegex(operator.Refused, "requires_operator_recovery"):
            self.action("select-pilot", issue=132)
        catalog = Path(self.config["state_root"]) / "model-catalog.json"
        stale = json.loads(catalog.read_bytes())
        stale["queried_at"] -= 90000
        atomic(catalog, json.dumps(stale).encode())
        with self.assertRaisesRegex(Rejected, "model_catalog_refresh_required"):
            self.select_fixture()

    def test_idle_probe_requires_bound_stop_and_replayed_evidence(self):
        self.pilot_fixture()
        with self.assertRaisesRegex(operator.Refused, "confirmed_stop_required"):
            operator.pilot_source_idle(self.data, self.config)
        atomic(Path(self.config["state_root"]) / "last_shutdown.json", canonical({"stopped": True, "identity": operator.stop_identity(self.config)}))
        with patch.object(operator, "run", return_value='{"allowed":false}'), \
                self.assertRaisesRegex(operator.Refused, "requires_operator_recovery"):
            operator.pilot_source_idle(self.data, self.config)
        atomic(Path(self.config["state_root"]) / "worker.json", b"{}")
        with self.assertRaisesRegex(operator.Refused, "stop_identity_changed"):
            operator.pilot_source_idle(self.data, self.config)

    def completed_pilot(self):
        self.pilot_fixture()
        self.data = self.select_fixture()["installation"]
        self.config = self.data["runtime_config"]
        root = Path(self.config["state_root"])
        binding = {"cycle": "cycle-A", "interval": "interval-A", "generation": "interval-A", "repo": "ExampleOrg/app", "branch": "agent/task-a", "base_sha": "a" * 40}
        atomic(root / "worker.json", canonical(binding))
        atomic(private_dir(root / "bindings", create=True) / "interval-A.json", canonical(binding))
        atomic(root / "delivery.json", b"old completed journal retained verbatim")
        atomic(root / "last_shutdown.json", canonical({"stopped": True, "identity": operator.stop_identity(self.config)}))
        return {"kind": "completed", "cycle_id": "cycle-A", "work": {"branch": binding["branch"]},
                "scope": {"repo": "exampleorg/app"}, "status_sync": {"status": "confirmed"}}

    def next_card(self, issue=200):
        row = self.report["items"][0]
        row["item_id"] = "PVTI_next_" + str(issue)
        row["native_ref"]["issue_number"] = issue
        row["url"] = "https://github.com/ExampleOrg/app/issues/" + str(issue)

    def test_completed_a_to_b_preserves_history_credentials_and_recognizes_stopped_worker(self):
        proof = self.completed_pilot()
        source = Path(self.config["state_root"])
        before = {p: p.read_bytes() for p in source.rglob("*") if p.is_file()}
        self.next_card()
        result = self.select_fixture(200, proof)
        after = result["installation"]
        target = Path(after["runtime_config"]["state_root"])
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertEqual(after["pilot_history"][-1]["source_pilot"]["issue"], 132)
        self.assertEqual(after["pilot_history"][-1]["evidence"], proof)
        self.assertEqual(after["pins"], self.data["pins"])
        self.assertEqual(after["worker"], self.data["worker"])
        self.assertEqual(after["github_app"], self.data["github_app"])
        self.assertFalse((target / "worker.json").exists())
        self.assertFalse((target / "delivery.json").exists())
        binding = read_json(source / "worker.json")
        def status(*_):
            return {**binding, "phase": "exported", "image": self.data["pins"]["worker_image"],
                    "profile_revision": self.data["pins"]["profile_revision"], "runtime_contract": "2",
                    "network_ready": True, "auth_present": True, "free_bytes": 100 * 1024**3}, b""
        ctl = Controller(after["runtime_config"], transport=status)
        self.assertIsNone(ctl.current())
        self.assertTrue(ctl.ready()["ready"])
        self.assertEqual(self.select_fixture(200, proof), result)
        self.data = after
        self.assertEqual(self.action("select-pilot", issue=200), result)
        with patch.object(operator, "pilot_source_idle", return_value=proof), self.assertRaisesRegex(operator.Refused, "already_completed"):
            self.action("select-pilot", issue=132)

    def test_completed_probe_keeps_legacy_annotation_and_rejects_foreign_worker_metadata(self):
        proof = self.completed_pilot()
        proof["status_sync"] = "legacy_not_recorded"
        with patch.object(operator, "run", return_value=json.dumps({"allowed": True, "evidence": proof})):
            observed = operator.pilot_source_idle(self.data, self.config)
            self.assertEqual(observed["status_sync"], "legacy_not_recorded")
            proof["cycle_id"] = "different"
        with patch.object(operator, "run", return_value=json.dumps({"allowed": True, "evidence": proof})), self.assertRaisesRegex(operator.Refused, "worker_owner"):
            operator.pilot_source_idle(self.data, self.config)

    def test_pending_selection_cannot_fork_or_adopt_changed_models(self):
        self.pilot_fixture()
        first = self.select_fixture()
        with self.assertRaisesRegex(operator.Refused, "selection_pending"), patch.object(cli, "launch") as launch:
            self.action("start")
        launch.assert_not_called()
        self.next_card()
        with self.assertRaisesRegex(operator.Refused, "selection_pending"):
            self.select_fixture(200)
        self.next_card(132)
        self.report["items"][0]["item_id"] = "PVTI_test"
        state = Path(self.config["state_root"])
        atomic(state / "model-selection.json", canonical({"model": "test-model", "effort": "low"}))
        with self.assertRaisesRegex(Rejected, "selected_effort_unavailable"):
            self.select_fixture()
        self.assertEqual(read_json(Path(first["installation"]["runtime_config"]["state_root"]) / "model-selection.json")["effort"], "high")

    def test_completed_source_cannot_restart_while_next_pilot_is_prepared(self):
        proof = self.completed_pilot()
        self.next_card()
        result = self.select_fixture(200, proof)
        with self.assertRaisesRegex(operator.Refused, "selection_pending"):
            self.action("select-pilot", issue=132)
        with self.assertRaisesRegex(operator.Refused, "selection_pending"), patch.object(cli, "launch") as launch:
            self.action("start", execute=True)
        launch.assert_not_called()
        self.assertEqual(self.select_fixture(200, proof), result)

    def test_probe_refuses_live_or_stale_launcher_even_with_prior_stop(self):
        self.pilot_fixture()
        root = Path(self.config["state_root"])
        atomic(root / "last_shutdown.json", canonical({"stopped": True, "identity": operator.stop_identity(self.config)}))
        atomic(root / "launcher.json", canonical({"pid": os.getpid()}))
        with patch.object(operator, "run") as replay, self.assertRaisesRegex(operator.Refused, "confirmed_stop_required"):
            operator.pilot_source_idle(self.data, self.config)
        replay.assert_not_called()

    def test_token_cannot_be_captured_in_logs(self):
        self.setup()
        with patch.object(os, "isatty", return_value=False), redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(operator.Refused, "local_terminal_required"):
                self.action("token")
        self.assertEqual(output.getvalue(), "")

    def test_bad_descriptor_fails_before_root_or_controller_actions(self):
        for mutation in (lambda d: d["runtime_config"].update(worker_distro="wrong"),
                         lambda d: d["runtime_config"].update(ssh_config=d["ssh"]["identity"]),
                         lambda d: d["controller"].update(user="root; shell"),
                         lambda d: d["ssh"].update(known_hosts="/home/a/../b")):
            data = copy.deepcopy(self.data)
            mutation(data)
            with patch.object(operator, "host_start") as start, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    operator.entry({"action": "host-start", "installation": data})
                start.assert_not_called()

    def test_immutable_helper_inputs_allow_spaces_and_unicode(self):
        self.data["controller"]["config"] = str(self.root / "local config-тест/local.json")
        request = {"installation": self.data, "source": base64.b64encode(b"# fixture").decode()}
        original = operator.install_helper(request)
        self.assertEqual(operator.install_helper(request), original)
        self.data["github_app"]["app_id"] = "789"
        other = operator.install_helper(request)
        self.assertNotEqual(original["installation"], other["installation"])
        self.assertEqual(json.loads(Path(original["installation"]).read_text())["github_app"]["app_id"], "123")
        Path(original["script"]).write_text("altered")
        with self.assertRaisesRegex(operator.Refused, "installed_helper_changed"):
            operator.install_helper(request)

    def test_existing_external_supervisor_is_not_adopted_or_stopped(self):
        with patch.object(operator, "host_info", return_value=self.info), patch.object(operator, "run") as run:
            with self.assertRaisesRegex(operator.Refused, "external_supervisor_not_adopted"):
                operator.host_start(self.data)
            self.assertEqual(operator.host_stop(self.data), {"host_stopped": False, "ownership": "external"})
            run.assert_not_called()

    def test_non_ready_managed_supervisor_cannot_be_started_again(self):
        host = {"name": "operator-test-nonexistent"}
        with patch.object(operator, "host_info", return_value={"ready": False, "ownership": "managed"}), patch.object(operator, "host_configuration", return_value=(host, "fixture.service", "fixture")), patch.object(operator, "run") as run:
            with self.assertRaisesRegex(operator.Refused, "supervisor_not_ready"):
                operator.host_start(self.data)
            run.assert_not_called()

    def test_managed_stop_needs_current_worker_proof_and_only_stops_its_unit(self):
        host = {"name": "unique-test"}
        with patch.object(operator, "host_info", return_value={"ownership": "managed"}), patch.object(operator, "host_configuration", return_value=(host, "exact-supervisor.service", "marker")), patch.object(operator, "policy_directory", return_value=self.root / "absent-policy"), patch.object(operator, "worker_status") as status, patch.object(operator, "run") as run:
            for phase in ("running", "prepared", "unknown", None):
                status.return_value = {"phase": phase}
                with self.subTest(phase=phase), self.assertRaisesRegex(operator.Refused, "worker_not_stopped"):
                    operator.host_stop(self.data)
                run.assert_not_called()
            status.return_value = {"phase": "stopped"}
            self.assertTrue(operator.host_stop(self.data)["host_stopped"])
            run.assert_called_once_with(["systemctl", "stop", "exact-supervisor.service"], timeout=130)

    def test_trusted_host_state_requires_live_services_lease_and_ownership(self):
        host = {"name": "fixture", "package": str(self.source / "runtime"), "image": self.data["pins"]["worker_image"]}
        directory = self.root / "policy"
        directory.mkdir()
        evidence = {"ready": True, "image": host["image"], "cgroup": "/system.slice/symphony-fixture.service",
                    "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                    "valid_until_monotonic": time.clock_gettime(time.CLOCK_BOOTTIME) + 60}
        (directory / "network.json").write_text(json.dumps(evidence))
        (directory / "management_host_key.pub").write_text(PUBLIC_KEY)
        state = {"supervisor": "inactive", "guardian": "active", "ssh": "active", "description": "marker"}
        def property(unit, name):
            if name == "Description": return state["description"]
            if name == "ControlGroup": return evidence["cgroup"]
            return state[{"exact.service": "supervisor", "symphony-fixture.service": "guardian",
                          "symphony-fixture-management.service": "ssh"}[unit]]
        with patch.object(operator, "host_configuration", return_value=(host, "exact.service", "marker")), patch.object(operator, "policy_directory", return_value=directory), patch.object(operator, "root_path", side_effect=Path), patch.object(operator, "unit_property", side_effect=property):
            self.assertTrue(operator.host_info(self.data)["ready"])
            self.assertEqual(operator.host_info(self.data)["ownership"], "external")
            evidence["cgroup"] = "/wsl-user/distro-287/systemd/system.slice/symphony-fixture.service"
            (directory / "network.json").write_text(json.dumps(evidence))
            self.assertTrue(operator.host_info(self.data)["ready"])
            state["ssh"] = "inactive"
            self.assertFalse(operator.host_info(self.data)["ready"])
            state["ssh"] = "active"
            evidence["valid_until_monotonic"] = 0
            (directory / "network.json").write_text(json.dumps(evidence))
            self.assertFalse(operator.host_info(self.data)["ready"])
            state.update(supervisor="active", description="unrelated service")
            with self.assertRaisesRegex(operator.Refused, "foreign_supervisor_unit"):
                operator.host_info(self.data)


if __name__ == "__main__":
    unittest.main()
