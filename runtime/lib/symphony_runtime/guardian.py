"""One host-side resource owner. No GitHub token, business queue, or arbitrary exec API."""
import base64
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import struct
import threading
import time
import uuid

from .common import Rejected, atomic, canonical, command, digest, identifier, lease_clock, locked, no_links, parse_json, private_dir, private_file, read_json, require, sha
from .storage import capacity, collect, retire
from .images import collect_images, register
from .cgroups import service_group, current_group, resources
from . import seccomp

MAX_BUNDLE = 80 * 1024 * 1024
MAX_HEADER = 16384
PREFIX = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"


def receive(stream, size):
    require(0 <= size <= MAX_BUNDLE, "frame_too_large")
    result = bytearray()
    while len(result) < size:
        block = stream.read(min(65536, size - len(result)))
        require(block, "truncated_frame")
        result.extend(block)
    return bytes(result)


def header(stream):
    length = struct.unpack("!I", receive(stream, 4))[0]
    require(0 < length <= MAX_HEADER, "invalid_header_size")
    value = parse_json(receive(stream, length))
    require(isinstance(value, dict), "invalid_request")
    return value


def send_bytes(stream, raw):
    """Raw socket streams may accept only part of a frame in one write."""
    pending = memoryview(raw)
    while pending:
        written = stream.write(pending)
        require(type(written) is int and 0 < written <= len(pending), "incomplete_frame_write")
        pending = pending[written:]
    stream.flush()


def send_header(stream, value):
    raw = canonical(value)
    require(len(raw) <= MAX_HEADER, "response_header_too_large")
    send_bytes(stream, struct.pack("!I", len(raw)) + raw)


def public_key(value):
    require(isinstance(value, str) and re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]{68}", value), "ed25519_public_key_required")
    raw = base64.b64decode(value.split()[1], validate=True)
    require(len(raw) == 51 and raw.startswith(PREFIX), "invalid_public_key")
    return value + "\n"


