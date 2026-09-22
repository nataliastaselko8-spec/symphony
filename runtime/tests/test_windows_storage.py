"""Physical-volume freshness and ownership, using private files and real pipes."""
import copy
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime import windows_storage as storage
from symphony_runtime.cli import SupervisorInput
from symphony_runtime.common import Rejected, atomic, canonical

GIB = 1024**3


class WindowsStorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="windows-disk-", dir=Path.home())
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = {"state_root": str(self.root), "windows_installation_id": "a" * 32,
                       "controller_distro": "controller", "worker_distro": "worker",
                       "disk_minimum_bytes": 5 * GIB, "disk_warning_bytes": 10 * GIB}
        self.token = "b" * 32
        self.frame = {"schema_version": 1, "installation_id": "a" * 32, "manager_token": self.token,
                      "measured_at_ms": int(time.time() * 1000), "disks": {
                          role: {"distro": role, "volume": "volume:12345678-1234-1234-1234-123456789abc",
                                 "free_bytes": 100 * GIB, "error": None} for role in ("controller", "worker")}}
        atomic(self.root / "launcher.json", canonical({"token": "launcher-current"}))
        self.disk = {"free_bytes": 500 * GIB, "status": "ready"}

    def save(self):
        storage.retain(self.frame, self.config, self.token, "launcher-current")

    def report(self):
        return storage.report(self.config, self.disk, self.disk)

    def test_shared_volume_is_not_counted_twice(self):
        self.frame["disks"]["worker"]["free_bytes"] = 8 * GIB
        self.save()
        report, reasons = self.report()
        self.assertEqual(reasons, [])
        windows = report["windows_disk"]
        self.assertEqual(len(windows["volumes"]), 1)
        self.assertEqual(windows["volumes"][0]["free_bytes"], 8 * GIB)
        self.assertEqual(windows["status"], "warning")
        for role in ("controller", "worker"):
            self.assertEqual(report[role + "_disk"]["effective_free_bytes"], 8 * GIB)

    def test_separate_volumes_and_exact_thresholds(self):
        self.frame["disks"]["worker"]["volume"] = "volume:abcdefab-1234-1234-1234-123456789abc"
        for free, status in ((5 * GIB - 1, "blocked"), (5 * GIB, "warning"), (10 * GIB - 1, "warning"), (10 * GIB, "ready")):
            with self.subTest(free=free):
                self.frame["disks"]["worker"]["free_bytes"] = free
                self.save()
                result, reasons = self.report()
                self.assertEqual(result["windows_disk"]["status"], status)
                self.assertEqual(len(result["windows_disk"]["volumes"]), 2)
                self.assertEqual(result["controller_disk"]["status"], "ready")
                self.assertEqual(bool(reasons), status == "blocked")

    def test_smaller_virtual_capacity_is_still_the_limit(self):
        self.save()
        small = {"free_bytes": 2 * GIB, "status": "blocked"}
        report, _ = storage.report(self.config, small, self.disk)
        self.assertEqual(report["controller_disk"]["effective_free_bytes"], 2 * GIB)
        self.assertEqual(report["controller_disk"]["status"], "blocked")

    def test_missing_old_launch_wrong_config_and_boot_are_unknown(self):
        self.assertEqual(self.report()[1], ["windows_disk_unknown"])
        self.save()
        atomic(self.root / "launcher.json", canonical({"token": "previous"}))
        self.assertEqual(self.report()[1], ["windows_disk_unknown"])
        atomic(self.root / "launcher.json", canonical({"token": "launcher-current"}))
        self.config["controller_distro"] = "other"
        self.assertEqual(self.report()[1], ["windows_disk_unknown"])
        self.config["controller_distro"] = "controller"
        with patch.object(storage.Path, "read_text", return_value="other-boot"):
            self.assertEqual(self.report()[1], ["windows_disk_unknown"])

    def test_staleness_includes_suspend_and_queued_old_frames(self):
        self.save()
        with patch.object(storage, "clock", return_value=storage.clock() + 16):
            self.assertEqual(self.report()[1], ["windows_disk_unknown"])
        self.frame["measured_at_ms"] -= 16_000
        with self.assertRaisesRegex(Rejected, "stale"):
            self.save()

    def test_measurement_error_is_explicit_unknown_without_zero_free(self):
        self.frame["disks"]["worker"].update(error="measurement_unavailable", free_bytes=None, volume=None)
        self.save()
        result, reasons = self.report()
        self.assertEqual(reasons, ["windows_disk_unknown"])
        self.assertIsNone(result["worker_disk"]["effective_free_bytes"])
        self.assertEqual(len(result["windows_disk"]["volumes"]), 1)

    def test_invalid_identity_shape_and_values_fail_closed(self):
        for path, value in ((["installation_id"], "other"), (["manager_token"], "old"),
                            (["schema_version"], True), (["measured_at_ms"], 0),
                            (["disks", "worker", "distro"], "foreign"),
                            (["disks", "worker", "free_bytes"], -1),
                            (["disks", "worker", "free_bytes"], True),
                            (["disks", "worker", "volume"], "D:")):
            frame = copy.deepcopy(self.frame)
            cursor = frame
            for key in path[:-1]:
                cursor = cursor[key]
            cursor[path[-1]] = value
            with self.subTest(path=path), self.assertRaises(Rejected):
                storage.retain(frame, self.config, self.token, "launcher-current")

    def test_real_pipe_retains_data_and_rejects_old_alive_protocol(self):
        read, write = os.pipe()
        with os.fdopen(read, "rb") as reader, os.fdopen(write, "wb", buffering=0) as writer:
            lease = SupervisorInput(reader, lambda frame: storage.retain(frame, self.config, self.token, "launcher-current"))
            writer.write(canonical(self.frame) + b"\n")
            deadline = time.monotonic() + 2
            while not (self.root / "windows-disk.json").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(self.report()[1], [])
            self.assertTrue(lease.healthy())
            writer.write(b"ALIVE\n")
            self.assertTrue(lease.closed.wait(1))
            self.assertFalse(lease.healthy())

    def test_legacy_non_windows_runtime_keeps_existing_storage_contract(self):
        self.config.pop("windows_installation_id")
        self.assertEqual(self.report(), ({"controller_disk": self.disk, "worker_disk": self.disk}, []))
