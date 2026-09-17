#!/usr/bin/env python3
"""Read-only host diagnostics; no installs, firewall changes, or task launch."""
import argparse
import configparser
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.common import Rejected, require

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--worker", required=True)
parser.add_argument("--image", required=True)
args = parser.parse_args()
checks = []


def check(name, fn):
    try:
        fn()
        checks.append({"check": name, "status": "PASS"})
    except (Rejected, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        checks.append({"check": name, "status": "NOT_READY", "reason": str(error) if isinstance(error, Rejected) else "host_requirement_missing"})


check("root_diagnostics", lambda: require(os.geteuid() == 0, "run_host_diagnostics_as_root"))
check("systemd", lambda: require(Path("/proc/1/comm").read_text().strip() == "systemd", "systemd_required"))
check("cgroup_v2", lambda: require(Path("/sys/fs/cgroup/cgroup.controllers").is_file(), "cgroup_v2_required"))
for tool in ("podman", "pasta", "sshd", "ssh", "iptables-nft", "ip6tables-nft", "systemd-run", "prlimit", "newuidmap", "newgidmap"):
    check(tool, lambda tool=tool: require(shutil.which(tool), "missing_" + tool))


def account():
    user = pwd.getpwnam(args.worker)
    require(user.pw_uid != 0, "worker_must_not_be_root")
    groups = {grp.getgrgid(gid).gr_name for gid in os.getgrouplist(args.worker, user.pw_gid)}
    require(not groups.intersection({"sudo", "docker", "wheel", "lxd", "incus-admin"}), "privileged_worker_group")
    for file in ("/etc/subuid", "/etc/subgid"):
        require(any(row.startswith(args.worker + ":") and int(row.split(":")[2]) >= 65536 for row in Path(file).read_text().splitlines()), "subordinate_ids_required")
    require(Path("/run/user", str(user.pw_uid)).is_dir(), "worker_user_manager_required")
    return user


check("unprivileged_worker", account)


def image():
    import re
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", args.image), "image_digest_required")
    user = account()
    raw = subprocess.check_output(["runuser", "-u", args.worker, "--", "env", "-i", "PATH=/usr/bin:/bin", "HOME=" + user.pw_dir,
        "XDG_RUNTIME_DIR=/run/user/" + str(user.pw_uid), "podman", "image", "inspect", args.image, "--format", "{{.Id}}"], stderr=subprocess.DEVNULL, timeout=15).decode().strip()
    require(raw == args.image.removeprefix("sha256:"), "worker_image_mismatch")


check("local_pinned_image", image)


def wsl():
    if "microsoft" not in os.uname().release.lower():
        return
    parser = configparser.ConfigParser()
    parser.read("/etc/wsl.conf")
    for section, setting in (("automount", "enabled"), ("automount", "mountFsTab"), ("interop", "enabled"), ("interop", "appendWindowsPath")):
        require(parser.getboolean(section, setting, fallback=True) is False, "dedicated_wsl_configuration_required")
    require(not Path("/proc/sys/fs/binfmt_misc/WSLInterop").exists(), "wsl_restart_required")
    mounts = Path("/proc/self/mountinfo").read_text()
    require(not any(" /mnt/c " in row or " /mnt/d " in row for row in mounts.splitlines()), "windows_drives_still_mounted")


check("dedicated_wsl_settings", wsl)
ready = all(row["status"] == "PASS" for row in checks)
print(json.dumps({"host_prerequisites_ready": ready, "execution_enabled": False, "acceptance": "run_explicit_runtime_smoke", "checks": checks}, indent=2))
raise SystemExit(0 if ready else 2)
