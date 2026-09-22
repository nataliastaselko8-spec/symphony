"""Physical Windows capacity received only through the installation manager pipe."""
import re
import time
from pathlib import Path

from .common import Rejected, atomic, canonical, digest, private_file, read_json, require

MAX_AGE = 15


def clock():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def validate(frame, config, manager_token):
    require(isinstance(frame, dict) and set(frame) == {
        "schema_version", "installation_id", "manager_token", "measured_at_ms", "disks"}, "invalid_windows_disk_frame")
    require(type(frame["schema_version"]) is int and frame["schema_version"] == 1 and
            frame["installation_id"] == config["windows_installation_id"] and
            frame["manager_token"] == manager_token, "windows_disk_identity_mismatch")
    measured = frame["measured_at_ms"]
    require(type(measured) is int and -3000 <= int(time.time() * 1000) - measured <= MAX_AGE * 1000,
            "windows_disk_measurement_stale")
    disks = frame["disks"]
    require(isinstance(disks, dict) and set(disks) == {"controller", "worker"}, "invalid_windows_disks")
    for role, disk in disks.items():
        require(isinstance(disk, dict) and set(disk) == {"distro", "volume", "free_bytes", "error"} and
                disk["distro"] == config[role + "_distro"], "windows_disk_distro_mismatch")
        if disk["error"] is not None:
            require(disk["error"] == "measurement_unavailable" and disk["volume"] is None and disk["free_bytes"] is None,
                    "invalid_windows_disk_error")
        else:
            require(isinstance(disk["volume"], str) and
                    re.fullmatch(r"volume:[0-9a-f-]{36}", disk["volume"]) and
                    type(disk["free_bytes"]) is int and 0 <= disk["free_bytes"] <= 2**63 - 1,
                    "invalid_windows_disk_capacity")
    return frame


def retain(frame, config, manager_token, launcher_token):
    validate(frame, config, manager_token)
    value = {"frame": frame, "received_at": clock(), "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
             "launcher_token": launcher_token, "config_sha256": digest(canonical(config))}
    atomic(Path(config["state_root"]) / "windows-disk.json", canonical(value))


def report(config, local, worker):
    """Never treat a missing/old installation measurement as an independent Linux disk."""
    if not config.get("windows_installation_id"):
        return {"controller_disk": local, "worker_disk": worker}, []
    minimum, warning = config["disk_minimum_bytes"], config["disk_warning_bytes"]
    result = {"controller_disk": {**local, "kind": "wsl_virtual"},
              "worker_disk": {**worker, "kind": "wsl_virtual"},
              "windows_disk": {"status": "unknown", "reason": "windows_disk_unknown", "volumes": [], "measured_at_ms": None}}
    try:
        root = Path(config["state_root"])
        stored = read_json(private_file(root / "windows-disk.json"))
        launcher = read_json(private_file(root / "launcher.json"))
        require(stored["config_sha256"] == digest(canonical(config)) and stored["launcher_token"] == launcher["token"] and
                stored["boot_id"] == Path("/proc/sys/kernel/random/boot_id").read_text().strip() and
                0 <= clock() - stored["received_at"] <= MAX_AGE, "windows_disk_measurement_stale")
        frame = validate(stored["frame"], config, stored["frame"]["manager_token"])
        volumes = {}
        unknown = False
        for role, disk in frame["disks"].items():
            if disk["error"]:
                result[role + "_disk"].update(status="unknown", effective_free_bytes=None)
                unknown = True
                continue
            free = disk["free_bytes"]
            volume = volumes.setdefault(disk["volume"], {"id": disk["volume"], "roles": [], "free_bytes": free})
            # A shared volume has one conservative measurement, never two summed budgets.
            volume["free_bytes"] = min(volume["free_bytes"], free)
            volume["roles"].append(role)
        for volume in volumes.values():
            free = volume["free_bytes"]
            volume["status"] = "blocked" if free < minimum else "warning" if free < warning else "ready"
            for role in volume["roles"]:
                disk = result[role + "_disk"]
                effective = min(disk["free_bytes"], free)
                disk.update(effective_free_bytes=effective, windows_volume=volume["id"],
                            status="blocked" if effective < minimum else "warning" if effective < warning else "ready")
        status = "unknown" if unknown else "blocked" if any(v["status"] == "blocked" for v in volumes.values()) else (
            "warning" if any(v["status"] == "warning" for v in volumes.values()) else "ready")
        reason = "windows_disk_unknown" if unknown else "windows_disk_space_low" if status == "blocked" else None
        result["windows_disk"] = {"status": status, "reason": reason, "volumes": list(volumes.values()),
                                  "measured_at_ms": frame["measured_at_ms"]}
        return result, [reason] if reason else []
    except (Rejected, OSError, ValueError, KeyError, TypeError):
        for role in ("controller", "worker"):
            result[role + "_disk"].update(status="unknown", effective_free_bytes=None)
        return result, ["windows_disk_unknown"]
