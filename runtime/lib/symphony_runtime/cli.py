"""Explicit pinned controller launch, finite inspection, and confirmed shutdown."""
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

from . import config as settings, windows_storage
from .common import Rejected, atomic, canonical, command, digest, locked, no_links, private_dir, private_file, read_json, require


def preflight(config, execute=False):
    checks = []
    def check(name, action):
        try:
            action()
            checks.append({"check": name, "status": "PASS"})
        except (Rejected, OSError, ValueError, TypeError) as error:
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
    inspection_ready = all(row["status"] == "PASS" for row in checks)
    worker = None
    if execute:
        check("controller_role", lambda: require(config["role"] == "controller" and settings.validate_manifest(config)["mode"] == "controller", "explicit_controller_pin_required"))
        for field in ("ssh_config", "app_key", "operator_credential"):
            check(field + "_required", lambda field=field: private_file(config[field]))
        try:
            from .controller import Controller
            worker = Controller(config).ready()
        except (Rejected, OSError, ValueError, TypeError):
            worker = {"ready": False, "reasons": ["worker_unavailable"]}
    return {"schema_version": 2, "profile": config["profile"], "role": config["role"], "execution_enabled": False,
            "inspection_ready": inspection_ready, "controller_ready": execute and all(row["status"] == "PASS" for row in checks),
            "worker": worker, "checks": checks}


def verify_source(config):
    manifest = settings.validate_manifest(config)
    root = no_links(config["symphony_root"])
    require(command(["git", "rev-parse", "HEAD"], cwd=root).decode().strip() == manifest["symphony_commit"], "symphony_pin_mismatch")
    require(not command(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=root).strip(), "symphony_checkout_dirty")
    require(config["project_template"], "project_template_required")
    profile = Path(config["project_template"]).parent
    require(command(["git", "rev-parse", "HEAD"], cwd=profile).decode().strip() == manifest["profile_revision"], "profile_pin_mismatch")
    require(not command(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=profile).strip(), "profile_checkout_dirty")
    if manifest["mode"] == "controller":
        lock = read_json(no_links(profile / "worker/profile-lock.json"))
        require(lock.get("runtime_contract") == 2 and lock.get("profile_contract") == 1, "profile_runtime_incompatible")
        require(lock.get("symphony_commit") == manifest["symphony_commit"], "profile_symphony_pin_mismatch")


class SupervisorInput:
    """A Windows parent keeps its stdin pipe open and sends bounded heartbeats."""
    def __init__(self, stream, receive_frame=None):
        self.last_seen = time.clock_gettime(time.CLOCK_BOOTTIME)
        self.closed = threading.Event()
        def receive():
            try:
                while True:
                    raw = stream.readline(16385 if receive_frame else 64)
                    if receive_frame:
                        if len(raw) > 16384 or not raw.endswith(b"\n"):
                            break
                        receive_frame(json.loads(raw))
                    elif raw != b"ALIVE\n":
                        break
                    self.last_seen = time.clock_gettime(time.CLOCK_BOOTTIME)
            except (Rejected, OSError, ValueError, KeyError, TypeError):
                pass
            finally:
                self.closed.set()
        threading.Thread(target=receive, daemon=True).start()

    def healthy(self):
        return not self.closed.is_set() and time.clock_gettime(time.CLOCK_BOOTTIME) - self.last_seen <= 15


