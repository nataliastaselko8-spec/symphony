"""Opt-in real WSL/rootless-Podman acceptance; temporary fake Git task, no model or GitHub calls."""
import argparse
import io
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.common import digest, require
from symphony_runtime.guardian import header, receive, send_bytes, send_header
from symphony_runtime.host import HostSession


def command(args, **kw):
    try:
        return subprocess.check_output(args, stderr=subprocess.STDOUT, timeout=75, **kw).decode().strip()
    except subprocess.CalledProcessError as error:
        print(error.output.decode(errors="replace")[:16384], flush=True)
        raise


def rpc(root, request, body=b""):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(85)
        connection.connect(str(root / "control.sock"))
        stream = connection.makefile("rwb", buffering=0)
        send_header(stream, request)
        send_bytes(stream, body)
        result = header(stream)
        require("error" not in result, str(result))
        return result["ok"], receive(stream, result["body_size"])


def expect_error(root, request, reason):
    try:
        rpc(root, request)
    except Exception as error:
        require(reason in str(error), "wrong_rejection_" + str(error))
        return
    raise RuntimeError("expected_rejection_" + reason)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--windows-canary", help="Valid Windows cmd.exe copied as test input, never a host mount")
    args = parser.parse_args()
    require(os.geteuid() == 0, "smoke_requires_explicit_root_setup")
    require(args.windows_canary or "microsoft" not in os.uname().release.lower(), "windows_canary_required_for_wsl_smoke")
    account = pwd.getpwnam(args.worker)
    suffix = uuid.uuid4().hex[:12]
    root = Path(tempfile.mkdtemp(prefix="smoke-данные ", dir=account.pw_dir))
    os.chown(root, account.pw_uid, account.pw_gid)
    # Host canaries are readable by the worker host account, but must never be mounted into a task.
    sentinel = root / "host-secret.txt"
    sentinel.write_text("HOST_PRIVATE_CANARY")
    sentinel.chmod(0o644)
    with tempfile.TemporaryDirectory(prefix="symphony-controller-") as temporary:
        control = Path(temporary)
        source = control / "source"
        source.mkdir()
        command(["git", "init", "-b", "dev", str(source)])
        (source / "readme.txt").write_text("fixture base\n")
        if args.windows_canary:
            canary = Path(args.windows_canary)
            require(canary.is_file() and not canary.is_symlink() and 64 <= canary.stat().st_size <= 2 * 1024**2,
                    "invalid_windows_canary")
            raw_canary = canary.read_bytes()
            offset = int.from_bytes(raw_canary[60:64], 'little')
            require(raw_canary[:2] == b'MZ' and raw_canary[offset:offset+4] == b'PE\0\0', "valid_pe_canary_required")
            (source / "windows-canary.exe").write_bytes(raw_canary)
            (source / "windows-canary.exe").chmod(0o755)
        command(["git", "-C", str(source), "add", "."])
        command(["git", "-C", str(source), "-c", "user.name=Runtime Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture"])
        base = command(["git", "-C", str(source), "rev-parse", "HEAD"])
        bundle = control / "seed.bundle"
        command(["git", "-C", str(source), "bundle", "create", str(bundle), "refs/heads/dev"])
        raw = bundle.read_bytes()
        client_key = control / "key"
        command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(client_key)])
        public = " ".join(client_key.with_suffix(".pub").read_text().split()[:2])
        request = dict(action="prepare", cycle="fixture", interval="first", generation="g" + suffix,
                       repo="example/project", branch="agent/fixture", base_sha=base,
                       bundle_size=len(raw), bundle_sha256=digest(raw), ssh_public_key=public)
        stop_event = threading.Event()
        failures = []
        host = None
        try:
            with HostSession(args.package, args.worker, args.image, root, "smoke-" + suffix) as host:
                def maintain():
                    while not stop_event.wait(2):
                        try:
                            host.refresh()
                        except Exception as error:
                            failures.append(str(error))
                            return
                keeper = threading.Thread(target=maintain, daemon=True)
                keeper.start()
                try:
                    with socket.socket(socket.AF_INET6) as canary:
                        canary.bind(("::1", 0))
                        canary.listen(3)
                        port6 = canary.getsockname()[1]
                        with socket.create_connection(("::1", port6), timeout=2):
                            pass
                        script6 = "import os,pathlib,socket\npathlib.Path(%r).write_text(str(os.getpid()))\ntry:\n socket.create_connection(('::1',%d),timeout=2)\nexcept OSError:\n print('IPV6_CGROUP_BLOCKED')\nelse:\n raise SystemExit(1)\n" % ("/sys/fs/cgroup/" + host.group + "/supervisor/cgroup.procs", port6)
                        require(command([sys.executable, "-I", "-c", script6]) == "IPV6_CGROUP_BLOCKED", "ipv6_scope_failed")
                        print("IPV6_CGROUP_CANARY_PASS; OUTSIDE_CANARY_CONNECTED", flush=True)
                    prepared, _ = rpc(root, request, raw)
                    require(prepared["phase"] == "prepared", "prepare_failed")
                    again, _ = rpc(root, request, raw)
                    require({k: v for k, v in again.items() if k != "free_bytes"} == {k: v for k, v in prepared.items() if k != "free_bytes"}, "prepare_not_idempotent")
                    bound = dict(interval=request["interval"], generation=request["generation"])
                    running, _ = rpc(root, dict(action="start", active_seconds=120, **bound))
                    known = control / "known_hosts"
                    known.write_text(f"[127.0.0.1]:{running['port']} {running['host_public_key']}\n")
                    ssh = ["ssh", "-F", "/dev/null", "-T", "-p", str(running["port"]), "-i", str(client_key),
                           "-oBatchMode=yes", "-oIdentitiesOnly=yes", "-oStrictHostKeyChecking=yes",
                           "-oConnectTimeout=3", "-oUserKnownHostsFile=" + str(known), "worker@127.0.0.1"]
                    for _ in range(20):
                        try:
                            command([*ssh, "true"])
                            break
                        except subprocess.CalledProcessError:
                            time.sleep(0.1)
                    paths = [str(sentinel), str(control / "key"), account.pw_dir, "/mnt/c", "/mnt/d", "/mnt/wsl", "/mnt/wslg",
                             "/run/WSL", "/usr/lib/wsl", "/var/run/docker.sock", f"/run/user/{account.pw_uid}/podman/podman.sock"]
                    # Feed inert Python through SSH stdin; no interpolated shell statements or credentials.
                    script = """import errno, os, pathlib, json, resource, signal, subprocess, socket
paths = json.loads(%r)
for target in paths:
    path = pathlib.Path(target)
    assert not path.exists() and not path.is_symlink(), ('visible_host_path', target)
    for action in (lambda: path.read_bytes(), lambda: list(path.iterdir()), lambda: path.write_text('forbidden')):
        try: action()
        except OSError: pass
        else: raise AssertionError(('host_access', target))
link = pathlib.Path('/workspace/escape')
link.symlink_to(paths[0])
try: link.read_bytes()
except OSError: pass
else: raise AssertionError('symlink_escape')
link.unlink()
try: pathlib.Path('/etc/host-modification').write_text('bad')
except OSError: pass
else: raise AssertionError('root_write')
status = pathlib.Path('/proc/self/status').read_text()
assert 'CapEff:\\t0000000000000000' in status
assert 'NoNewPrivs:\\t1' in status and 'Seccomp:\\t2' in status
assert os.getuid() == 10001
assert os.environ['CODEX_HOME'] == '/codex'
assert not os.environ.get('WSL_INTEROP')
try: socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
except OSError as error: assert error.errno in (errno.EPERM, errno.EACCES, errno.EAFNOSUPPORT, errno.ENOSYS), ('vsock_error', error.errno)
else: raise AssertionError('host_vsock_accessible')
print('HOST_VSOCK_BLOCKED')
for family in (socket.AF_UNIX, socket.AF_INET, socket.AF_INET6):
    with socket.socket(family, socket.SOCK_STREAM): pass
# A minimal static ELF32 exits successfully without the compatibility ABI guard.
import struct
code32 = bytes.fromhex('b801000000bb00000000cd80')
ident = b'\\x7fELF\\x01\\x01\\x01' + bytes(9)
elf32 = struct.pack('<16sHHIIIIIHHHHHH', ident, 2, 3, 1, 0x8048000+84, 52, 0, 0, 52, 32, 1, 0, 0, 0)
elf32 += struct.pack('<IIIIIIII', 1, 0, 0x8048000, 0x8048000, 84+len(code32), 84+len(code32), 5, 4096) + code32
compat = pathlib.Path('/workspace/compat-probe')
compat.write_bytes(elf32)
compat.chmod(0o755)
try:
    try: result32 = subprocess.run([str(compat)], capture_output=True, timeout=5)
    except OSError as error: assert error.errno in (errno.ENOEXEC, errno.ENOENT, errno.EACCES, errno.EPERM)
    else: assert result32.returncode in (-signal.SIGSYS, -signal.SIGKILL), ('compat_abi_allowed', result32.returncode)
finally: compat.unlink()
print('COMPAT_ABI_BLOCKED')
canary = pathlib.Path('/workspace/repo/windows-canary.exe')
if canary.exists():
    try:
        result = subprocess.run([str(canary), '/d', '/c', 'echo SYMPHONY_INTEROP_CANARY'],
                                capture_output=True, timeout=15)
    except OSError as error:
        assert error.errno in (errno.ENOEXEC, errno.ENOENT, errno.EACCES, errno.EPERM), ('canary_error', error.errno)
    else:
        assert result.returncode != 0 and b'SYMPHONY_INTEROP_CANARY' not in result.stdout, 'windows_execution_possible'
    print('WINDOWS_EXECUTION_BLOCKED')
assert resource.getrlimit(resource.RLIMIT_FSIZE) == (268435456, 268435456)
cgroup = pathlib.Path('/sys/fs/cgroup')
assert (cgroup / 'cpu.max').read_text().strip() == '200000 100000', 'cpu_limit_missing'
assert (cgroup / 'memory.max').read_text().strip() == '2147483648', 'memory_limit_missing'
assert (cgroup / 'pids.max').read_text().strip() == '512', 'pids_limit_missing'
print('CPU_MEMORY_PIDS_LIMITS_PASS')
probe = pathlib.Path('/workspace/fsize-probe')
previous_signal = signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
try:
    with probe.open('xb') as output:
        # Sparse data verifies the actual kernel boundary without allocating 256 MiB.
        output.seek(151356535)
        output.write(b'x')
        output.flush()
        assert probe.stat().st_size == 151356536
        try: os.ftruncate(output.fileno(), 268435457)
        except OSError as error: assert error.errno == errno.EFBIG
        else: raise AssertionError('file_limit_not_enforced')
finally:
    probe.unlink(missing_ok=True)
    signal.signal(signal.SIGXFSZ, previous_signal)
print('FILE_SIZE_LIMIT_256_MIB_PASS')
subprocess.run(['codex', '--version'], check=True)
subprocess.run(['python3.11', '--version'], check=True)
subprocess.run(['uv', '--version'], check=True)
import select
server = subprocess.Popen(['codex', 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
try:
    message = {'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'runtime-smoke', 'version': '1.0'}}}
    server.stdin.write((json.dumps(message) + '\\n').encode())
    server.stdin.flush()
    assert select.select([server.stdout], [], [], 10)[0], 'app_server_initialize_timeout'
    response = json.loads(server.stdout.readline())
    assert response.get('id') == 1 and 'result' in response, 'app_server_initialize_failed'
    print('CODEX_APP_SERVER_INITIALIZE_PASS')
finally:
    server.terminate()
    server.wait(timeout=5)
print('FILESYSTEM_BOUNDARY_PASS')
""" % json.dumps(paths)
                    print(command([*ssh, "python3 -I -"], input=script.encode()), flush=True)
                    # Outside canary succeeds; the same destination from actual pasta must be rejected.
                    address = next(a for a in host.addresses if "." in a and not a.startswith("127."))
                    with socket.socket() as listener:
                        listener.bind((address, 0))
                        listener.listen(5)
                        port = listener.getsockname()[1]
                        with socket.create_connection((address, port), timeout=2):
                            pass
                        network = "import socket\ntry:\n s=socket.create_connection((%r,%d),timeout=3)\nexcept OSError:\n print('PRIVATE_NETWORK_BLOCKED')\nelse:\n raise SystemExit('PRIVATE_NETWORK_ALLOWED')\n" % (address, port)
                        result = command([*ssh, "python3 -I -"], input=network.encode())
                        require(result == "PRIVATE_NETWORK_BLOCKED", result)
                        # Check kernel rule counters, not a missing route/DNS failure.
                        rules = command(["iptables-nft", "-v", "-x", "-n", "-L", host.firewall.chain])
                        require(any(line.split()[0].isdigit() and int(line.split()[0]) > 0 and "REJECT" in line for line in rules.splitlines()), "no_firewall_rejection_evidence")
                        print("PASTA_PRIVATE_NETWORK_PASS; OUTSIDE_CANARY_CONNECTED", flush=True)
                    print(command([*ssh, "curl --fail --silent --show-error --retry 2 --retry-all-errors --max-time 15 --output /dev/null https://registry.npmjs.org/ && printf PUBLIC_HTTPS_PASS"]), flush=True)
                    # Management endpoint accepts framed status and ignores arbitrary SSH command requests.
                    with socket.socket() as reserve:
                        reserve.bind(("127.0.0.1", 0))
                        management_port = reserve.getsockname()[1]
                    management_key = host.management_ssh(management_port, public)
                    management_known = control / "management_known"
                    management_known.write_text(f"[127.0.0.1]:{management_port} {management_key}\n")
                    wire = io.BytesIO()
                    send_header(wire, {"action": "status"})
                    manage = ["ssh", "-F", "/dev/null", "-T", "-p", str(management_port), "-i", str(client_key), "-oBatchMode=yes",
                              "-oStrictHostKeyChecking=yes", "-oUserKnownHostsFile=" + str(management_known), args.worker + "@127.0.0.1", "touch /tmp/never-execute"]
                    response = subprocess.check_output(manage, input=wire.getvalue(), timeout=10)
                    require(header(io.BytesIO(response))["ok"]["phase"] == "running", "management_frame_failed")
                    require(not Path("/tmp/never-execute").exists(), "management_shell_executed")
                    print("MANAGEMENT_FORCED_COMMAND_PASS", flush=True)
                    rpc(root, dict(action="heartbeat", **bound))
                    expect_error(root, dict(action="stop", interval="wrong", generation=bound["generation"]), "stale_worker_handle")
                    expect_error(root, dict(action="export", sha=base, **bound), "confirmed_stop_required")
                    code = "cd /workspace/repo && git switch -c agent/fixture && printf 'changed\\n' > readme.txt && git add readme.txt && git -c user.name=Test -c user.email=test@example.invalid commit -m changed && git rev-parse HEAD"
                    candidate = command([*ssh, code]).splitlines()[-1]
                    command([*ssh, "sh -c 'nohup sleep 240 >/tmp/child.log 2>&1 </dev/null &'"])
                    stopped, _ = rpc(root, dict(action="stop", **bound))
                    require(stopped["phase"] == "stopped", str(stopped))
                    require(rpc(root, dict(action="stop", **bound))[0]["phase"] == "stopped", "stop_not_idempotent")
                    proof, data = rpc(root, dict(action="export", sha=candidate, **bound))
                    require(proof["sha256"] == digest(data), "export_corrupt")
                    (control / "candidate.bundle").write_bytes(data)
                    require(command(["git", "bundle", "list-heads", str(control / "candidate.bundle")]) == candidate + " refs/heads/agent/fixture", "wrong_export_ref")
                    require(rpc(root, dict(action="export", sha=candidate, **bound))[1] == data, "export_not_idempotent")
                    # Exercise the real controller bridge over its pinned management SSH channel.
                    ssh_config = control / "ssh_config"
                    ssh_config.write_text(f'Host fixture\n HostName 127.0.0.1\n Port {management_port}\n User {args.worker}\n IdentityFile "{client_key}"\n UserKnownHostsFile "{management_known}"\n')
                    ssh_config.chmod(0o600)
                    export_dir = control / "exports"
                    export_dir.mkdir(mode=0o700)
                    transport_config = control / "transport.json"
                    transport_config.write_text(json.dumps({"ssh_config": str(ssh_config), "destination": "fixture", "export_directory": str(export_dir),
                        "cycle": "fixture", "branch": "agent/fixture", **bound}))
                    transport_config.chmod(0o600)
                    frame = io.BytesIO()
                    send_header(frame, dict(action="export", sha=candidate, **bound))
                    result = subprocess.check_output([sys.executable, "-I", "-B", str(Path(args.package) / "scripts/controller-transport.py"), "--config", str(transport_config)], input=frame.getvalue(), timeout=20)
                    exported = Path(header(io.BytesIO(result))["ok"]["path"])
                    require(exported.read_bytes() == data and exported.stat().st_mode & 0o077 == 0, "controller_export_failed")
                    print("STOP_DESCENDANTS_EXPORT_PASS", flush=True)
                    # Bootstrap has an empty workspace and preserves the prior export binding.
                    login_id = "login-" + suffix
                    rpc(root, {"action": "login_prepare", "generation": login_id, "ssh_public_key": public})
                    login_bound = dict(interval=login_id, generation=login_id)
                    login_proof, _ = rpc(root, dict(action="start", active_seconds=60, **login_bound))
                    login_known = control / "login_known"
                    login_known.write_text(f"[127.0.0.1]:{login_proof['port']} {login_proof['host_public_key']}\n")
                    login_ssh = ["ssh", "-F", "/dev/null", "-T", "-p", str(login_proof["port"]), "-i", str(client_key),
                                 "-oBatchMode=yes", "-oIdentitiesOnly=yes", "-oStrictHostKeyChecking=yes",
                                 "-oUserKnownHostsFile=" + str(login_known), "worker@127.0.0.1"]
                    for attempt in range(20):
                        try:
                            command([*login_ssh, "test ! -e /workspace/repo && codex login --help >/dev/null"])
                            break
                        except subprocess.CalledProcessError:
                            if attempt == 19:
                                raise
                            time.sleep(0.2)
                    command([*login_ssh, "umask 077; printf '{}' > /codex/auth.json"])
                    rpc(root, dict(action="stop", **login_bound))
                    restored, _ = rpc(root, {"action": "status"})
                    require(restored["generation"] == bound["generation"], "login_lost_task_binding")
                    require(not (root / "keys" / login_id).exists(), "bootstrap_keys_remain")
                    require((root / "auth/auth.json").read_text() == "{}", "bootstrap_auth_not_saved")
                    require(rpc(root, dict(action="export", sha=candidate, **bound))[1] == data, "login_changed_export")
                    print("ISOLATED_LOGIN_AND_RESTORED_BINDING_PASS", flush=True)
                    # Reuse the same task workspace after acknowledged stop; preserve committed result.
                    request.update(interval="second", generation="h" + suffix)
                    rpc(root, request, raw)
                    bound = dict(interval=request["interval"], generation=request["generation"])
                    rpc(root, dict(action="start", active_seconds=2, **bound))
                    deadline = time.monotonic() + 25
                    while time.monotonic() < deadline:
                        current, _ = rpc(root, {"action": "status"})
                        if current["phase"] == "stopped":
                            break
                        time.sleep(0.3)
                    require(current["phase"] == "stopped" and current["reason"] == "lease_or_deadline_expired", "deadline_stop_failed")
                    require(not failures, str(failures))
                    print("DEADLINE_STOP_PASS", flush=True)
                    # Losing the controller means no heartbeat; a new connection must not restart it.
                    request.update(interval="third", generation="j" + suffix)
                    rpc(root, request, raw)
                    bound = dict(interval=request["interval"], generation=request["generation"])
                    rpc(root, dict(action="start", active_seconds=120, **bound))
                    lost_at = time.monotonic()
                    while time.monotonic() - lost_at < 65:
                        current, _ = rpc(root, {"action": "status"})
                        if current["phase"] == "stopped":
                            break
                        time.sleep(0.5)
                    require(current["phase"] == "stopped", "heartbeat_loss_not_stopped")
                    print("CONTROLLER_LOSS_STOP_SECONDS=" + str(round(time.monotonic() - lost_at, 2)), flush=True)
                    # An unexpected guardian death must kill the container through the systemd unit.
                    request.update(interval="fourth", generation="k" + suffix)
                    rpc(root, request, raw)
                    bound = dict(interval=request["interval"], generation=request["generation"])
                    rpc(root, dict(action="start", active_seconds=120, **bound))
                    command(["systemctl", "kill", "--kill-whom=main", "--signal=KILL", host.unit])
                    stop_event.set()
                    keeper.join(timeout=5)
                    group = Path("/sys/fs/cgroup") / host.group
                    deadline = time.monotonic() + 15
                    while group.exists() and time.monotonic() < deadline:
                        time.sleep(0.2)
                    require(not group.exists(), "guardian_crash_left_processes")
                    print("GUARDIAN_CRASH_STOP_PASS", flush=True)
                finally:
                    stop_event.set()
                    keeper.join(timeout=5)
            with HostSession(args.package, args.worker, args.image, root, "smoke-" + suffix):
                current, _ = rpc(root, {"action": "status"})
                require(current["phase"] == "stopped", "restart_resumed_unreconciled_work")
                require((root / "workspaces/fixture/repo/readme.txt").read_text() == "changed\n", "restart_lost_workspace")
                expect_error(root, dict(action="stop", interval="first", generation="g" + suffix), "stale_worker_handle")
                print("GUARDIAN_RESTART_PRESERVES_WORK_AND_STOPS_PASS", flush=True)
            print("SCOPED_FIREWALL_REMOVED; SUMMARY PASS", flush=True)
        finally:
            if (root / "last-command-error.log").exists():
                print((root / "last-command-error.log").read_text()[:16384], flush=True)
            # This exact mkdtemp path under the explicitly named worker home is the only deletion target.
            require(root.parent == Path(account.pw_dir) and root.name.startswith("smoke-"), "cleanup_path_mismatch")
            group = Path("/sys/fs/cgroup") / host.group if host is not None and host.group is not None else None
            if group is not None and not group.exists():
                shutil.rmtree(root)
            else:
                print("STOP_UNCONFIRMED_PRESERVING_WORKSPACE=" + str(root), flush=True)


if __name__ == "__main__":
    main()
