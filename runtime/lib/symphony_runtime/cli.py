"""Finite inspection launcher. Runtime execution cannot be enabled by editing JSON."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

from . import config as settings
from .common import Rejected, atomic, canonical, command, digest, locked, no_links, private_dir, private_file, read_json, require


def preflight(config):
    checks = []
    def check(name, action):
        try:
            action()
            checks.append({"check": name, "status": "PASS"})
        except (Rejected, OSError, ValueError) as error:
            checks.append({"check": name, "status": "NOT_READY", "reason": str(error) if isinstance(error, Rejected) else "missing_or_unreadable_resource"})
    check("linux", lambda: require(sys.platform == "linux", "linux_required"))
    for tool in ("git", "ssh", "python3", "prlimit"):
        check(tool, lambda tool=tool: require(shutil.which(tool), "missing_tool"))
    check("private_state_directory", lambda: private_dir(config["state_root"]))
    check("workflow_and_manifest", lambda: settings.validate_manifest(config))
    check("symphony_pin", lambda: verify_source(config))
    check("symphony_executable", lambda: require(os.access(Path(config["symphony_root"]) / "elixir/bin/symphony", os.X_OK), "build_required"))
    for field in ("ssh_config", "app_key", "operator_credential"):
        if config[field]:
            check(field + "_permissions", lambda field=field: private_file(config[field]))
    checks.append({"check": "live_execution", "status": "BLOCKED", "reason": "PR13_integration_required"})
    checks.append({"check": "worker_acceptance", "status": "NOT_EVALUATED", "reason": "run_explicit_runtime_smoke"})
    return {"schema_version": 1, "profile": config["profile"], "role": config["role"], "execution_enabled": False,
            "inspection_ready": all(row["status"] == "PASS" for row in checks[:-2]), "checks": checks}


def verify_source(config):
    manifest = settings.validate_manifest(config)
    root = no_links(config["symphony_root"])
    require(command(["git", "rev-parse", "HEAD"], cwd=root).decode().strip() == manifest["symphony_commit"], "symphony_pin_mismatch")
    require(not command(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=root).strip(), "symphony_checkout_dirty")
    require(config["project_template"], "project_template_required")
    profile = Path(config["project_template"]).parent
    require(command(["git", "rev-parse", "HEAD"], cwd=profile).decode().strip() == manifest["profile_revision"], "profile_pin_mismatch")
    require(not command(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=profile).strip(), "profile_checkout_dirty")


def launch(config, delivery=False):
    require(sys.platform == "linux", "linux_required")
    require(preflight(config)["inspection_ready"], "inspection_preflight_failed")
    state = private_dir(config["state_root"])
    with locked(state / "launcher.lock"):
        # The fixed CLI entry point owns its temporary read credential cache.
        executable = Path(config["symphony_root"]) / "elixir/bin/symphony"
        require(not delivery, "use_documented_delivery_inspection_command")
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(Path.home()), "LANG": "C.UTF-8"}
        if config["ssh_config"]:
            env["SYMPHONY_SSH_CONFIG"] = config["ssh_config"]
        if config["app_key"]:
            env["SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH"] = config["app_key"]
        proc = None
        stop = threading.Event()
        token = uuid.uuid4().hex
        endpoint = state / "launcher.sock"
        if endpoint.exists():
            require(endpoint.is_socket(), "unexpected_launcher_path")
            endpoint.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(endpoint))
        endpoint.chmod(0o600)
        server.listen(4)
        server.settimeout(0.2)
        record = {"pid": os.getpid(), "start": Path("/proc/self/stat").read_text().split(") ", 1)[1].split()[19], "mode": "inspection", "token": token}
        atomic(state / "launcher.json", canonical(record))
        previous = signal.signal(signal.SIGTERM, lambda *_: stop.set())
        try:
            proc = subprocess.Popen([str(executable), "--dry-run", config["workflow"]],
                                    cwd=executable.parent.parent, env=env, stdin=subprocess.DEVNULL, start_new_session=True)
            while proc.poll() is None and not stop.is_set():
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(1)
                        value = connection.recv(128)
                        if value in (("STOP " + token).encode(), ("PING " + token).encode()):
                            connection.sendall(b"OK")
                            if value.startswith(b"STOP "):
                                stop.set()
                except (TimeoutError, BrokenPipeError):
                    pass
        except KeyboardInterrupt:
            stop.set()
        finally:
            signal.signal(signal.SIGTERM, previous)
            if proc is not None and proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            server.close()
            endpoint.unlink(missing_ok=True)
            (state / "launcher.json").unlink(missing_ok=True)
        return proc.returncode


def status(config):
    path = private_dir(config["state_root"]) / "launcher.json"
    if not path.exists():
        return {"running": False, "execution_enabled": False}
    record = read_json(private_file(path))
    require(set(record) == {"pid", "start", "mode", "token"} and type(record["pid"]) is int and record["pid"] > 1 and record["mode"] == "inspection", "invalid_launcher_record")
    try:
        process = Path(f"/proc/{record['pid']}")
        current = process.joinpath("stat").read_text().split(") ", 1)[1].split()[19]
        active = current == record["start"] and process.stat().st_uid == os.getuid()
    except (FileNotFoundError, ProcessLookupError):
        active = False
    return {"running": active, "execution_enabled": False, "mode": record["mode"], "pid": record["pid"]}


def stop_inspection(config):
    state = private_dir(config["state_root"])
    if not status(config)["running"]:
        return {"stopped": True, "workspace_preserved": True}
    record = read_json(private_file(state / "launcher.json"))
    endpoint = no_links(state / "launcher.sock")
    require(endpoint.is_socket() and endpoint.stat().st_uid == os.getuid(), "launcher_control_unavailable")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect(str(endpoint))
        connection.sendall(("STOP " + record["token"]).encode())
        require(connection.recv(16) == b"OK", "stop_not_acknowledged")
    deadline = time.monotonic() + 15
    while status(config)["running"] and time.monotonic() < deadline:
        time.sleep(0.1)
    require(not status(config)["running"], "stop_unconfirmed")
    return {"stopped": True, "workspace_preserved": True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("configure", "render", "pin", "preflight", "launch", "status", "stop"))
    parser.add_argument("--config", default=str(settings.default_config_path()))
    parser.add_argument("--from-json", help="Explicit machine parameters; no shell expressions")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--symphony-commit")
    parser.add_argument("--profile-revision")
    parser.add_argument("--worker-image")
    args = parser.parse_args(argv)
    try:
        require(not args.execute, "PR13_execution_integration_required")
        if args.action == "configure":
            values = read_json(args.from_json) if args.from_json else {}
            value = settings.configure(args.config, values)
            print(json.dumps({"configured": True, "profile": value["profile"], "execution_enabled": False}))
            return 0
        require(args.from_json is None, "from_json_only_for_configure")
        config = settings.load(args.config)
        if args.action == "render":
            print(json.dumps({"workflow_sha256": settings.render(config)}))
        elif args.action == "pin":
            print(json.dumps(settings.pin(config, args.symphony_commit, args.profile_revision, args.worker_image)))
        elif args.action == "preflight":
            report = preflight(config)
            print(json.dumps(report, indent=2))
            return 0 if report["inspection_ready"] else 2
        elif args.action == "launch":
            return launch(config)
        elif args.action == "status":
            print(json.dumps(status(config)))
        else:
            print(json.dumps(stop_inspection(config)))
        return 0
    except (Rejected, OSError, ValueError) as exc:
        reason = str(exc) if isinstance(exc, Rejected) else "runtime_io_error"
        print(json.dumps({"error": reason, "execution_enabled": False}), file=sys.stderr)
        return 1