class Guardian:
    def __init__(self, root, image, cgroup, policy_file, *, podman="/usr/bin/podman", clock=lease_clock):
        require(os.geteuid() != 0, "guardian_must_be_unprivileged")
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", image), "image_digest_required")
        service_group(cgroup)
        current = current_group()
        require(current == cgroup + "/supervisor", "guardian_cgroup_mismatch")
        self.root = private_dir(root)
        require(":" not in str(self.root), "mount_path_contains_separator")
        require(not self.root.is_relative_to("/mnt") and self.root != Path.home(), "dedicated_linux_storage_required")
        self.image, self.cgroup, self.policy_file = image, cgroup, no_links(policy_file)
        self.seccomp_file = self.policy_file.parent / 'worker-seccomp.json'
        self.podman, self.clock = podman, clock
        self.mutex = threading.RLock()
        self.record = read_json(private_file(self.root / "resource.json")) if (self.root / "resource.json").exists() else None
        self.heartbeat_at = self.clock()
        self.started_at = None
        self.ready()
        image_info = parse_json(self.pod("image", "inspect", self.image))[0]
        labels = image_info.get("Labels") or image_info.get("Config", {}).get("Labels") or {}
        self.image_profile = {"profile_revision": labels.get("io.symphony.profile-revision"),
                              "runtime_contract": labels.get("io.symphony.runtime-contract")}
        register(self.root, self.image, self.pod)
        self.next_collection = self.clock() + 3600
        self.retention_days = 7

    def ready(self):
        info = self.policy_file.stat()
        require(info.st_uid == 0 and info.st_mode & 0o022 == 0, "root_owned_policy_required")
        policy = read_json(self.policy_file)
        require(policy.get("cgroup") == self.cgroup and policy.get("boot_id") == Path("/proc/sys/kernel/random/boot_id").read_text().strip(), "network_policy_scope_mismatch")
        require(policy.get("image") == self.image and policy.get("ready") is True, "network_policy_not_ready")
        require(policy.get("cgroup_inode") == (Path("/sys/fs/cgroup") / self.cgroup.lstrip("/")).stat().st_ino, "network_policy_stale")
        resources(self.cgroup)
        seccomp.verify(self.seccomp_file, policy.get('seccomp_sha256'))
        require(type(policy.get("valid_until_monotonic")) in (int, float) and self.clock() < policy["valid_until_monotonic"], "network_policy_expired")

    def save(self):
        atomic(self.root / "resource.json", canonical(self.record))

    def pod(self, *args, **kwargs):
        return command([self.podman, "--cgroup-manager=cgroupfs", *args],
                       env={"HOME": str(Path.home()), "XDG_RUNTIME_DIR": os.environ["XDG_RUNTIME_DIR"]},
                       error_file=self.root / "last-command-error.log", **kwargs)

    def path(self, kind, cycle):
        identifier(cycle)
        base = private_dir(self.root / kind, create=True)
        return private_dir(base / cycle, create=True)

    def base_args(self, name, *, network=False):
        # This allowlist is code-owned. A request cannot append options, mounts, or an entrypoint.
        args = ["run", "--name", name, "--pull=never", "--userns=keep-id:uid=10001,gid=10001",
                "--user=10001:10001", "--read-only", "--cap-drop=all", "--security-opt=no-new-privileges",
                "--security-opt=seccomp=" + str(self.seccomp_file),
                "--cgroupns=private", "--pid=private", "--ipc=private", "--pids-limit=512", "--memory=2g", "--cpus=2",
                "--log-driver=k8s-file", "--log-opt=max-size=2097152",
                "--ulimit=fsize=268435456:268435456",
                "--cgroup-parent=" + self.cgroup + "/payload", "--tmpfs=/tmp:rw,nosuid,nodev,size=256m,mode=1777",
                "--tmpfs=/home/worker:rw,nosuid,nodev,size=64m,mode=1777"]
        if network:
            args += ["--network=pasta", "--dns=1.1.1.1", "--dns=1.0.0.1", "--no-hosts"]
        else:
            args += ["--network=none"]
        return args

    def prepare(self, request, bundle):
        expected = {"action", "cycle", "interval", "generation", "repo", "branch", "base_sha", "bundle_size", "bundle_sha256", "ssh_public_key"}
        require(set(request) == expected, "invalid_prepare_fields")
        for key in ("cycle", "interval", "generation"):
            identifier(request[key])
        sha(request["base_sha"])
        require(isinstance(request["repo"], str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", request["repo"]), "invalid_repo")
        require(isinstance(request["branch"], str) and re.fullmatch(r"agent/[A-Za-z0-9_/-]+", request["branch"]) and "//" not in request["branch"], "invalid_branch")
        require(type(request["bundle_size"]) is int and 0 < request["bundle_size"] <= MAX_BUNDLE, "invalid_bundle_size")
        require(len(bundle) == request["bundle_size"] and digest(bundle) == request["bundle_sha256"], "bundle_digest_mismatch")
        pub = public_key(request["ssh_public_key"])
        binding = digest(canonical(request))
        if self.record and self.record["generation"] == request["generation"]:
            require(self.record["binding"] == binding, "generation_payload_changed")
            return self.summary()
        require(not self.record or self.record["phase"] in ("stopped", "exported"), "worker_stop_required")
        work = self.path("workspaces", request["cycle"])
        keys = self.path("keys", request["generation"])
        seed = self.path("seeds", request["generation"])
        atomic(seed / "seed.bundle", bundle)
        atomic(keys / "authorized_keys", pub.encode())
        command(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(keys / "host_key")])
        self.record = {"phase": "preparing", "binding": binding, "cycle": request["cycle"], "interval": request["interval"],
                       "generation": request["generation"], "repo": request["repo"], "branch": request["branch"],
                       "base_sha": request["base_sha"], "container": "symphony-job-" + request["generation"],
                       "cgroup": None, "reason": None, "export": None}
        self.save()
        atomic(keys / "binding.json", canonical({key: self.record[key] for key in ("cycle", "generation", "repo")}))
        name = "symphony-seed-" + request["generation"]
        try:
            self.pod(*self.base_args(name), "--volume", f"{work}:/workspace:rw", "--volume", f"{seed}:/input:ro",
                     "--entrypoint=/usr/bin/python3", self.image, "-I", "/opt/symphony/git_transfer.py", "seed",
                     request["base_sha"], request["branch"], timeout=60)
        except (Rejected, OSError):
            self.stop("worker_prepare_failed")
            raise
        finally:
            self.pod("rm", "--force", "--ignore", name)
        self.record["phase"] = "prepared"
        self.save()
        return self.summary()

    def bound(self, request, extra=()):
        require(set(request) == {"action", "interval", "generation", *extra}, "invalid_request_fields")
        require(self.record is not None and request["generation"] == self.record["generation"] and request["interval"] == self.record["interval"], "stale_worker_handle")

    def start(self, request):
        self.bound(request, ("active_seconds",))
        require(type(request["active_seconds"]) is int and 1 <= request["active_seconds"] <= 3600, "invalid_deadline")
        if self.record["phase"] == "running":
            return self.summary()  # A retry cannot extend the deadline.
        require(self.record["phase"] == "prepared", "worker_not_prepared")
        self.ready()
        record = self.record
        work = self.path("workspaces", record["cycle"])
        keys = self.path("keys", record["generation"])
        central = private_dir(self.root / "auth", create=True)
        auth = self.path("codex", record["cycle"])
        # Optional operator-provisioned auth only, never an entire controller CODEX_HOME.
        source = central / "auth.json"
        if not source.exists() and not source.is_symlink():
            source = self.root / "codex-auth.json"
        if source.exists() or source.is_symlink():
            private_file(source)
            raw = source.read_bytes()
            require(len(raw) <= 65536, "codex_auth_too_large")
            atomic(auth / "auth.json", raw)
        self.record["phase"] = "starting"
        self.save()
        try:
            self.pod(*self.base_args(record["container"], network=True), "-d", "--publish=127.0.0.1::2222",
                     "--volume", f"{work}:/workspace:rw", "--volume", f"{keys}:/run/worker:ro",
                     "--volume", f"{auth}:/codex:rw", "--env=CODEX_HOME=/codex", self.image)
            info = json.loads(self.pod("inspect", record["container"]))[0]
            path = info["State"]["CgroupPath"]
            require(path.startswith(self.cgroup + "/payload/libpod-"), "container_cgroup_mismatch")
            self.record.update(phase="running", cgroup=path, port=int(info["NetworkSettings"]["Ports"]["2222/tcp"][0]["HostPort"]), active_seconds=request["active_seconds"])
            self.started_at = self.heartbeat_at = self.clock()
            self.save()
        except (Rejected, OSError, ValueError, KeyError):
            self.stop("worker_start_failed")
            raise
        return self.summary()

    def stop(self, reason):
        if self.record is None:
            return {"phase": "stopped"}
        sync_auth = self.record.get("auth_sync_pending", False) or self.record["phase"] in ("starting", "running", "stopping", "stop_unconfirmed")
        self.record["auth_sync_pending"] = sync_auth
        self.record.update(phase="stopping", reason=reason)
        try:
            self.save()
        except (Rejected, OSError):
            pass  # A storage failure must not prevent the actual process stop.
        identifier(self.record["generation"])
        name = "symphony-job-" + self.record["generation"]
        require(self.record["container"] == name, "invalid_container_record")
        try:
            self.pod("stop", "--ignore", "--time=10", name, timeout=20)
            self.pod("rm", "--force", "--ignore", name, timeout=15)
            for prefix in ("symphony-seed-", "symphony-export-"):
                self.pod("rm", "--force", "--ignore", prefix + self.record["generation"], timeout=15)
            group = self.record.get("cgroup")
            if group:
                require(group.startswith(self.cgroup + "/payload/libpod-"), "invalid_recorded_cgroup")
                path = Path("/sys/fs/cgroup") / group.lstrip("/")
                require(not path.exists() or not any(p.read_text().strip() for p in path.rglob("cgroup.procs")), "worker_processes_remain")
            payload = Path("/sys/fs/cgroup") / self.cgroup.lstrip("/") / "payload"
            require(not payload.exists() or not any(p.read_text().strip() for p in payload.rglob("cgroup.procs")), "payload_processes_remain")
            self.record["phase"] = "stopped"
        except (Rejected, OSError):
            self.record["phase"] = "stop_unconfirmed"
        self.started_at = None
        try:
            self.save()
        except (Rejected, OSError):
            self.record["phase"] = "stop_unconfirmed"
        result = self.summary()
        if self.record["phase"] == "stopped" and sync_auth:
            source = no_links(self.root / "codex" / self.record["cycle"] / "auth.json")
            if source.exists():
                require(private_file(source).stat().st_size <= 65536, "codex_auth_too_large")
                raw = private_file(source).read_bytes()
                require(0 < len(raw) <= 65536, "codex_auth_too_large")
                atomic(private_dir(self.root / "auth", create=True) / "auth.json", raw)
            self.record["auth_sync_pending"] = False
            self.save()
        if self.record["phase"] == "stopped" and self.record.get("purpose") == "login":
            receipt = private_dir(self.root / "login-receipts", create=True) / (self.record["generation"] + ".json")
            atomic(receipt, canonical({key: result[key] for key in ("phase", "generation", "interval")}))
            import shutil
            require(shutil.rmtree.avoids_symlink_attacks, "safe_tree_removal_required")
            for kind in ("keys", "workspaces", "codex"):
                path = no_links(self.root / kind / identifier(self.record["generation"]))
                if path.exists():
                    shutil.rmtree(private_dir(path))
            self.record = self.record.get("previous")
            self.save()
        return result

    def export(self, request):
        self.bound(request, ("sha",))
        sha(request["sha"])
        require(self.record["phase"] in ("stopped", "exported"), "confirmed_stop_required")
        record = self.record
        target = self.path("exports", record["generation"])
        if record["export"]:
            require(record["export"]["sha"] == request["sha"], "export_sha_changed")
            file = private_file(target / "candidate.bundle")
            require(file.stat().st_size <= MAX_BUNDLE, "export_size_invalid")
            raw = file.read_bytes()
            require(digest(raw) == record["export"]["sha256"], "export_digest_changed")
            return record["export"], raw
        name = "symphony-export-" + record["generation"]
        work = self.path("workspaces", record["cycle"])
        record["phase"] = "exporting"
        self.save()
        try:
            candidate = no_links(target / "candidate.bundle")
            if candidate.exists():
                require(candidate.is_file() and candidate.stat().st_nlink == 1, "unsafe_partial_export")
                candidate.unlink()  # Only an unfinished export of this generation, never a published receipt.
            try:
                self.pod(*self.base_args(name), "--volume", f"{work}:/workspace:ro", "--volume", f"{target}:/output:rw",
                         "--entrypoint=/usr/bin/python3", self.image, "-I", "/opt/symphony/git_transfer.py", "export",
                         request["sha"], record["branch"], timeout=60)
            finally:
                self.pod("rm", "--force", "--ignore", name)
            payload = Path("/sys/fs/cgroup") / self.cgroup.lstrip("/") / "payload"
            require(not payload.exists() or not any(p.read_text().strip() for p in payload.rglob("cgroup.procs")), "export_processes_remain")
        except (Rejected, OSError):
            self.stop("worker_export_failed")
            raise
        file = no_links(target / "candidate.bundle")
        require(file.is_file() and file.stat().st_nlink == 1 and file.stat().st_size <= MAX_BUNDLE, "export_size_invalid")
        file.chmod(0o600)
        raw = private_file(file).read_bytes()
        require(0 < len(raw) <= MAX_BUNDLE, "export_size_invalid")
        record["export"] = {"sha": request["sha"], "size": len(raw), "sha256": digest(raw),
                            **{key: record[key] for key in ("cycle", "branch", "interval", "generation")}}
        record["phase"] = "exported"
        self.save()
        return record["export"], raw

    def summary(self):
        try:
            self.ready()
            ready = True
        except (Rejected, OSError):
            ready = False
        auth = self.root / "auth/auth.json"
        source = auth if auth.exists() or auth.is_symlink() else self.root / "codex-auth.json"
        try:
            auth_present = 0 < private_file(source).stat().st_size <= 65536
        except (Rejected, OSError):
            auth_present = False
        metadata = {"image": self.image, "network_ready": ready, "auth_present": auth_present,
                    "free_bytes": capacity(self.root)["free_bytes"], **getattr(self, "image_profile", {})}
        if self.record is None:
            return {"phase": "idle", **metadata}
        record = self.record
        result = {key: record[key] for key in ("phase", "cycle", "branch", "repo", "interval", "generation", "reason")}
        if record.get("port"):
            result["port"] = record["port"]
        host_public = no_links(self.root / "keys" / record["generation"] / "host_key.pub")
        if host_public.exists():
            result["host_public_key"] = " ".join(host_public.read_text().split()[:2])
        return {**result, **metadata}

    def tick(self):
        with self.mutex:
            if self.record and self.record["phase"] == "running":
                try:
                    self.ready()
                except (Rejected, OSError):
                    self.stop("network_policy_lost")
                    return
                if self.started_at is None or self.clock() - self.heartbeat_at >= 45 or self.clock() - self.started_at >= self.record["active_seconds"]:
                    self.stop("lease_or_deadline_expired")
            elif self.clock() >= getattr(self, "next_collection", float("inf")):
                self.next_collection = self.clock() + 3600
                try:
                    collect(self.root, retention_days=self.retention_days, dry_run=False, categories=("workspaces", "codex", "keys", "seeds", "exports"))
                    collect_images(self.root, self.image, self.pod, self.retention_days, dry_run=False)
                except (Rejected, OSError, ValueError):
                    from .storage import bounded_log
                    bounded_log(self.root / "maintenance.log", b"cleanup requires operator inspection\n")

    def dispatch(self, request, body=b""):
        with self.mutex:
            action = request.get("action")
            if action == "prepare":
                return self.prepare(request, body), b""
            if action == "status":
                require(set(request) == {"action"}, "invalid_status_request")
                return self.summary(), b""
            if action == "retire":
                require(set(request) == {"action", "cycle", "report", "retention_days"}, "invalid_retirement_request")
                cycle = identifier(request["cycle"])
                require(not self.record or self.record["phase"] in ("stopped", "exported"), "confirmed_stop_required")
                report = request["report"]
                generations = report.get("generations")
                require(isinstance(generations, list) and len(generations) <= 1000, "invalid_generation_list")
                if self.record and self.record["cycle"] == cycle:
                    require(self.record["generation"] in generations, "retirement_generation_missing")
                for generation in generations:
                    receipt = self.root / "keys" / identifier(generation) / "binding.json"
                    if receipt.exists():
                        bound = read_json(private_file(receipt))
                        require(bound["cycle"] == cycle and bound["generation"] == generation, "retirement_owner_mismatch")
                    else:
                        existing = read_json(private_file(self.root / "reports" / (cycle + ".json")))
                        require(generation in existing["report"]["generations"], "retirement_owner_unknown")
                retire(self.root, cycle, report, retention_days=request["retention_days"])
                removed = collect(self.root, retention_days=request["retention_days"], dry_run=False,
                                  categories=("workspaces", "codex", "keys", "seeds", "exports"))
                return {"retired": cycle, "removed": removed}, b""
            if action == "collect":
                require(set(request) == {"action", "retention_days", "dry_run"} and type(request["dry_run"]) is bool, "invalid_cleanup_request")
                active = self.record["cycle"] if self.record and self.record["phase"] not in ("stopped", "exported") else None
                removed = collect(self.root, active_cycle=active, retention_days=request["retention_days"], dry_run=request["dry_run"], categories=("workspaces", "codex", "keys", "seeds", "exports"))
                images = collect_images(self.root, self.image, self.pod, request["retention_days"], dry_run=request["dry_run"])
                self.retention_days = request["retention_days"]
                return {"removed": removed, "images": images}, b""
            if action == "login_prepare":
                return self.login_prepare(request), b""
            if action == "start":
                return self.start(request), b""
            if action == "export":
                return self.export(request)
            if action == "stop" and isinstance(request.get("generation"), str) and request["generation"].startswith("login-"):
                receipt = self.root / "login-receipts" / (identifier(request["generation"]) + ".json")
                if receipt.exists():
                    require(set(request) == {"action", "generation", "interval"} and request["interval"] == request["generation"], "invalid_login_stop")
                    return read_json(private_file(receipt)), b""
            self.bound(request)
            if action == "heartbeat":
                require(self.record["phase"] == "running", "worker_not_running")
                self.heartbeat_at = self.clock()
                return self.summary(), b""
            require(action == "stop", "unknown_operation")
            return self.stop("controller_requested"), b""

    def login_prepare(self, request):
        require(set(request) == {"action", "generation", "ssh_public_key"}, "invalid_login_request")
        generation = identifier(request["generation"])
        require(generation.startswith("login-"), "login_generation_required")
        require(not self.record or self.record["phase"] in ("stopped", "exported"), "confirmed_stop_required")
        keys = self.path("keys", generation)
        require(not (keys / "host_key").exists(), "login_generation_reused")
        atomic(keys / "authorized_keys", public_key(request["ssh_public_key"]).encode())
        command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(keys / "host_key")])
        self.record = {"phase": "prepared", "purpose": "login", "previous": self.record,
                       "cycle": generation, "interval": generation, "generation": generation, "repo": None,
                       "branch": None, "container": "symphony-job-" + generation, "reason": None, "cgroup": None}
        self.save()
        return self.summary()


