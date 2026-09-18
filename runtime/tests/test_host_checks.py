from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from symphony_runtime.host_checks import wsl_settings
from symphony_runtime.common import Rejected


class HostChecksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / 'wsl.conf'
        self.mounts = Path(self.temp.name) / 'mountinfo'
        self.text = '[automount]\nenabled=false\nmountFsTab=false\n[interop]\nenabled=false\nappendWindowsPath=false\n'
        self.config.write_text(self.text)
        self.mounts.write_text('10 9 0:34 / /proc/sys/fs/binfmt_misc rw - binfmt_misc binfmt_misc rw\n')

    def test_shared_global_handler_does_not_override_distro_configuration(self):
        with patch.object(Path, 'exists', return_value=True):
            wsl_settings(self.config, self.mounts)

    def test_enabled_or_missing_settings_are_rejected(self):
        for text in (self.text.replace('false', 'true', 1), self.text.replace('mountFsTab=false', ''),
                     self.text.replace('[interop]\nenabled=false', '[interop]\nenabled=true'), ''):
            self.config.write_text(text)
            with self.assertRaisesRegex(Rejected, 'configuration_required'):
                wsl_settings(self.config, self.mounts)

    def test_windows_mounts_are_rejected_at_custom_mountpoints(self):
        for mount in ('10 9 0:34 / /mnt/c rw - 9p C: rw',
                      '10 9 0:34 / /windows rw - 9p C: rw,aname=drvfs;path=C:',
                      '10 9 0:34 / /windows rw - drvfs C: rw'):
            self.mounts.write_text(mount)
            with self.assertRaisesRegex(Rejected, 'windows_drives_still_mounted'):
                wsl_settings(self.config, self.mounts)
