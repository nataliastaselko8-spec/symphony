"""Read-only host configuration checks; container acceptance is a separate gate."""
import configparser
from pathlib import Path

from .common import require


def wsl_settings(config_file=Path('/etc/wsl.conf'), mounts_file=Path('/proc/self/mountinfo')):
    parser = configparser.ConfigParser()
    parser.read(config_file)
    for section, setting in (("automount", "enabled"), ("automount", "mountFsTab"),
                             ("interop", "enabled"), ("interop", "appendWindowsPath")):
        require(parser.getboolean(section, setting, fallback=True) is False, "dedicated_wsl_configuration_required")
    mounts = mounts_file.read_text().splitlines()
    require(not any(" /mnt/c " in row or " /mnt/d " in row or " - drvfs " in row or
                    (" - 9p " in row and "aname=drvfs;" in row) for row in mounts),
            "windows_drives_still_mounted")
    # WSLInterop is a kernel-global registry entry. Another distro can register
    # it while this distro's interop=false is in force. Do not disable it globally
    # or treat its presence as a restart request. Real execution is tested in the
    # task container, including the AF_VSOCK boundary and a valid Windows canary.
