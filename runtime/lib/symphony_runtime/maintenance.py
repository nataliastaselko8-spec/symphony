"""Operator-only maintenance. No task API can authorize deletion or start a login."""
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid

from .common import Rejected, atomic, canonical, command, identifier, locked, parse_json, private_dir, private_file, require
from .controller import Controller
from . import models
from .storage import collect


def cleanup(config, *, apply=False):
    ctl = Controller(config)
    with locked(ctl.root / "launcher.lock"), locked(ctl.root / "prepare.lock"):
        report = ctl.recover()
        require(report["phase"] in ("idle", "stopped", "exported") and "worker_ownership_unknown" not in report["reasons"], "cleanup_stop_unconfirmed")
        remote, _ = ctl.rpc({"action": "collect", "retention_days": config["retention_days"], "dry_run": not apply})
        local = collect(ctl.root, retention_days=config["retention_days"], dry_run=not apply, categories=("attempts",))
        return {"dry_run": not apply, "controller": local, "worker": remote["removed"], "images": remote.get("images", []), "preserved": "cancelled, interrupted, incomplete cycles and final reports"}


def select_model(config, model, effort):
    ctl = Controller(config)
    with locked(ctl.root / "launcher.lock"), locked(ctl.root / "prepare.lock"):
        choice = models.available({"model": model, "effort": effort}, models.catalog(ctl.root, ctl.manifest["worker_image"]))
        atomic(ctl.root / "model-selection.json", canonical(choice))
        return {"selected": choice, "applied": None}


def login(config, *, discover=False):
    ctl = Controller(config)
    with locked(ctl.root / "launcher.lock"), locked(ctl.root / "prepare.lock"):
        require(discover or os.isatty(0), "interactive_terminal_required")
        report = ctl.recover()
        require(report["phase"] in ("idle", "stopped", "exported") and "worker_ownership_unknown" not in report["reasons"], "login_stop_unconfirmed")
        generation = "login-" + uuid.uuid4().hex
        directory = private_dir(ctl.root / "login", create=True)
        key = directory / (generation + "-identity")
        command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
        private_file(key)
        pub = " ".join(key.with_suffix(".pub").read_text().split()[:2])
        stop = threading.Event()
        proc = None
        wire = {"generation": generation, "interval": generation}
        catalog = None
        (ctl.root / "model-catalog.json").unlink(missing_ok=True)
        try:
            ctl.rpc({"action": "login_prepare", "generation": generation, "ssh_public_key": pub})
            proof, _ = ctl.rpc({"action": "start", **wire, "active_seconds": 600})
            require(proof.get("generation") == generation and proof.get("phase") == "running", "login_start_unconfirmed")
            # Reuse the same pinned SSH writer, with a private isolated login directory.
            session = private_dir(directory / generation, create=True)
            atomic(session / "task_key", key.read_bytes())
            ctl.ssh_config(session, proof)
            ssh = ["ssh", "-F", str(session / "ssh_config"), "-T", "symphony-task-" + generation]
            for attempt in range(5):
                try:
                    command([*ssh, "true"], timeout=6)
                    break
                except Rejected:
                    require(attempt < 4, "login_endpoint_unavailable")
                    time.sleep(0.2)
            def heartbeat():
                while not stop.wait(10):
                    try:
                        status, _ = ctl.rpc({"action": "heartbeat", **wire})
                        require(status.get("generation") == generation and status.get("network_ready") is True, "login_lease_lost")
                    except (Rejected, OSError):
                        stop.set()
                        if proc is not None:
                            proc.terminate()
            thread = threading.Thread(target=heartbeat, daemon=True)
            thread.start()
            if not discover:
                proc = subprocess.Popen([*ssh, "codex login --device-auth"],
                                        env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home()), "LANG": "C.UTF-8"})
                try:
                    result = proc.wait(timeout=500)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                    raise Rejected("login_timeout")
                require(result == 0 and not stop.is_set(), "login_not_completed")
            script = Path(__file__).resolve().parents[2] / "scripts/model_catalog.py"
            result = command([*ssh, "python3 -I -B -"], input_data=script.read_bytes(), timeout=75)
            catalog = models.normalize(parse_json(result)["data"])
            require(not stop.is_set(), "model_catalog_lease_lost")
        finally:
            stop.set()
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            proof, _ = ctl.rpc({"action": "stop", **wire})
            require(proof.get("phase") == "stopped" and proof.get("generation") == generation, "login_stop_unconfirmed")
            key.unlink()
            key.with_suffix(".pub").unlink()
            session = directory / generation
            if session.exists():
                import shutil
                require(shutil.rmtree.avoids_symlink_attacks, "safe_tree_removal_required")
                shutil.rmtree(private_dir(session))
        atomic(ctl.root / "model-catalog.json", canonical({"models": catalog, "image": ctl.manifest["worker_image"], "queried_at": int(time.time())}))
        return {"login_completed": not discover, "worker_stopped": True, "models": catalog}