def launch(config, delivery=False, *, execute=False, config_path=None, supervised=False, manager_token=None):
    require(sys.platform == "linux", "linux_required")
    report = preflight(config, execute)
    require(report["controller_ready"] if execute else report["inspection_ready"], "launch_preflight_failed")
    state = private_dir(config["state_root"])
    with locked(state / "launcher.lock"):
        if (state / "update-receipt.json").exists():
            atomic(state / "update-used.json", canonical({"started_at_ms": int(time.time() * 1000)}))
        # The fixed CLI entry point owns its temporary read credential cache.
        executable = Path(config["symphony_root"]) / "elixir/bin/symphony"
        require(not delivery, "use_documented_delivery_inspection_command")
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(Path.home()), "LANG": "C.UTF-8"}
        if config["ssh_config"]:
            env["SYMPHONY_SSH_CONFIG"] = config["ssh_config"]
        if config["app_key"]:
            env["SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH"] = config["app_key"]
        for name in ("SYMPHONY_GITHUB_APP_ID", "SYMPHONY_GITHUB_APP_CLIENT_ID", "SYMPHONY_GITHUB_INSTALLATION_ID"):
            if name in os.environ:
                env[name] = os.environ[name]
        if execute:
            require(config_path is not None, "configuration_path_required")
            env["SYMPHONY_RUNTIME_CONFIG"] = str(Path(config_path).absolute())
            env["SYMPHONY_RUNTIME_HELPER"] = str(Path(config["symphony_root"]) / "runtime/scripts/controller.py")
        proc = None
        stop = threading.Event()
        token = uuid.uuid4().hex
        receiver = None
        if config.get("windows_installation_id"):
            require(supervised and isinstance(manager_token, str) and len(manager_token) == 32 and
                    all(c in "0123456789abcdef" for c in manager_token), "windows_manager_required")
            receiver = lambda frame: windows_storage.retain(frame, config, manager_token, token)
        parent = SupervisorInput(sys.stdin.buffer, receiver) if supervised else None
        endpoint = state / "launcher.sock"
        if endpoint.exists():
            require(endpoint.is_socket(), "unexpected_launcher_path")
            endpoint.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(endpoint))
        endpoint.chmod(0o600)
        server.listen(4)
        server.settimeout(0.2)
        record = {"pid": os.getpid(), "start": Path("/proc/self/stat").read_text().split(") ", 1)[1].split()[19], "mode": "controller" if execute else "inspection", "token": token}
        atomic(state / "launcher.json", canonical(record))
        previous = signal.signal(signal.SIGTERM, lambda *_: stop.set())
        try:
            args = ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--logs-root", str(state)] if execute else ["--dry-run"]
            proc = subprocess.Popen([str(executable), *args, config["workflow"]],
                                    cwd=executable.parent.parent, env=env, stdin=subprocess.DEVNULL, start_new_session=True)
            while proc.poll() is None and not stop.is_set():
                if parent is not None and not parent.healthy():
                    stop.set()
                if execute and (state / "shutdown.ack").exists():
                    ack = read_json(private_file(state / "shutdown.ack"))
                    if ack.get("token") == token and ack.get("pilot_finished") is True:
                        stop.set()
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
            if execute:
                atomic(state / "shutdown.request", canonical({"token": token}))
                deadline = time.monotonic() + 105
                while proc is not None and proc.poll() is None and time.monotonic() < deadline:
                    ack = state / "shutdown.ack"
                    if ack.exists() and read_json(private_file(ack)).get("token") == token:
                        break
                    time.sleep(0.2)
            if proc is not None and proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            if execute:
                outcome = confirm_shutdown(config)
                atomic(state / "last_shutdown.json", canonical(outcome))
            server.close()
            endpoint.unlink(missing_ok=True)
            (state / "launcher.json").unlink(missing_ok=True)
        return 0 if execute and outcome["stopped"] else 1 if execute else proc.returncode


def status(config):
    path = private_dir(config["state_root"]) / "launcher.json"
    if not path.exists():
        result = {"running": False, "execution_enabled": False}
        prior = Path(config["state_root"]) / "last_shutdown.json"
        if prior.exists():
            result["last_shutdown"] = read_json(private_file(prior))
        return result
    record = read_json(private_file(path))
    require(set(record) == {"pid", "start", "mode", "token"} and type(record["pid"]) is int and record["pid"] > 1 and record["mode"] in ("inspection", "controller"), "invalid_launcher_record")
    try:
        process = Path(f"/proc/{record['pid']}")
        fields = process.joinpath("stat").read_text().split(") ", 1)[1].split()
        active = fields[0] not in ("Z", "X") and fields[19] == record["start"] and process.stat().st_uid == os.getuid()
    except (FileNotFoundError, ProcessLookupError):
        active = False
    return {"running": active, "execution_enabled": active and record["mode"] == "controller", "mode": record["mode"], "pid": record["pid"]}


