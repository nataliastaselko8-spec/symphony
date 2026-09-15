#!/usr/bin/env python3
"""Manual WSL canary. Run with python3 -I ... --run; never runs Codex.
Temporarily creates its own systemd units and narrowly scoped firewall rules.
Does not flush tables, change policies, or remove iptables base structures.
SIGKILL/power loss cannot run finally; emergency cleanup is printed first.
"""
import argparse
import errno
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

USER = "symphony-worker"
UID = 2002
PROBE = r"""
import errno, json, os, socket, sys
family, address, port = sys.argv[1:]
cg = next(x[3:] for x in open("/proc/self/cgroup").read().splitlines()
          if x.startswith("0::"))
result = {"uid": os.geteuid(), "cgroup": cg}
try:
    with socket.socket(socket.AF_INET if family == "4" else socket.AF_INET6,
                       socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect((address, int(port)))
    result["outcome"] = "CONNECTED"
except OSError as exc:
    result["outcome"] = "REFUSED" if exc.errno == errno.ECONNREFUSED else "ERROR"
    result["errno"] = exc.errno
    result["error"] = str(exc)
print(json.dumps(result), flush=True)
"""


def emit(message):
    print(message, flush=True)


class Canary:
    def __init__(self):
        self.tools = {}
        self.listeners = []
        self.rules = []
        self.attempted_rules = []
        self.pending_probes = set()
        self.keeper_attempted = False
        self.deadline = None
        self.prefix = "symphonyprobe" + uuid.uuid4().hex[:16]
        self.slice = self.prefix + ".slice"
        self.keeper = self.prefix + "keeper.service"
        self.cg = "/" + self.slice
        self.sequence = 0
        self.python = str(Path(sys.executable).resolve())

    def command(self, argv, cleanup=False, check=True):
        timeout = 8
        if self.deadline is not None and not cleanup:
            timeout = min(timeout, self.deadline - time.monotonic())
            if timeout <= 0:
                raise RuntimeError("TOTAL_TIMEOUT")
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=timeout,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C", "LC_ALL": "C"},
        )
        if check and result.returncode:
            label = shlex.join([Path(argv[0]).name, *argv[1:]])[:300]
            detail = (
                "stdout=" + repr(result.stdout.strip()[-500:])
                + " stderr=" + repr(result.stderr.strip()[-500:])
            )
            raise RuntimeError(
                label + ": exit=" + str(result.returncode) + " " + detail
            )
        return result

    def preflight(self):
        emit("PHASE PREFLIGHT")
        if not sys.flags.isolated:
            raise RuntimeError("Use python3 -I")
        if sys.platform != "linux" or os.geteuid() != 0:
            raise RuntimeError("Linux root is required")
        if os.environ.get("WSL_DISTRO_NAME") != "Ubuntu-26.04":
            raise RuntimeError("Expected WSL_DISTRO_NAME=Ubuntu-26.04")
        if "microsoft" not in os.uname().release.lower():
            raise RuntimeError("Expected the WSL kernel")
        if Path("/proc/1/comm").read_text().strip() != "systemd":
            raise RuntimeError("PID 1 must be systemd")
        if pwd.getpwnam(USER).pw_uid != UID:
            raise RuntimeError("Unexpected worker UID")
        if not Path("/sys/fs/cgroup/cgroup.controllers").is_file():
            raise RuntimeError("cgroup v2 is required")
        for name in ("systemd-run", "systemctl", "runuser", "sleep", "modinfo",
                     "iptables-nft", "ip6tables-nft"):
            path = shutil.which(name, path="/usr/sbin:/usr/bin:/sbin:/bin")
            if not path:
                raise RuntimeError("Missing tool: " + name)
            self.tools[name] = path
        for name in ("iptables-nft", "ip6tables-nft"):
            if "(nf_tables)" not in self.command([self.tools[name], "--version"]).stdout:
                raise RuntimeError("Expected explicit nft iptables backend")
        for module in ("xt_cgroup", "nft_compat"):
            self.command([self.tools["modinfo"], "-F", "filename", module])
        # list-unit-files returns nonzero for unmatched patterns on systemd 259.
        # Query inventories instead, keeping real systemctl failures fatal.
        for listing in ("list-units", "list-unit-files"):
            result = self.command([
                self.tools["systemctl"], listing, "--all", "--plain", "--full",
                "--no-legend", "--no-pager",
            ])
            unit_names = {
                line.split()[0] for line in result.stdout.splitlines()
                if line.strip()
            }
            collisions = unit_names.intersection({self.slice, self.keeper})
            if collisions:
                raise RuntimeError(
                    "Resource name already exists: " + ", ".join(sorted(collisions))
                )
        if Path("/sys/fs/cgroup", self.cg.lstrip("/")).exists():
            raise RuntimeError("Cgroup path already exists")
        emit("PASS PREFLIGHT")

    def open_listeners(self):
        for version, family, address, tool in (
            ("4", socket.AF_INET, "127.0.0.1", "iptables-nft"),
            ("6", socket.AF_INET6, "::1", "ip6tables-nft"),
        ):
            server = socket.socket(family, socket.SOCK_STREAM)
            self.listeners.append((version, address, server))
            if family == socket.AF_INET6:
                server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            server.bind((address, 0))
            server.listen(16)
            server.settimeout(0.2)
            threading.Thread(target=self.drain, args=(server,), daemon=True).start()
            spec = ["-p", "tcp", "-d", address, "--dport", str(server.getsockname()[1]),
                    "-m", "cgroup", "--path", self.cg.lstrip("/"),
                    "-j", "REJECT", "--reject-with", "tcp-reset"]
            base = [self.tools[tool], "-w", "2"]
            self.rules.append({
                "add": base + ["-I", "OUTPUT", "1"] + spec,
                "delete": base + ["-D", "OUTPUT"] + spec,
                "check": base + ["-C", "OUTPUT"] + spec,
            })

    @staticmethod
    def drain(server):
        while True:
            try:
                connection, _ = server.accept()
                connection.close()
            except socket.timeout:
                continue
            except OSError:
                return

    def emergency_instructions(self):
        emit("EMERGENCY_CLEANUP (only this invocation; run in the same WSL distro)")
        for rule in self.rules:
            emit(shlex.join(rule["delete"]))
        emit(shlex.join([self.tools["systemctl"], "stop", self.slice]))
        emit("END_EMERGENCY_CLEANUP")

    def keeper_check(self):
        state = self.command([
            self.tools["systemctl"], "show", self.keeper,
            "--property=ActiveState", "--value",
        ]).stdout.strip()
        if state != "active":
            raise RuntimeError("KEEPER_NOT_ACTIVE")
        if not Path("/sys/fs/cgroup", self.cg.lstrip("/")).is_dir():
            raise RuntimeError("SLICE_DISAPPEARED")

    def start_keeper(self):
        self.keeper_attempted = True
        self.command([
            self.tools["systemd-run"], "--system", "--quiet", "--collect",
            "--unit=" + self.keeper, "--slice=" + self.slice,
            "--service-type=exec", "--uid=" + USER,
            "--property=RuntimeMaxSec=120", "--property=TimeoutStopSec=3",
            self.tools["sleep"], "120",
        ])
        actual = self.command([
            self.tools["systemctl"], "show", self.slice,
            "--property=ControlGroup", "--value",
        ]).stdout.strip()
        if actual != self.cg:
            raise RuntimeError("Unexpected slice ControlGroup: " + actual)
        self.keeper_check()

    def probe(self, listener, inside, expected, phase):
        self.keeper_check()
        version, address, server = listener
        argv = [self.python, "-I", "-c", PROBE, version, address,
                str(server.getsockname()[1])]
        if inside:
            self.sequence += 1
            unit = self.prefix + "test" + str(self.sequence) + ".service"
            self.pending_probes.add(unit)
            result = self.command([
                self.tools["systemd-run"], "--system", "--quiet", "--wait",
                "--pipe", "--collect", "--service-type=exec", "--uid=" + USER,
                "--unit=" + unit, "--slice=" + self.slice,
                "--property=RuntimeMaxSec=5", "--property=TimeoutStopSec=2",
            ] + argv)
            self.pending_probes.remove(unit)
        else:
            result = self.command([self.tools["runuser"], "-u", USER, "--"] + argv)
        data = json.loads(result.stdout.strip())
        member = data["cgroup"] == self.cg or data["cgroup"].startswith(self.cg + "/")
        if data["uid"] != UID or member != inside or data["outcome"] != expected:
            raise RuntimeError("PROBE_FAILED " + json.dumps(data))
        emit("PASS " + phase + " IPV" + version + (" INSIDE " if inside else " OUTSIDE ")
             + expected)

    def remove_rules(self):
        errors = []
        for rule in reversed(self.attempted_rules):
            try:
                found = self.command(rule["check"], cleanup=True, check=False)
                if found.returncode == 0:
                    self.command(rule["delete"], cleanup=True)
                    found = self.command(rule["check"], cleanup=True, check=False)
                missing = found.returncode == 1 and "Bad rule" in found.stderr
                if not missing:
                    raise RuntimeError("Cannot verify exact rule absence: " + found.stderr.strip())
            except Exception as exc:
                errors.append(str(exc))
        return errors

    def stop_unit(self, unit):
        result = self.command(
            [self.tools["systemctl"], "stop", unit], cleanup=True, check=False)
        if result.returncode and "not loaded" not in result.stderr:
            raise RuntimeError("STOP " + unit + ": " + result.stderr.strip())
        state = self.command([
            self.tools["systemctl"], "show", unit,
            "--property=ActiveState", "--value",
        ], cleanup=True, check=False).stdout.strip()
        if state not in ("inactive", "failed"):
            raise RuntimeError("STOP_UNVERIFIED " + unit + ": " + state)

    def cleanup(self):
        errors = []
        for unit in sorted(self.pending_probes):
            try:
                self.stop_unit(unit)
            except Exception as exc:
                errors.append(str(exc))
        errors.extend(self.remove_rules())
        if self.keeper_attempted:
            for unit in (self.keeper, self.slice):
                try:
                    self.stop_unit(unit)
                except Exception as exc:
                    errors.append(str(exc))
        for _, _, server in self.listeners:
            server.close()
        return errors

    def execute(self):
        self.preflight()
        self.open_listeners()
        self.emergency_instructions()
        self.deadline = time.monotonic() + 60
        self.start_keeper()
        emit("PHASE BASELINE")
        for listener in self.listeners:
            self.probe(listener, False, "CONNECTED", "BASELINE")
            self.probe(listener, True, "CONNECTED", "BASELINE")
        emit("PHASE SCOPED_RULES")
        for rule in self.rules:
            self.attempted_rules.append(rule)
            self.command(rule["add"])
        for listener in self.listeners:
            self.probe(listener, True, "REFUSED", "FILTERED")
            self.probe(listener, False, "CONNECTED", "FILTERED")
        emit("PHASE RESTORE")
        errors = self.remove_rules()
        if errors:
            raise RuntimeError("; ".join(errors))
        for listener in self.listeners:
            self.probe(listener, True, "CONNECTED", "RESTORED")


def interrupted(signum, _frame):
    raise RuntimeError("SIGNAL " + signal.Signals(signum).name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="perform the temporary local canary")
    if not parser.parse_args().run:
        parser.error("Explicit --run is required")
    canary = Canary()
    passed = False
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        canary.execute()
        passed = True
    except Exception as exc:
        emit("FAIL " + str(exc))
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        errors = canary.cleanup()
        for error in errors:
            emit("CLEANUP_UNRESOLVED " + error)
        passed = passed and not errors
    emit("SUMMARY " + ("PASS" if passed else "FAIL"))
    emit("SCOPE cgroup filter canary only; actual pasta/SSH/Codex runtime is not validated")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
