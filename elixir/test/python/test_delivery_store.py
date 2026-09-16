"""Real Linux file/lock tests and process-crash injection for the private store."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "priv" / "delivery_store.py"
if sys.platform == "linux":
    spec = importlib.util.spec_from_file_location("delivery_store", SOURCE)
    storage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(storage)


@unittest.skipUnless(sys.platform == "linux", "Delivery store targets Linux/WSL2")
class DeliveryStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="symphony-store-")
        self.path = Path(self.temp.name) / "cycle.json"

    def tearDown(self):
        self.temp.cleanup()

    def close(self, store):
        os.close(store.lock_fd)
        os.close(store.directory_fd)

    def create(self):
        store = storage.Store(str(self.path))
        self.assertIsNone(store.read())
        store.write({"revision": 1})
        self.close(store)

    def test_lock_and_private_atomic_backup(self):
        first = storage.Store(str(self.path))
        self.addCleanup(self.close, first)
        first.read()
        first.write({"revision": 1})
        first.write({"revision": 2})
        self.assertEqual(first.read(), {"revision": 2})
        self.assertEqual(first.backup_read(), {"revision": 1})
        for path in [self.path, first.backup]:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        script = "import runpy,sys; s=runpy.run_path(sys.argv[1]); s['Store'](sys.argv[2])"
        result = subprocess.run([sys.executable, "-I", "-c", script, str(SOURCE), str(self.path)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_process_death_before_and_after_replace(self):
        for stage, expected in [("before", 1), ("after", 2)]:
            with self.subTest(stage=stage):
                self.create() if not self.path.exists() else None
                script = r"""
import os,runpy,sys
module=runpy.run_path(sys.argv[1])
store=module['Store'](sys.argv[2])
store.read()
original=os.replace
def interrupted(source,target):
    if str(target)==sys.argv[2] and sys.argv[3]=='before':
        os._exit(71)
    original(source,target)
    if str(target)==sys.argv[2] and sys.argv[3]=='after':
        os._exit(72)
os.replace=interrupted
store.write({'revision':2})
"""
                result = subprocess.run([sys.executable, "-I", "-c", script, str(SOURCE), str(self.path), stage], capture_output=True)
                self.assertEqual(result.returncode, 71 if stage == "before" else 72)
                restored = storage.Store(str(self.path))
                try:
                    self.assertEqual(restored.read(), {"revision": expected})
                    self.assertEqual(restored.backup_read(), {"revision": 1})
                finally:
                    self.close(restored)

    def test_backup_failure_does_not_change_current_snapshot(self):
        self.create()
        store = storage.Store(str(self.path))
        self.addCleanup(self.close, store)
        store.read()
        original = self.path.read_bytes()
        with patch.object(storage.os, "replace", side_effect=OSError("injected storage failure")):
            with self.assertRaises(OSError):
                store.write({"revision": 2})
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(list(self.path.parent.glob("*.tmp-*")), [])

    def test_directory_sync_failure_after_replace_is_uncertain_not_acknowledged(self):
        self.create()
        store = storage.Store(str(self.path))
        self.addCleanup(self.close, store)
        store.read()
        original = storage.os.fsync

        def fail_final_sync(descriptor):
            if descriptor == store.directory_fd and storage.unpack(self.path.read_bytes()) == {"revision": 2}:
                raise OSError("injected directory fsync failure")
            original(descriptor)

        with patch.object(storage.os, "fsync", side_effect=fail_final_sync):
            with self.assertRaises(OSError):
                store.write({"revision": 2})
        self.assertEqual(storage.unpack(self.path.read_bytes()), {"revision": 2})
        with self.assertRaisesRegex(ValueError, "external_change"):
            store.write({"revision": 3})

    def test_checksum_corruption_and_missing_initialized_file_fail_closed(self):
        self.create()
        store = storage.Store(str(self.path))
        self.addCleanup(self.close, store)
        envelope = json.loads(self.path.read_bytes())
        envelope["snapshot"]["revision"] = 999
        self.path.write_bytes(storage.encode(envelope))
        with self.assertRaisesRegex(ValueError, "checksum_mismatch"):
            store.read()
        with self.assertRaisesRegex(ValueError, "recovery_required"):
            store.write({"revision": 0})
        self.path.unlink()
        with self.assertRaisesRegex(ValueError, "previously_initialized_store_missing"):
            store.read()

    def test_restore_keeps_backup_and_quarantines_bad_input(self):
        self.create()
        store = storage.Store(str(self.path))
        self.addCleanup(self.close, store)
        store.read()
        store.write({"revision": 2})
        self.path.write_bytes(b"corrupted")
        with self.assertRaises(ValueError):
            store.read()
        store.write(store.backup_read(), restore=True)
        self.assertEqual(store.read(), {"revision": 1})
        self.assertEqual(store.backup_read(), {"revision": 1})
        quarantined = list(self.path.parent.glob("*.quarantine-*"))
        self.assertEqual(len(quarantined), 1)
        self.assertEqual(quarantined[0].read_bytes(), b"corrupted")

    def test_unknown_checksum_format_and_oversized_input_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "invalid_envelope"):
            storage.unpack(b'{"snapshot":{}}')
        self.path.write_bytes(b"large")
        self.path.chmod(0o600)
        with patch.object(storage, "MAX_BYTES", 2):
            with self.assertRaisesRegex(ValueError, "snapshot_too_large"):
                storage.read_bytes(self.path)
            with self.assertRaisesRegex(ValueError, "snapshot_too_large"):
                storage.atomic_write(self.path, b"large", -1)

    def test_symlink_hardlink_and_shared_permissions_are_rejected(self):
        target = self.path.parent / "target"
        target.write_bytes(b"private")
        target.chmod(0o600)
        self.path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "unsafe_file"):
            storage.read_bytes(self.path)
        self.path.unlink()
        os.link(target, self.path)
        with self.assertRaisesRegex(ValueError, "unsafe_file"):
            storage.read_bytes(self.path)
        self.path.unlink()
        target.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "unsafe_file"):
            storage.read_bytes(target)


if __name__ == "__main__":
    unittest.main()
