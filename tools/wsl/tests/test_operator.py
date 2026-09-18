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
from symphony_runtime.common import Rejected, atomic, locked, private_dir
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
        template.write_text('---\n{"tracker":{"kind":"github_projects","item_ids":"${runtime.pilot_item_ids}"}}\n---\nPrompt.\n')
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
            return state[{"exact.service": "supervisor", "symphony-fixture.service": "guardian",
                          "symphony-fixture-management.service": "ssh"}[unit]]
        with patch.object(operator, "host_configuration", return_value=(host, "exact.service", "marker")), patch.object(operator, "policy_directory", return_value=directory), patch.object(operator, "root_path", side_effect=Path), patch.object(operator, "unit_property", side_effect=property):
            self.assertTrue(operator.host_info(self.data)["ready"])
            self.assertEqual(operator.host_info(self.data)["ownership"], "external")
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
