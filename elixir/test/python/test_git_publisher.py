import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).parents[2] / "priv/git_publisher.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublisherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="publisher-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.remote = self.root / "remote.git"
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "dev", str(self.work))
        self.git("config", "user.name", "Test", cwd=self.work)
        self.git("config", "user.email", "test@example.invalid", cwd=self.work)
        (self.work / "app.txt").write_text("base")
        self.commit()
        self.base = self.git("rev-parse", "HEAD", cwd=self.work).strip()
        self.git("push", str(self.remote), "dev", cwd=self.work)
        self.git("checkout", "-b", "agent/task-a", cwd=self.work)
        (self.work / "app.txt").write_text("feature")
        self.commit()
        self.sha = self.git("rev-parse", "HEAD", cwd=self.work).strip()
        self.bundle = self.root / "candidate.bundle"
        self.git("bundle", "create", str(self.bundle), "agent/task-a", cwd=self.work)
        self.bundle.chmod(0o600)
        self.request = dict(bundle=str(self.bundle), sha=self.sha, base_sha=self.base, previous_sha=None,
                            branch="agent/task-a", repo="ExampleOrg/app", token=None, send=True, digest=None)

    def git(self, *args, cwd=None):
        return subprocess.check_output(["git", *args], cwd=cwd or self.root, stderr=subprocess.DEVNULL, text=True)

    def commit(self):
        self.git("add", ".", cwd=self.work)
        self.git("commit", "-m", "Test", cwd=self.work)

    def test_publish_and_readback_replay_keeps_dev(self):
        result = publisher.publish(self.request, str(self.remote))
        self.assertEqual(result["sha"], self.sha)
        self.assertEqual(publisher.publish(self.request, str(self.remote)), result)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "dev").strip(), self.base)

    def test_validate_without_credentials_or_remote_effect(self):
        result = publisher.publish(dict(self.request, send=False))
        self.assertEqual(result["sha"], self.sha)
        self.assertNotIn("agent/task-a", self.git("--git-dir=" + str(self.remote), "show-ref"))

    def test_forbidden_refs_options_digest_and_foreign_base(self):
        for patch in [dict(branch="dev"), dict(branch="main"), dict(branch="--mirror"), dict(branch="agent/a//b"),
                      dict(sha="--help"), dict(base_sha="a" * 40), dict(digest="b" * 64), dict(repo="../../tmp"), dict(send="yes")]:
            with self.subTest(patch=patch), self.assertRaises((ValueError, subprocess.SubprocessError)):
                publisher.publish(dict(self.request, **patch), str(self.remote))

    def test_unexpected_remote_history_is_not_overwritten(self):
        self.git("--git-dir=" + str(self.remote), "update-ref", "refs/heads/agent/task-a", self.base)
        with self.assertRaises(ValueError):
            publisher.publish(self.request, str(self.remote))
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "agent/task-a").strip(), self.base)

    def test_workflow_change_and_symlink_bundle_are_rejected(self):
        (self.work / ".github/workflows").mkdir(parents=True)
        (self.work / ".github/workflows/evil.yml").write_text("name: evil")
        self.commit()
        sha = self.git("rev-parse", "HEAD", cwd=self.work).strip()
        self.bundle.unlink()
        self.git("bundle", "create", str(self.bundle), "agent/task-a", cwd=self.work)
        with self.assertRaises(ValueError):
            publisher.publish(dict(self.request, sha=sha), str(self.remote))
        link = self.root / "link.bundle"
        link.symlink_to(self.bundle)
        with self.assertRaises(ValueError):
            publisher.publish(dict(self.request, bundle=str(link)), str(self.remote))

    def test_untrusted_git_config_and_hooks_are_not_loaded(self):
        marker = self.root / "hook-ran"
        hook = self.work / ".git/hooks/pre-push"
        hook.write_text("#!/bin/sh\ntouch " + str(marker))
        hook.chmod(0o700)
        os.environ["GIT_CONFIG_COUNT"] = "1"
        os.environ["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        os.environ["GIT_CONFIG_VALUE_0"] = str(hook.parent)
        try:
            publisher.publish(self.request, str(self.remote))
            self.assertFalse(marker.exists())
        finally:
            for key in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"]:
                os.environ.pop(key, None)

    def test_receive_pack_race_is_rejected_even_when_normal_push_would_fast_forward(self):
        original = publisher.git

        def concurrent(args, root, extra=None, codes=(0,)):
            if "push" in args:
                self.git("--git-dir=" + str(self.remote), "update-ref", "refs/heads/agent/task-a", self.base)
            return original(args, root, extra, codes)

        with patch.object(publisher, "git", concurrent), self.assertRaises(ValueError):
            publisher.publish(self.request, str(self.remote))
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "agent/task-a").strip(), self.base)

    def test_existing_branch_only_accepts_a_descendant_and_expected_old_head(self):
        publisher.publish(self.request, str(self.remote))
        (self.work / "app.txt").write_text("fix")
        self.commit()
        new = self.git("rev-parse", "HEAD", cwd=self.work).strip()
        self.bundle.unlink()
        self.git("bundle", "create", str(self.bundle), "agent/task-a", cwd=self.work)
        result = publisher.publish(dict(self.request, sha=new, previous_sha=self.sha), str(self.remote))
        self.assertEqual(result["sha"], new)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "dev").strip(), self.base)

    def test_extra_refs_lfs_and_submodule_candidates_are_rejected(self):
        self.bundle.unlink()
        self.git("bundle", "create", str(self.bundle), "--all", cwd=self.work)
        with self.assertRaises(ValueError):
            publisher.publish(self.request, str(self.remote))
        self.bundle.unlink()
        (self.work / "asset").write_text("version https://git-lfs.github.com/spec/v1\noid sha256:fake\nsize 1\n")
        self.commit()
        sha = self.git("rev-parse", "HEAD", cwd=self.work).strip()
        self.git("bundle", "create", str(self.bundle), "agent/task-a", cwd=self.work)
        with self.assertRaises(ValueError):
            publisher.publish(dict(self.request, sha=sha), str(self.remote))
        self.bundle.unlink()
        self.git("rm", "asset", cwd=self.work)
        self.git("update-index", "--add", "--cacheinfo", "160000," + self.base + ",sub", cwd=self.work)
        self.git("-c", "user.name=Test", "commit", "-m", "Submodule", cwd=self.work)
        sha = self.git("rev-parse", "HEAD", cwd=self.work).strip()
        self.git("bundle", "create", str(self.bundle), "agent/task-a", cwd=self.work)
        with self.assertRaises(ValueError):
            publisher.publish(dict(self.request, sha=sha), str(self.remote))


if __name__ == "__main__":
    unittest.main()
