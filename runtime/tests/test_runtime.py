"""Portable runtime contracts; real filesystem/process tests, no privileged operations."""
import io
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime import config, cli
from symphony_runtime.client import accept_export
from symphony_runtime.common import Rejected, atomic, canonical, command, digest, locked, no_links, private_dir, private_file, read_json
from symphony_runtime.guardian import Guardian, MAX_BUNDLE, header, public_key, receive, send_bytes, send_header
from symphony_runtime.network import Firewall


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="runtime-tests-", dir=Path.home())
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.local = self.root / "configuration/local.json"
        self.values = {"state_root": str(self.root / "state"), "symphony_root": str(self.root / "source"),
                       "project_template": str(self.root / "project/WORKFLOW.template.md")}

    def configured(self):
        return config.configure(self.local, self.values)

    def template(self, front=None):
        source = self.root / "project/WORKFLOW.template.md"
        source.parent.mkdir(exist_ok=True)
        source.write_text("---\n" + json.dumps(front or {"tracker": {"kind": "github_projects"}, "workspace": {"root": "${runtime.workspace_root}"}}) + "\n---\nFixture prompt.\n")
        return source

    def test_configuration_is_local_private_and_never_overwritten(self):
        value = self.configured()
        self.assertEqual(value, config.load(self.local))
        self.assertEqual(value["role"], "inspection")
        private_file(self.local)
        private_dir(value["state_root"])
        with self.assertRaisesRegex(Rejected, "configuration_exists"):
            self.configured()

    def test_unknown_runtime_and_path_overlap_fail_before_writes(self):
        for raw in ({"unknown": True}, {"schema_version": 7}, {"runtime_kind": "host-shell"},
                    {"state_root": self.values["symphony_root"]}, {"app_key": self.values["symphony_root"] + "/key"},
                    {"worker_host": "bad;command"}, {"dashboard_port": True}, {"state_root": "/mnt/c/runtime"}):
            with self.subTest(raw=raw), self.assertRaises(Rejected):
                config.configure(self.local, {**self.values, **raw})
        self.assertFalse(self.local.exists())

    def test_personal_paths_are_not_required(self):
        value = config.configure(self.local, {**self.values, "controller_distro": "OtherLinux", "worker_distro": "DifferentWorker", "worker_user": "developer42", "worker_host": "custom-alias", "dashboard_port": 5142})
        self.assertEqual(value["worker_distro"], "DifferentWorker")
        self.assertEqual(value["dashboard_port"], 5142)

    def test_symlink_and_hardlink_credentials_are_rejected(self):
        target = self.root / "key"
        atomic(target, b"not-a-secret-fixture")
        alias = self.root / "alias"
        alias.symlink_to(target)
        with self.assertRaises(Rejected):
            private_file(alias)
        alias.unlink()
        os.link(target, alias)
        with self.assertRaises(Rejected):
            private_file(target)

    def test_symlinked_parent_and_world_readable_config_are_rejected(self):
        directory = self.root / "other"
        directory.mkdir()
        alias = self.root / "linked"
        alias.symlink_to(directory, target_is_directory=True)
        with self.assertRaises(Rejected):
            no_links(alias / "future-file")
        self.configured()
        self.local.chmod(0o644)
        with self.assertRaises(Rejected):
            config.load(self.local)

    def test_json_rejects_duplicate_keys_and_oversized_input(self):
        source = self.root / "bad.json"
        source.write_text('{"a": 1,"a":2}')
        with self.assertRaisesRegex(Rejected, "duplicate"):
            read_json(source)
        with self.assertRaisesRegex(Rejected, "too_large"):
            read_json(source, maximum=2)

    def test_workflow_render_is_deterministic_and_digest_pinned(self):
        value = self.configured()
        template = self.template()
        first = config.render(value)
        self.assertEqual(config.render(value), first)
        config.pin(value, "a" * 40, "b" * 40, "sha256:" + "c" * 64)
        self.assertEqual(config.validate_manifest(value)["workflow_sha256"], first)
        self.assertNotIn("${runtime.", Path(value["workflow"]).read_text())
        template.write_text(template.read_text().replace("Fixture", "Changed"))
        with self.assertRaisesRegex(Rejected, "explicit_regeneration"):
            config.render(value)
        Path(value["workflow"]).write_text("changed")
        with self.assertRaisesRegex(Rejected, "digest_mismatch"):
            config.validate_manifest(value)

    def test_clean_clone_and_profile_revision_are_checked_without_fetch(self):
        value = self.configured()
        self.template()
        revisions = []
        for directory in (Path(value["symphony_root"]), Path(value["project_template"]).parent):
            directory.mkdir(exist_ok=True)
            (directory / "tracked.txt").write_text("fixture")
            command(["git", "init", "-q", str(directory)])
            command(["git", "add", "."], cwd=directory)
            command(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], cwd=directory)
            revisions.append(command(["git", "rev-parse", "HEAD"], cwd=directory).decode().strip())
        config.render(value)
        config.pin(value, *revisions, "sha256:" + "a" * 64)
        cli.verify_source(value)
        (Path(value["project_template"]).parent / "tracked.txt").write_text("changed")
        with self.assertRaisesRegex(Rejected, "profile_checkout_dirty"):
            cli.verify_source(value)

    def test_generic_runtime_has_no_machine_identifiers(self):
        runtime = Path(__file__).resolve().parents[1]
        for directory in ("scripts", "lib", "worker", "config"):
            for file in (runtime / directory).rglob("*"):
                if file.is_file() and file.suffix not in (".pyc", ".pyo"):
                    source = file.read_text()
                    for literal in ("/home/nataselko", "Ubuntu-26.04", "D:/symphony", "D:\\secret", "UID = 2002"):
                        self.assertNotIn(literal, source, str(file))

    def test_template_never_evaluates_partial_expressions_or_unknown_slots(self):
        value = self.configured()
        for slot in ("${runtime.unknown}", "prefix ${runtime.workspace_root}"):
            self.template({"tracker": {"kind": "github_projects"}, "value": slot})
            with self.assertRaises(Rejected):
                config.render(value)

    def test_launch_execution_is_not_a_config_toggle(self):
        with patch("sys.stderr", new=io.StringIO()):
            self.assertEqual(cli.main(["launch", "--execute", "--config", str(self.local)]), 1)
        self.assertFalse(self.local.exists())

    def test_missing_profile_is_not_replaced_with_demo(self):
        value = self.configured()
        report = cli.preflight(value)
        self.assertFalse(report["inspection_ready"])
        self.assertFalse(report["execution_enabled"])
        self.assertTrue(any(row.get("reason") for row in report["checks"] if row["status"] == "NOT_READY"))

    def test_lock_prevents_second_owner_and_releases_on_error(self):
        lock = self.root / "owner.lock"
        with locked(lock):
            with self.assertRaisesRegex(Rejected, "already_running"):
                with locked(lock):
                    self.fail("second owner")
        with locked(lock):
            pass

    def test_command_environment_does_not_inherit_secrets(self):
        with patch.dict(os.environ, {"GH_TOKEN": "fixture-secret", "OPENAI_API_KEY": "fixture-key"}):
            result = command([sys.executable, "-I", "-c", "import os;print(os.environ.get('GH_TOKEN'),os.environ.get('OPENAI_API_KEY'))"])
        self.assertEqual(result.strip(), b"None None")

    def test_command_timeout_and_output_limit(self):
        with self.assertRaisesRegex(Rejected, "timeout"):
            command([sys.executable, "-I", "-c", "import time;time.sleep(30)"], timeout=0.1)
        with self.assertRaisesRegex(Rejected, "output_too_large"):
            command([sys.executable, "-I", "-c", "print('a'*1024)"], maximum=32)

    def test_framing_rejects_truncation_duplicate_keys_and_overflow(self):
        frame = io.BytesIO()
        send_header(frame, {"action": "status"})
        frame.seek(0)
        self.assertEqual(header(frame), {"action": "status"})
        for raw in (b"\x00", struct.pack("!I", 20000), struct.pack("!I", 2) + b"[1", struct.pack("!I", 13) + b'{"a":1,"a":2}'):
            with self.assertRaises((Rejected, ValueError)):
                header(io.BytesIO(raw))
        with self.assertRaises(Rejected):
            receive(io.BytesIO(), MAX_BUNDLE + 1)

    def test_framing_handles_short_writes_and_rejects_no_progress(self):
        class ShortWriter(io.BytesIO):
            def write(self, raw):
                return super().write(raw[:7])
        frame = ShortWriter()
        raw = b"large-frame" * 10000
        send_header(frame, {"body_size": len(raw)})
        send_bytes(frame, raw)
        frame.seek(0)
        self.assertEqual(header(frame), {"body_size": len(raw)})
        self.assertEqual(receive(frame, len(raw)), raw)
        for stalled in (None, 0, -1):
            with patch.object(frame, "write", return_value=stalled), self.assertRaisesRegex(Rejected, "incomplete_frame_write"):
                send_bytes(frame, b"x")

    def test_management_relay_transfers_multi_megabyte_bundle(self):
        raw = b"bundle-payload" * 250000
        failures = []
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(self.root / "control.sock"))
            server.listen(1)
            server.settimeout(10)

            def respond():
                try:
                    connection, _ = server.accept()
                    with connection, connection.makefile("rwb", buffering=0) as stream:
                        connection.settimeout(5)
                        request = header(stream)
                        self.assertEqual(receive(stream, request["bundle_size"]), raw)
                        send_header(stream, {"ok": {"sha256": digest(raw)}, "body_size": len(raw)})
                        send_bytes(stream, raw)
                except BaseException as error:
                    failures.append(error)

            thread = threading.Thread(target=respond, daemon=True)
            thread.start()
            frame = io.BytesIO()
            send_header(frame, {"action": "prepare", "bundle_size": len(raw)})
            send_bytes(frame, raw)
            relay = Path(__file__).resolve().parents[1] / "scripts/worker-control.py"
            result = subprocess.run([sys.executable, "-I", "-B", str(relay), "--root", str(self.root)],
                                    input=frame.getvalue(), capture_output=True, timeout=15)
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(result.returncode, 0, result.stderr)
            response = io.BytesIO(result.stdout)
            self.assertEqual(header(response), {"ok": {"sha256": digest(raw)}, "body_size": len(raw)})
            self.assertEqual(receive(response, len(raw)), raw)

    def test_public_key_does_not_accept_ssh_options(self):
        import base64
        from symphony_runtime.guardian import PREFIX
        key = "ssh-ed25519 " + base64.b64encode(PREFIX + bytes(32)).decode()
        self.assertEqual(public_key(key), key + "\n")
        for value in ('command="sh" ' + key, key + "\n", key + " comment", "ssh-rsa AAAA"):
            with self.assertRaises(Rejected):
                public_key(value)

    def test_export_is_immutable_and_private(self):
        raw = b"fixture-bundle"
        proof = {"size": len(raw), "sha256": digest(raw)}
        path = accept_export(self.root, "generation", proof, raw)
        self.assertEqual(accept_export(self.root, "generation", proof, raw), path)
        private_file(path)
        with self.assertRaises(Rejected):
            accept_export(self.root, "generation", proof, b"tampered")
        with self.assertRaises(Rejected):
            accept_export(self.root, "../escape", proof, raw)

    def guardian(self):
        value = object.__new__(Guardian)
        value.root = self.root
        value.record = {"phase": "running", "interval": "i", "generation": "g", "container": "symphony-job-g", "cgroup": None, "active_seconds": 60}
        value.mutex = threading.RLock()
        value.clock = lambda: 50
        value.started_at = 0
        value.heartbeat_at = 0
        value.cgroup = "/system.slice/symphony-fixture.service"
        return value

    def test_old_interval_and_additional_request_fields_are_rejected(self):
        value = self.guardian()
        for request in ({"action": "stop", "interval": "old", "generation": "g"},
                        {"action": "stop", "interval": "i", "generation": "g", "shell": "bad"}):
            with self.assertRaises(Rejected):
                value.dispatch(request)

    def test_export_requires_confirmed_stop(self):
        value = self.guardian()
        with self.assertRaisesRegex(Rejected, "confirmed_stop"):
            value.export({"action": "export", "interval": "i", "generation": "g", "sha": "a" * 40})

    def test_failed_export_runs_stop_before_another_interval_is_allowed(self):
        value = self.guardian()
        value.record.update(phase="stopped", cycle="cycle", branch="agent/task", export=None)
        with patch.object(value, "save"), patch.object(value, "pod", side_effect=Rejected("export_failed")), patch.object(value, "stop") as stop:
            with self.assertRaises(Rejected):
                value.export({"action": "export", "interval": "i", "generation": "g", "sha": "a" * 40})
            stop.assert_called_once_with("worker_export_failed")
            self.assertEqual(value.record["phase"], "exporting")

    def test_stop_failure_retains_ownership_and_workspace(self):
        value = self.guardian()
        (self.root / "workspace.txt").write_text("preserve")
        with patch.object(value, "save"), patch.object(value, "summary", side_effect=lambda: dict(value.record)), patch.object(value, "pod", side_effect=Rejected("stop_failed")):
            self.assertEqual(value.stop("cancel")["phase"], "stop_unconfirmed")
        self.assertEqual((self.root / "workspace.txt").read_text(), "preserve")

    def test_storage_failure_cannot_skip_actual_stop(self):
        value = self.guardian()
        with patch.object(value, "save", side_effect=OSError()), patch.object(value, "summary", side_effect=lambda: dict(value.record)), patch.object(value, "pod") as pod:
            self.assertEqual(value.stop("cancel")["phase"], "stop_unconfirmed")
            self.assertTrue(any(call.args[0] == "stop" for call in pod.call_args_list))

    def test_heartbeat_and_network_loss_stop_worker(self):
        value = self.guardian()
        with patch.object(value, "ready"), patch.object(value, "stop") as stop:
            value.tick()
            stop.assert_called_once_with("lease_or_deadline_expired")
        value.heartbeat_at = 49
        with patch.object(value, "ready", side_effect=Rejected("expired")), patch.object(value, "stop") as stop:
            value.tick()
            stop.assert_called_once_with("network_policy_lost")

    def test_start_retry_cannot_extend_deadline(self):
        value = self.guardian()
        with patch.object(value, "summary", return_value={"phase": "running"}):
            self.assertEqual(value.start({"action": "start", "interval": "i", "generation": "g", "active_seconds": 3600})["phase"], "running")
        self.assertEqual(value.record["active_seconds"], 60)

    def test_mount_flags_are_not_taken_from_request(self):
        args = self.guardian().base_args("fixture", network=True)
        for expected in ("--read-only", "--cap-drop=all", "--network=pasta", "--pid=private", "--cgroupns=private", "--security-opt=no-new-privileges"):
            self.assertIn(expected, args)
        self.assertFalse(any("--privileged" in arg or "=host" in arg or "/mnt/" in arg for arg in args))

    def test_firewall_is_scoped_to_one_service_and_removes_only_own_chain(self):
        calls = []
        def execute(args, allowed=(0,)):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0)
        firewall = Firewall("system.slice/symphony-fixture.service", ["1.1.1.1"], execute)
        firewall._remove(4)
        self.assertIn("--path", calls[0])
        self.assertIn("system.slice/symphony-fixture.service", calls[0])
        self.assertTrue(all(row[-1] == firewall.chain for row in calls))
        for path in ("init.scope", "user.slice", "system.slice/ssh.service", "../bad"):
            with self.assertRaises(Rejected):
                Firewall(path, [])

    def test_stale_launcher_record_never_kills_process(self):
        value = self.configured()
        atomic(Path(value["state_root"]) / "launcher.json", canonical({"pid": os.getpid(), "start": "wrong", "mode": "inspection", "token": "fixture"}))
        self.assertFalse(cli.status(value)["running"])
        self.assertTrue(cli.stop_inspection(value)["stopped"])

    def test_exited_unreaped_launcher_is_not_running(self):
        value = self.configured()
        process = subprocess.Popen(["/bin/true"])
        try:
            os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
            fields = Path(f"/proc/{process.pid}/stat").read_text().split(") ", 1)[1].split()
            atomic(Path(value["state_root"]) / "launcher.json", canonical({"pid": process.pid, "start": fields[19], "mode": "controller", "token": "fixture"}))
            self.assertFalse(cli.status(value)["running"])
        finally:
            process.wait()

    def test_launcher_can_be_stopped_through_its_private_endpoint(self):
        value = self.configured()
        executable = Path(value["symphony_root"]) / "elixir/bin/symphony"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexec sleep 30\n")
        executable.chmod(0o700)
        program = "import sys,json;sys.path.insert(0,sys.argv[1]);from symphony_runtime import cli;cli.preflight=lambda c,*args:{'inspection_ready':True};raise SystemExit(cli.launch(json.loads(sys.argv[2])))"
        process = subprocess.Popen([sys.executable, "-I", "-B", "-c", program, str(Path(__file__).resolve().parents[1] / "lib"), json.dumps(value)])
        try:
            import time
            deadline = time.monotonic() + 5
            while not (Path(value["state_root"]) / "launcher.json").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(cli.status(value)["running"])
            self.assertTrue(cli.stop_inspection(value)["stopped"])
            process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)

    def test_lost_manager_pipe_requests_shutdown_and_preserves_work(self):
        value = self.configured()
        state = Path(value["state_root"])
        retained = state / "unpublished-work"
        retained.write_text("retain this")
        executable = Path(value["symphony_root"]) / "elixir/bin/symphony"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!" + sys.executable + "\nimport json,time,os\nfrom pathlib import Path\n"
                              + "state=Path(" + repr(str(state)) + ")\n"
                              + "while not (state/'shutdown.request').exists(): time.sleep(0.01)\n"
                              + "fd=os.open(state/'shutdown.pending',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)\n"
                              + "with os.fdopen(fd,'wb') as stream: stream.write((state/'shutdown.request').read_bytes())\n"
                              + "os.replace(state/'shutdown.pending',state/'shutdown.ack')\n")
        executable.chmod(0o700)
        program = ("import sys,json;sys.path.insert(0,sys.argv[1]);from symphony_runtime import cli;"
                   "cli.preflight=lambda c,*args:{'controller_ready':True};"
                   "cli.confirm_shutdown=lambda c:{'stopped':True,'workspace_preserved':True};"
                   "raise SystemExit(cli.launch(json.loads(sys.argv[2]),execute=True,config_path='/fixture',supervised=True))")
        process = subprocess.Popen([sys.executable, "-I", "-B", "-c", program,
                                    str(Path(__file__).resolve().parents[1] / "lib"), json.dumps(value)], stdin=subprocess.PIPE)
        try:
            import time
            process.stdin.write(b"ALIVE\n")
            process.stdin.flush()
            deadline = time.monotonic() + 5
            while not (state / "launcher.json").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(cli.status(value)["running"])
            process.stdin.close()  # The Windows owner has disappeared.
            self.assertEqual(process.wait(timeout=10), 0)
            self.assertTrue(read_json(state / "last_shutdown.json")["stopped"])
            self.assertTrue((state / "shutdown.request").exists())
            self.assertFalse((state / "launcher.json").exists())
            self.assertEqual(retained.read_text(), "retain this")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
