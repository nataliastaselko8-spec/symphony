"""Bootstrap contract tests with real temporary files; no packages/users/services changed."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("provision", Path(__file__).parents[1] / "provision.py")
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.request = {"id": "a" * 32, "role": "controller"}
        self.addCleanup(patch.stopall)
        patch.object(p, "STAGE", self.root / "stage").start()
        patch.object(p, "MARKER", self.root / "marker.json").start()
        patch.object(p, "WSL_CONFIG", self.root / "wsl.conf").start()

    def test_transfer_binary_hash_and_resume(self):
        raw = bytes(range(256)) * 8192
        req = {**self.request, "asset": "mise", "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        with patch.object(p, "owned", return_value="fixture"):
            for expected in (False, True):
                with patch.object(p.sys, "stdin", types.SimpleNamespace(buffer=io.BytesIO(raw))):
                    result = p.receive(req)
                self.assertEqual(result.get("reused", False), expected)
            self.assertEqual(p.asset(req).read_bytes(), raw)
            self.assertEqual(p.asset(req).stat().st_mode & 0o777, 0o600)

    def test_failed_transfer_does_not_publish_or_leave_secret(self):
        req = {**self.request, "asset": "pem", "size": 7, "sha256": "f" * 64}
        with patch.object(p, "owned", return_value="fixture"), patch.object(p.sys, "stdin", types.SimpleNamespace(buffer=io.BytesIO(b"secret!"))):
            with self.assertRaisesRegex(ValueError, "checksum"):
                p.receive(req)
        self.assertFalse(p.asset(req).exists())
        self.assertEqual(list(p.asset(req).parent.iterdir()), [])

    def test_worker_cannot_receive_credentials_or_source(self):
        for name in ("pem", "mise", "symphony", "profile", "../../etc/passwd"):
            with self.assertRaisesRegex(ValueError, "asset_not_allowed"):
                p.asset({**self.request, "role": "worker", "asset": name, "size": 1, "sha256": "b" * 64})

    def test_preflight_reports_only_bounded_reason_codes(self):
        p.require_preflight({'host_prerequisites_ready': True})
        for reason, expected in (('missing_podman', 'host_preflight_podman_missing_podman'),
                                 ('secret https://example.invalid/token', 'host_preflight_not_ready')):
            with self.assertRaises(ValueError) as raised:
                p.require_preflight({'host_prerequisites_ready': False, 'checks': [
                    {'check': 'podman', 'status': 'NOT_READY', 'reason': reason}]})
            self.assertEqual(str(raised.exception), expected)

    def test_symlink_parent_is_not_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        p.STAGE.symlink_to(outside, target_is_directory=True)
        req = {**self.request, "asset": "mise", "size": 1, "sha256": "b" * 64}
        with patch.object(p, "owned", return_value="fixture"), self.assertRaisesRegex(ValueError, "symlink"):
            p.receive(req)
        self.assertEqual(list(outside.iterdir()), [])

    def archive(self, entries):
        archive = self.root / "runtime.tar"
        with tarfile.open(archive, "w") as out:
            for name, kind, raw in entries:
                item = tarfile.TarInfo(name)
                item.type = kind
                item.size = len(raw) if kind == tarfile.REGTYPE else 0
                item.linkname = "/etc/passwd" if kind == tarfile.SYMTYPE else ""
                out.addfile(item, io.BytesIO(raw) if item.isfile() else None)
        return archive

    def test_archive_validates_all_members_before_writing(self):
        for bad in ("../escape", "/escape", "sub/../../escape", "sub\\escape"):
            archive = self.archive([("valid.py", tarfile.REGTYPE, b"ok"), (bad, tarfile.REGTYPE, b"bad")])
            with self.assertRaises(ValueError):
                p.extract_runtime(archive, self.root / "package")
            self.assertFalse((self.root / "package/valid.py").exists())
        for entries in ([('link', tarfile.SYMTYPE, b'')], [('file', tarfile.REGTYPE, b'a'), ('./file', tarfile.REGTYPE, b'b')]):
            with self.assertRaises(ValueError):
                p.extract_runtime(self.archive(entries), self.root / "package")

    def test_regular_archive_and_changed_existing_file(self):
        archive = self.archive([("lib/code.py", tarfile.REGTYPE, b"code")])
        package = self.root / "package"
        p.extract_runtime(archive, package)
        self.assertEqual((package / "lib/code.py").read_bytes(), b"code")
        (package / "lib/code.py").write_bytes(b"retained changes")
        with self.assertRaisesRegex(ValueError, "existing_file_differs"):
            p.extract_runtime(archive, package)
        self.assertEqual((package / "lib/code.py").read_bytes(), b"retained changes")

    def test_claim_does_not_reset_existing_password(self):
        home = self.root / "home"
        home.mkdir()
        account = types.SimpleNamespace(pw_uid=1001, pw_gid=1001, pw_dir=str(home))
        with patch.object(p, "check_request", return_value=self.request), patch.object(p, "owned", return_value="fixture"), \
             patch.object(p.pwd, "getpwnam", return_value=account), patch.object(p, "run") as run:
            result = p.claim(self.request)
            self.assertTrue(result["restart_required"])
            run.assert_not_called()
        self.assertIn("enabled=false", p.WSL_CONFIG.read_text())

    def test_marker_scope_and_non_root_rejected(self):
        with patch.object(p.os, "geteuid", return_value=1000), self.assertRaisesRegex(ValueError, "root_bootstrap_required"):
            p.check_request(self.request)
        p.MARKER.write_text(json.dumps({"id": "b" * 32, "role": "worker", "schema_version": 1}))
        with patch.object(p.os, "geteuid", return_value=0), self.assertRaisesRegex(ValueError, "foreign_distribution"):
            p.owned(self.request)

    def test_clone_from_real_git_bundle_preserves_dirty_work(self):
        source = self.root / "source"
        source.mkdir()
        def git(*args):
            return subprocess.check_output(["git", "-C", str(source), *args], stderr=subprocess.DEVNULL).decode().strip()
        git("init", "-qb", "main")
        (source / "code").write_text("initial")
        git("add", ".")
        git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial")
        commit = git("rev-parse", "HEAD")
        bundle = self.root / "source.bundle"
        git("bundle", "create", str(bundle), "HEAD")
        account = types.SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())
        def current_user_run(argv, **_):
            return subprocess.check_output(argv, stderr=subprocess.DEVNULL).decode().strip()
        dest = self.root / "checkout"
        with patch.object(p.pwd, "getpwnam", return_value=account), patch.object(p, "run", side_effect=current_user_run):
            p.clone(bundle, dest, commit, "fixture")
            p.clone(bundle, dest, commit, "fixture")
            (dest / "code").write_text("unpublished")
            with self.assertRaisesRegex(ValueError, "source_not_clean"):
                p.clone(bundle, dest, commit, "fixture")
        self.assertEqual((dest / "code").read_text(), "unpublished")

    def controller_fixture(self):
        home = self.root / 'controller-home'
        (home / 'symphony/elixir/bin').mkdir(parents=True)
        (home / '.ssh').mkdir()
        (home / '.ssh/management_ed25519').write_text('existing SSH key')
        (home / '.ssh/management_ed25519.pub').write_text('ssh-ed25519 fixture')
        stage = p.STAGE / self.request['id']
        stage.mkdir(parents=True)
        (stage / 'mise').write_bytes(b'fixed mise')
        account = types.SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid(), pw_dir=str(home))
        patch.object(p, 'owned', return_value='fixture').start()
        patch.object(p.pwd, 'getpwnam', return_value=account).start()
        patch.object(p, 'clone').start()
        request = {**self.request, 'manifest': {'symphony_commit': 'a' * 40, 'profile_revision': 'b' * 40,
                   'toolchain': {'erlang': '28.5', 'elixir': '1.19.5-otp-28'}}}
        artifact = home / 'symphony/elixir/bin/symphony'
        builds = []
        def execute(argv, **_):
            if argv[-2:] == ['mix', 'build']:
                builds.append(len(builds) + 1)
                artifact.write_bytes(('escript archive build ' + str(builds[-1])).encode())
                artifact.chmod(0o755)
            return ''
        runner = patch.object(p, 'run', side_effect=execute).start()
        return request, home, stage, artifact, builds, runner

    def test_resumed_controller_keeps_manifest_bound_build_bytes(self):
        request, home, stage, artifact, builds, runner = self.controller_fixture()
        p.controller(request)
        original = artifact.read_bytes()
        receipt = stage / 'controller-build.json'
        accepted = receipt.read_bytes()
        deployment = home / '.config/symphony/pilot/deployment.json'
        deployment.parent.mkdir(parents=True)
        deployment.write_text(json.dumps({'artifact_sha256': hashlib.sha256(original).hexdigest()}))
        runner.reset_mock()
        p.controller(request)
        p.controller(request)
        self.assertEqual(builds, [1])
        self.assertEqual(artifact.read_bytes(), original)
        self.assertEqual(receipt.read_bytes(), accepted)
        self.assertEqual(json.loads(deployment.read_text())['artifact_sha256'], hashlib.sha256(artifact.read_bytes()).hexdigest())
        self.assertFalse(any(str(call.args[0][0]).endswith('/mise') for call in runner.call_args_list))

    def test_controller_does_not_rebuild_changed_or_missing_accepted_artifact(self):
        request, _, stage, artifact, builds, runner = self.controller_fixture()
        p.controller(request)
        receipt = (stage / 'controller-build.json').read_bytes()
        artifact.write_bytes(b'changed executable')
        with self.assertRaisesRegex(ValueError, 'controller_artifact_changed'):
            p.controller(request)
        self.assertEqual(artifact.read_bytes(), b'changed executable')
        artifact.unlink()
        with self.assertRaisesRegex(ValueError, 'controller_artifact_missing'):
            p.controller(request)
        self.assertEqual(builds, [1])
        self.assertEqual((stage / 'controller-build.json').read_bytes(), receipt)

    def test_controller_does_not_rebuild_when_receipt_is_lost_after_configuration(self):
        request, home, stage, artifact, builds, _ = self.controller_fixture()
        p.controller(request)
        (stage / 'controller-build.json').unlink()
        deployment = home / '.config/symphony/pilot/deployment.json'
        deployment.parent.mkdir(parents=True)
        deployment.write_text('retained manifest')
        original = artifact.read_bytes()
        with self.assertRaisesRegex(ValueError, 'controller_build_receipt_missing'):
            p.controller(request)
        self.assertEqual(builds, [1])
        self.assertEqual(artifact.read_bytes(), original)
        self.assertEqual(deployment.read_text(), 'retained manifest')

    def test_controller_rejects_changed_build_inputs_and_unsafe_receipt(self):
        request, home, stage, artifact, builds, _ = self.controller_fixture()
        p.controller(request)
        request['manifest']['toolchain']['erlang'] = '28.6'
        with self.assertRaisesRegex(ValueError, 'controller_build_inputs_changed'):
            p.controller(request)
        request['manifest']['toolchain']['erlang'] = '28.5'
        receipt = stage / 'controller-build.json'
        original = receipt.read_bytes()
        receipt.write_text('{invalid')
        with self.assertRaisesRegex(ValueError, 'invalid_controller_build_receipt'):
            p.controller(request)
        receipt.write_bytes(original)
        receipt.chmod(0o666)
        with self.assertRaisesRegex(ValueError, 'unsafe_controller_build_receipt'):
            p.controller(request)
        receipt.chmod(0o600)
        saved = home / 'saved-receipt'
        receipt.rename(saved)
        receipt.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, 'unsafe_controller_build_receipt'):
            p.controller(request)
        self.assertEqual(builds, [1])

    def test_interrupted_first_build_resumes_before_any_manifest_is_accepted(self):
        request, _, stage, artifact, builds, runner = self.controller_fixture()
        execute = runner.side_effect
        def interrupted(argv, **kwargs):
            value = execute(argv, **kwargs)
            if argv[-2:] == ['mix', 'build']:
                raise ValueError('simulated interruption')
            return value
        runner.side_effect = interrupted
        with self.assertRaisesRegex(ValueError, 'simulated interruption'):
            p.controller(request)
        self.assertFalse((stage / 'controller-build.json').exists())
        runner.side_effect = execute
        p.controller(request)
        self.assertEqual(builds, [1, 2])
        saved = json.loads((stage / 'controller-build.json').read_text())
        self.assertEqual(saved['artifact_sha256'], hashlib.sha256(artifact.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
