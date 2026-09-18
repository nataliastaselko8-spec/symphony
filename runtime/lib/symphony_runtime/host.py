"""Explicit root supervisor for one delegated worker service and its scoped firewall."""
import json
import os
from pathlib import Path
import pwd
import re
import signal
import socket
import subprocess
import time

from .common import Rejected, lease_clock, no_links, read_json, require
from .network import Firewall, host_addresses
from .cgroups import service_group, resources


def run(*args, allowed=(0,)):
    result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
                            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"})
    require(result.returncode in allowed, "host_command_failed_" + Path(args[0]).name)
    return result.stdout.decode().strip()


def trusted_tree(path):
    path = no_links(path)
    for entry in (path, *path.parents, *path.rglob("*")):
        info = entry.lstat()
        require(not entry.is_symlink() and info.st_uid == 0 and info.st_mode & 0o022 == 0, "root_owned_runtime_copy_required")
    require((path / "scripts/guardian.py").is_file(), "runtime_package_missing")
    return path


class HostSession:
    """No persistent service enablement. Leaving this context stops only its own units."""
    def __init__(self, package, user, image, root, name):
        require(os.geteuid() == 0, "host_setup_requires_root")
        require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,40}", name), "invalid_service_name")
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", image), "image_digest_required")
        self.package = trusted_tree(package)
        self.account = pwd.getpwnam(user)
        require(self.account.pw_uid != 0, "unprivileged_worker_required")
        self.root = no_links(root)
        require(self.root.is_relative_to(self.account.pw_dir) and self.root != Path(self.account.pw_dir), "worker_private_storage_required")
        require(self.root.is_dir() and self.root.stat().st_uid == self.account.pw_uid and self.root.stat().st_mode & 0o077 == 0, "worker_storage_permissions")
        self.unit = "symphony-" + name + ".service"
        self.group = None
        self.image = image
        self.policy_dir = Path("/run/symphony-runtime") / name
        self.policy = self.policy_dir / "network.json"
        self.firewall = None
        self.installed = False
        self.started = False
        self.management = None

    def __enter__(self):
        require(not self.policy_dir.exists(), "runtime_scope_already_exists")
        parent = no_links(self.policy_dir.parent)
        parent.mkdir(mode=0o755, exist_ok=True)
        require(parent.stat().st_uid == 0 and parent.stat().st_mode & 0o022 == 0, "unsafe_policy_parent")
        self.policy_dir.mkdir(mode=0o755)
        try:
            # systemd may live below a per-distro WSL subtree. Explicitly place
            # the unit in its system.slice, then verify the real unit path.
            parent = run("/usr/bin/systemctl", "show", "system.slice", "--property=ControlGroup", "--value")
            self.group = service_group(parent + "/" + self.unit, self.unit).lstrip("/")
            run("/usr/bin/systemd-run", "--unit=" + self.unit, "--collect", "--service-type=exec",
                "--slice=system.slice",
                "--property=User=" + self.account.pw_name, "--property=Delegate=yes", "--property=DelegateSubgroup=supervisor",
                "--property=KillMode=control-group", "--property=TimeoutStopSec=40", "--property=RuntimeMaxSec=12h",
                "--setenv=HOME=" + self.account.pw_dir, "--setenv=XDG_RUNTIME_DIR=/run/user/" + str(self.account.pw_uid),
                "/usr/bin/python3", "-I", str(self.package / "scripts/guardian.py"), "--root", str(self.root),
                "--image", self.image, "--cgroup", "/" + self.group, "--policy", str(self.policy))
            self.started = True
            actual = run("/usr/bin/systemctl", "show", self.unit, "--property=ControlGroup", "--value")
            require(service_group(actual, self.unit) == "/" + self.group, "service_cgroup_changed")
            group = Path("/sys/fs/cgroup") / self.group
            deadline = time.monotonic() + 10
            while not group.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.cgroup_inode = resources(actual)
            self.firewall = Firewall(self.group, ["1.1.1.1", "1.0.0.1"])
            self.addresses = host_addresses()
            self.firewall.install(self.addresses)
            self.installed = True
            self.refresh()
            from .guardian import header, send_header
            deadline = time.monotonic() + 15
            acknowledged = False
            while time.monotonic() < deadline:
                try:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                        connection.settimeout(1)
                        connection.connect(str(self.root / "control.sock"))
                        stream = connection.makefile("rwb", buffering=0)
                        send_header(stream, {"action": "status"})
                        acknowledged = "ok" in header(stream)
                    if acknowledged:
                        break
                except (OSError, Rejected):
                    time.sleep(0.05)
            require(acknowledged, "guardian_start_failed")
            return self
        except BaseException:
            self.close()
            raise

    def refresh(self):
        # Changes to interfaces or externally removed rules close the gate; never silently repair them.
        require(host_addresses() == self.addresses, "host_network_changed_restart_required")
        require(run("/usr/bin/systemctl", "show", self.unit, "--property=ControlGroup", "--value") == "/" + self.group,
                "service_cgroup_changed")
        require(resources("/" + self.group) == self.cgroup_inode, "service_cgroup_replaced")
        for family in (4, 6):
            self.firewall.rule(family, "-C", "OUTPUT", *self.firewall.jump())
        value = {"ready": True, "image": self.image, "cgroup": "/" + self.group,
                 "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                 "cgroup_inode": self.cgroup_inode,
                 "valid_until_monotonic": lease_clock() + 20}
        temporary = self.policy_dir / "network.pending"
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o644)
        temporary.replace(self.policy)

    def management_ssh(self, port, public_key):
        """A separate root-owned sshd exposes only framed worker-control; never a shell."""
        from .guardian import public_key as validate_key
        require(type(port) is int and 1024 <= port <= 65535, "invalid_management_port")
        require(Path("/usr/sbin/sshd").is_file(), "openssh_server_required")
        require(self.management is None, "management_already_started")
        key = self.policy_dir / "management_host_key"
        run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key))
        authorized = self.policy_dir / "authorized_keys"
        authorized.write_text(validate_key(public_key))
        authorized.chmod(0o644)
        require(re.fullmatch(r"[a-z_][a-z0-9_-]*", self.account.pw_name), "invalid_worker_account")
        # Only the generated, simple /run path enters sshd's shell command. Actual paths stay JSON data.
        relay = self.policy_dir / "relay.py"
        relay.write_text("import json,os,pathlib,sys\nc=json.loads(pathlib.Path(__file__).with_suffix('.json').read_text())\nos.execve('/usr/bin/python3', ['/usr/bin/python3','-I','-B',c['script'],'--root',c['root']],c['env'])\n")
        relay.with_suffix(".json").write_text(json.dumps({"script": str(self.package / "scripts/worker-control.py"), "root": str(self.root),
            "env": {"HOME": self.account.pw_dir, "XDG_RUNTIME_DIR": "/run/user/" + str(self.account.pw_uid)}}))
        config = self.policy_dir / "sshd_config"
        config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {key}
