"""Build and clone a real portable bundle from two miniature accepted Git repos."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("bundle", Path(__file__).parents[1] / "bundle.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source, self.profile = self.root / "source", self.root / "profile"
        for directory in (self.source, self.profile):
            directory.mkdir()
            b.git(directory, "init", "-qb", "main")
        (self.source / "runtime").mkdir()
        (self.source / "runtime/code.py").write_text("# fixture\n")
        (self.source / "tools/wsl").mkdir(parents=True)
        for name in ("symphony.ps1", "setup.ps1", "support.ps1", "manager.ps1", "operator.ps1", "operator.py", "provision.py", "update.ps1", "update.py"):
            (self.source / "tools/wsl" / name).write_text("# " + name + "\n")
        self.commit(self.source)
        revision = b.git(self.source, "rev-parse", "HEAD").decode().strip()
        (self.profile / "worker").mkdir()
        (self.profile / "worker/profile-lock.json").write_text(json.dumps({"symphony_commit": revision, "runtime_contract": 2}))
        self.commit(self.profile)
        asset = self.root / "artifact"
        asset.write_bytes(bytes(range(256)))
        self.args = argparse.Namespace(symphony=str(self.source), profile=str(self.profile), symphony_commit=revision,
            profile_revision=b.git(self.profile, "rev-parse", "HEAD").decode().strip(), rootfs=str(asset), mise=str(asset),
            image_archive=str(asset), worker_image="sha256:" + "b" * 64, erlang="28.4", elixir="1.19.5-otp-28", output=str(self.root / "bundle"))

    def commit(self, root):
        b.git(root, "add", ".")
        b.git(root, "-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")

    def test_bundle_is_independent_of_source_and_records_all_hashes(self):
        result = b.create(self.args)
        manifest = json.loads(Path(result["bundle"]).read_text())
        self.assertEqual(result["sha256"], b.hash_file(result["bundle"]))
        for item in manifest["assets"].values():
            file = Path(result["bundle"]).parent / item["file"]
            self.assertEqual(item["sha256"], b.hash_file(file))
            self.assertEqual(item["size"], file.stat().st_size)
        clone = self.root / "another-machine"
        subprocess.run(["git", "clone", str(Path(result["bundle"]).parent / "symphony.bundle"), str(clone)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(b.git(clone, "rev-parse", "HEAD").decode().strip(), self.args.symphony_commit)
        self.assertNotIn(str(self.source), json.dumps(manifest))
        self.assertNotIn(str(self.profile), json.dumps(manifest))

    def test_dirty_revision_or_existing_destination_is_rejected(self):
        (self.source / "unpublished").write_text("retain me")
        with self.assertRaisesRegex(ValueError, "clean_accepted_checkout"):
            b.create(self.args)
        self.assertFalse(Path(self.args.output).exists())
        (self.source / "unpublished").unlink()
        Path(self.args.output).mkdir()
        (Path(self.args.output) / "retained").write_text("retain me")
        with self.assertRaisesRegex(ValueError, "new_bundle_directory"):
            b.create(self.args)
        self.assertEqual((Path(self.args.output) / "retained").read_text(), "retain me")

    def test_incompatible_profile_rejected_before_output(self):
        (self.profile / "worker/profile-lock.json").write_text(json.dumps({"symphony_commit": "d" * 40, "runtime_contract": 2}))
        self.commit(self.profile)
        self.args.profile_revision = b.git(self.profile, "rev-parse", "HEAD").decode().strip()
        with self.assertRaisesRegex(ValueError, "profile_runtime_pin_mismatch"):
            b.create(self.args)
        self.assertFalse(Path(self.args.output).exists())


if __name__ == "__main__":
    unittest.main()
