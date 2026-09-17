"""Root-only cgroup firewall. No global flush, policies, or UID-wide filtering."""
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess

from .common import Rejected, canonical, digest, require

DENY4 = ("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
         "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15",
         "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4")
DENY6 = ("::/128", "::1/128", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64",
         "2001:db8::/32", "2002::/16", "fc00::/7", "fe80::/10", "ff00::/8")


class Firewall:
    def __init__(self, cgroup, dns, execute=None):
        require(re.fullmatch(r"system.slice/symphony-[a-zA-Z0-9_-]+\.service", cgroup), "invalid_firewall_cgroup")
        self.cgroup = cgroup
        self.chain = "SWR" + digest(cgroup.encode())[:16].upper()
        self.dns = tuple(str(ipaddress.ip_address(value)) for value in dns)
        self.execute = execute or self._execute

    @staticmethod
    def _execute(args, allowed=(0,)):
        result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=8,
                                env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"})
        require(result.returncode in allowed, "firewall_command_failed")
        return result

    def rule(self, family, *args, allowed=(0,)):
        return self.execute(["/usr/sbin/iptables-nft" if family == 4 else "/usr/sbin/ip6tables-nft", "-w", "2", *args], allowed=allowed)

    def jump(self):
        return ["-m", "cgroup", "--path", self.cgroup, "-j", self.chain]

    def install(self, host_addresses):
        require(os.geteuid() == 0, "firewall_requires_root")
        require((Path("/sys/fs/cgroup") / self.cgroup).is_dir(), "firewall_cgroup_missing")
        # Reject an existing owner; installation is not a blind replacement operation.
        for family in (4, 6):
            result = self.rule(family, "-S", self.chain, allowed=(0, 1))
            require(result.returncode == 1, "firewall_already_installed")
        installed = []
        try:
            for family, denied in ((4, DENY4), (6, DENY6)):
                self.rule(family, "-N", self.chain)
                installed.append(family)
                self.rule(family, "-A", self.chain, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "RETURN")
                for address in self.dns:
                    if ipaddress.ip_address(address).version == family:
                        for protocol in ("udp", "tcp"):
                            self.rule(family, "-A", self.chain, "-p", protocol, "-d", address, "--dport", "53", "-j", "RETURN")
                addresses = [str(ipaddress.ip_address(a)) for a in host_addresses if ipaddress.ip_address(a).version == family]
                for network in (*denied, *addresses):
                    self.rule(family, "-A", self.chain, "-d", network, "-j", "REJECT")
                self.rule(family, "-A", self.chain, "-j", "RETURN")
                self.rule(family, "-I", "OUTPUT", "1", *self.jump())
        except BaseException:
            for family in reversed(installed):
                self._remove(family)
            raise

    def _remove(self, family):
        self.rule(family, "-D", "OUTPUT", *self.jump(), allowed=(0, 1))
        self.rule(family, "-F", self.chain, allowed=(0, 1))
        self.rule(family, "-X", self.chain, allowed=(0, 1))

    def remove(self):
        require(os.geteuid() == 0, "firewall_requires_root")
        group = Path("/sys/fs/cgroup") / self.cgroup
        if group.exists():
            procs = [file for file in group.rglob("cgroup.procs") if file.read_text().strip()]
            require(not procs, "stop_processes_before_removing_firewall")
        for family in (4, 6):
            self._remove(family)


def host_addresses():
    raw = subprocess.check_output(["/usr/sbin/ip", "-j", "address", "show"], timeout=5)
    return [item["local"] for interface in json.loads(raw) for item in interface.get("addr_info", [])]