def serve(guardian, stop_event=None):
    stop_event = stop_event or threading.Event()
    socket_path = guardian.root / "control.sock"
    # The flock is held before stale socket removal; another guardian cannot be displaced.
    with locked(guardian.root / "guardian.lock"):
        if guardian.record and guardian.record["phase"] not in ("stopped", "exported"):
            guardian.stop("guardian_restarted")
        if socket_path.exists():
            require(socket_path.is_socket(), "unexpected_control_path")
            socket_path.unlink()
        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                self.connection.settimeout(15)
                try:
                    request = header(self.rfile)
                    size = request.get("bundle_size", 0)
                    require(type(size) is int and 0 <= size <= MAX_BUNDLE, "invalid_body_size")
                    value, body = guardian.dispatch(request, receive(self.rfile, size))
                    send_header(self.wfile, {"ok": value, "body_size": len(body)})
                    send_bytes(self.wfile, body)
                except (Rejected, OSError, ValueError) as exc:
                    reason = str(exc) if isinstance(exc, Rejected) else "guardian_io_error"
                    send_header(self.wfile, {"error": reason, "body_size": 0})
        class Server(socketserver.ThreadingUnixStreamServer):
            slots = threading.BoundedSemaphore(4)

            def process_request(self, request, address):
                if not self.slots.acquire(blocking=False):
                    request.close()
                    return
                super().process_request(request, address)

            def process_request_thread(self, request, address):
                try:
                    super().process_request_thread(request, address)
                finally:
                    self.slots.release()

        with Server(str(socket_path), Handler) as server:
            socket_path.chmod(0o600)
            server.daemon_threads = True
            server.timeout = 0.5
            try:
                while not stop_event.is_set():
                    guardian.tick()
                    server.handle_request()
            finally:
                with guardian.mutex:
                    guardian.stop("guardian_shutdown")
                socket_path.unlink(missing_ok=True)