PidFile {self.policy_dir}/sshd.pid
AuthorizedKeysFile {authorized}
AllowUsers {self.account.pw_name}
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
PrintMotd no
PrintLastLog no
PermitRootLogin no
PermitTTY no
PermitTunnel no
PermitUserRC no
PermitUserEnvironment no
DisableForwarding yes
StrictModes yes
LogLevel ERROR
ForceCommand /usr/bin/python3 -I -B {relay}
""")
        Path("/run/sshd").mkdir(mode=0o755, exist_ok=True)
        run("/usr/sbin/sshd", "-t", "-f", str(config))
        self.management = self.unit.removesuffix(".service") + "-management.service"
        run("/usr/bin/systemd-run", "--unit=" + self.management, "--collect", "--service-type=exec",
            "--property=KillMode=control-group", "--property=TimeoutStopSec=10", "--property=RuntimeMaxSec=12h",
            "/usr/sbin/sshd", "-D", "-e", "-f", str(config))
        return " ".join(key.with_suffix(".pub").read_text().split()[:2])

    def close(self):
        self.policy.unlink(missing_ok=True)
        if self.management:
            run("/usr/bin/systemctl", "stop", self.management, allowed=(0, 5))
        if self.started:
            run("/usr/bin/systemctl", "stop", self.unit, allowed=(0, 5))
        if self.group is not None:
            group = Path("/sys/fs/cgroup") / self.group
            require(not group.exists() or not any(p.read_text().strip() for p in group.rglob("cgroup.procs")), "service_stop_unconfirmed_keep_firewall")
        if self.installed:
            self.firewall.remove()
        # Explicit files only; no recursive delete of a configured path.
        for name in ("network.json", "network.pending", "management_host_key", "management_host_key.pub", "authorized_keys", "sshd_config", "sshd.pid", "relay.py", "relay.json"):
            (self.policy_dir / name).unlink(missing_ok=True)
        if self.policy_dir.exists():
            self.policy_dir.rmdir()

    def __exit__(self, *_):
        self.close()


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="Root-owned host JSON, outside the checkout")
    args = parser.parse_args()
    file = no_links(args.config)
    require(file.stat().st_uid == 0 and file.stat().st_mode & 0o022 == 0, "root_owned_host_configuration_required")
    config = read_json(file)
    require(set(config) == {"package", "user", "image", "root", "name", "management_port", "management_public_key"}, "invalid_host_configuration")
    stop = False
    def requested(*_):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGINT, requested)
    signal.signal(signal.SIGTERM, requested)
    with HostSession(**{key: config[key] for key in ("package", "user", "image", "root", "name")}) as host:
        pub = host.management_ssh(config["management_port"], config["management_public_key"])
        print(json.dumps({"ready": True, "management_host_public_key": pub}), flush=True)
        while not stop:
            host.refresh()
            time.sleep(2)
