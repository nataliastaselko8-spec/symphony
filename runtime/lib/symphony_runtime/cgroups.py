"""Validate one dedicated service scope; ancestors are never firewall targets."""
from pathlib import Path, PurePosixPath
import re

from .common import require


def service_group(value, unit=None):
    require(isinstance(value, str) and 0 < len(value) < 480 and value.startswith("/"), "invalid_service_cgroup")
    path = PurePosixPath(value)
    require("//" not in value and str(path) == value and all(re.fullmatch(r"[A-Za-z0-9_.-]+", p) and p not in (".", "..")
                                    for p in path.parts[1:]), "invalid_service_cgroup")
    require(len(path.parts) >= 3 and path.parent.name == "system.slice" and
            re.fullmatch(r"symphony-[A-Za-z0-9_-]{1,41}\.service", path.name), "dedicated_service_required")
    require(unit is None or path.name == unit, "service_cgroup_unit_mismatch")
    return value


def current_group():
    rows = Path("/proc/self/cgroup").read_text().splitlines()
    require(len(rows) == 1 and rows[0].startswith("0::/"), "unified_cgroup_required")
    return rows[0][3:]


def retained_payload(value, current):
    """Validate a previous payload without assuming WSL kept its distro prefix."""
    require(isinstance(value, str), "invalid_recorded_cgroup")
    path = PurePosixPath(value)
    require(str(path) == value and path.parent.name == "payload" and
            re.fullmatch(r"libpod-[0-9a-f]{64}", path.name), "invalid_recorded_cgroup")
    service_group(str(path.parent.parent), PurePosixPath(service_group(current)).name)
    return value


def resources(group):
    path = Path("/sys/fs/cgroup") / service_group(group).lstrip("/")
    controllers = set((path / "cgroup.controllers").read_text().split())
    require({"cpu", "memory", "pids"} <= controllers, "worker_resource_controllers_missing")
    return path.stat().st_ino
