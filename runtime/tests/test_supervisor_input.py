"""A dead Windows manager cannot leave the controller admitting work."""
import io
import os
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.cli import SupervisorInput


class SupervisorTests(unittest.TestCase):
    def test_eof_and_invalid_input_close_lease(self):
        for raw in (b"", b"ALIVE\n", b"not-a-heartbeat\n", b"a" * 100):
            lease = SupervisorInput(io.BytesIO(raw))
            self.assertTrue(lease.closed.wait(1))
            self.assertFalse(lease.healthy())

    def test_open_pipe_needs_recent_heartbeat_including_suspend(self):
        read, write = os.pipe()
        with os.fdopen(read, "rb") as reader, os.fdopen(write, "wb", buffering=0) as writer:
            lease = SupervisorInput(reader)
            self.assertTrue(lease.healthy())
            initial = lease.last_seen
            writer.write(b"ALIVE\n")
            deadline = time.monotonic() + 2
            while lease.last_seen == initial and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertGreater(lease.last_seen, initial)
            with patch("symphony_runtime.cli.time.clock_gettime", return_value=lease.last_seen + 16):
                self.assertFalse(lease.healthy())
            writer.close()
            self.assertTrue(lease.closed.wait(1))
            self.assertFalse(lease.healthy())


if __name__ == "__main__":
    unittest.main()