def confirm_shutdown(config):
    from .controller import Controller
    try:
        proof = Controller(config).recover()
        stopped = proof["phase"] in ("idle", "stopped", "exported") and "worker_ownership_unknown" not in proof["reasons"]
        return {"stopped": stopped, "workspace_preserved": True}
    except (Rejected, OSError, ValueError):
        return {"stopped": False, "reason": "worker_stop_unconfirmed", "workspace_preserved": True}


def status_report(config):
    result = status(config)
    if config["role"] == "controller":
        from .controller import Controller
        try:
            controller = Controller(config)
            result["worker"] = controller.ready()
            record = controller.current()
            result["task"] = {key: record[key] for key in ("cycle", "interval", "branch")} if record else None
        except (Rejected, OSError, ValueError, KeyError, TypeError):
            result["worker"] = {"ready": False, "reasons": ["worker_unavailable"]}
    return result


def stop_inspection(config):
    state = private_dir(config["state_root"])
    if not status(config)["running"]:
        return status(config).get("last_shutdown", {"stopped": True, "workspace_preserved": True})
    record = read_json(private_file(state / "launcher.json"))
    endpoint = no_links(state / "launcher.sock")
    require(endpoint.is_socket() and endpoint.stat().st_uid == os.getuid(), "launcher_control_unavailable")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect(str(endpoint))
        connection.sendall(("STOP " + record["token"]).encode())
        require(connection.recv(16) == b"OK", "stop_not_acknowledged")
    deadline = time.monotonic() + (220 if record["mode"] == "controller" else 15)
    while status(config)["running"] and time.monotonic() < deadline:
        time.sleep(0.1)
    require(not status(config)["running"], "stop_unconfirmed")
    return status(config).get("last_shutdown", {"stopped": True, "workspace_preserved": True})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("configure", "render", "pin", "preflight", "launch", "status", "stop", "login", "cleanup", "models", "select-model"))
    parser.add_argument("--config", default=str(settings.default_config_path()))
    parser.add_argument("--from-json", help="Explicit machine parameters; no shell expressions")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--symphony-commit")
    parser.add_argument("--profile-revision")
    parser.add_argument("--worker-image")
    parser.add_argument("--model")
    parser.add_argument("--effort")
    parser.add_argument("--apply", action="store_true", help="Delete only successfully completed data past retention")
    args = parser.parse_args(argv)
    try:
        require(not args.execute or args.action in ("launch", "pin", "preflight"), "execute_only_for_activation")
        require(not args.apply or args.action == "cleanup", "apply_only_for_cleanup")
        require((args.model is None and args.effort is None) or args.action == "select-model", "model_options_only_for_selection")
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
            print(json.dumps(settings.pin(config, args.symphony_commit, args.profile_revision, args.worker_image, execute=args.execute)))
        elif args.action == "preflight":
            report = preflight(config, args.execute)
            print(json.dumps(report, indent=2))
            return 0 if report["inspection_ready"] else 2
        elif args.action == "launch":
            return launch(config, execute=args.execute, config_path=args.config)
        elif args.action == "status":
            print(json.dumps(status_report(config)))
        elif args.action in ("login", "models"):
            from .maintenance import login
            print(json.dumps(login(config, discover=args.action == "models")))
        elif args.action == "select-model":
            from .maintenance import select_model
            print(json.dumps(select_model(config, args.model, args.effort)))
        elif args.action == "cleanup":
            from .maintenance import cleanup
            print(json.dumps(cleanup(config, apply=args.apply)))
        else:
            print(json.dumps(stop_inspection(config)))
        return 0
    except (Rejected, OSError, ValueError) as exc:
        reason = str(exc) if isinstance(exc, Rejected) else "runtime_io_error"
        print(json.dumps({"error": reason, "execution_enabled": False}), file=sys.stderr)
        return 1
