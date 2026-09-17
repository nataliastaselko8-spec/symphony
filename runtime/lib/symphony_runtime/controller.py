"""Bounded trusted-controller operations. No model-selected paths, hosts or commands."""
import os
from pathlib import Path
import re
import time

from . import config as settings
from . import models
from .activation import validate
from .client import accept_export, exchange
from .common import Rejected, atomic, canonical, command, digest, identifier, locked, no_links, private_dir, private_file, read_json, require, sha
from .guardian import public_key
from .seed import create as create_seed
from .storage import capacity, collect, retire


class Controller:
    def __init__(self, config, *, transport=exchange, seed=create_seed):
        self.config, self.transport, self.seed = config, transport, seed
        self.root = private_dir(config["state_root"])
        self.attempts = private_dir(self.root / "attempts", create=True)
        self.bindings = private_dir(self.root / "bindings", create=True)
        self.manifest = settings.validate_manifest(config)
        self.profile = settings.workflow_settings(config)["tracker"]["provider"]

    def rpc(self, request, body=b""):
        return self.transport(self.config["ssh_config"], self.config["management_host"], request, body)

    def current(self):
        file = self.root / "worker.json"
        if not file.exists():
            return None
        value = read_json(private_file(file))
        for key in ("cycle", "interval", "generation"):
            identifier(value[key])
        require(value["interval"] == value["generation"] and value["repo"] == self.profile["repo"], "invalid_worker_record")
        return value

    def directory(self, generation):
        return private_dir(self.attempts / identifier(generation), create=True)

    def bound(self, request):
        record = self.current()
        require(record is not None and all(request.get(key) == record[key] for key in ("cycle", "interval", "generation")), "stale_controller_handle")
        return record

    @staticmethod
    def matches(proof, record):
        require(all(proof.get(key) == record[key] for key in ("cycle", "branch", "interval", "generation")), "worker_scope_mismatch")

    def known_stopped(self, proof):
        if proof.get("phase") not in ("stopped", "exported"):
            return False
        try:
            path = self.bindings / (identifier(proof["generation"]) + ".json")
            record = read_json(private_file(path))
            self.matches(proof, record)
            return record["repo"] == self.profile["repo"]
        except (Rejected, OSError, ValueError, KeyError):
            return False

    def ready(self):
        proof, _ = self.rpc({"action": "status"})
        local_disk = capacity(self.root, self.config["disk_minimum_bytes"], self.config["disk_warning_bytes"])
        free = proof.get("free_bytes")
        require(type(free) is int and free >= 0, "worker_disk_unknown")
        worker_disk = {"free_bytes": free, "status": "blocked" if free < self.config["disk_minimum_bytes"] else "warning" if free < self.config["disk_warning_bytes"] else "ready"}
        model_status = models.ready(self.root, self.manifest["worker_image"])
        reasons = list(model_status["reasons"])
        if proof.get("image") != self.manifest["worker_image"]:
            reasons.append("worker_image_mismatch")
        if proof.get("profile_revision") != self.manifest["profile_revision"] or proof.get("runtime_contract") != "2":
            reasons.append("worker_profile_mismatch")
        if proof.get("network_ready") is not True:
            reasons.append("worker_network_not_ready")
        if not proof.get("auth_present"):
            reasons.append("codex_login_required")
        if local_disk["status"] == "blocked" or worker_disk["status"] == "blocked":
            reasons.append("disk_space_low")
        current = self.current()
        if proof.get("phase") != "idle":
            if self.known_stopped(proof):
                pass
            elif current is None or any(proof.get(key) != current[key] for key in ("cycle", "interval", "generation")):
                reasons.append("worker_ownership_unknown")
            elif proof.get("phase") not in ("stopped", "exported"):
                reasons.append("worker_reconciliation_required")
        applied = None
        if current:
            try:
                models.bound(self.root, current["cycle"], current["repo"])
            except (Rejected, OSError, ValueError) as exc:
                reasons.append(str(exc) if isinstance(exc, Rejected) else "model_selection_unreadable")
            receipt = self.root / "model-receipts" / (current["interval"] + ".json")
            if receipt.exists():
                saved = read_json(private_file(receipt))
                require(saved.get("cycle") == current["cycle"] and saved.get("interval") == current["interval"], "model_receipt_mismatch")
                applied = models.pair(saved["selection"])
        return {"ready": not reasons, "reasons": list(dict.fromkeys(reasons)), "controller_disk": local_disk,
                "model": {"selected": model_status["selected"], "applied": applied},
                "worker_disk": worker_disk, "phase": proof.get("phase"), "auth_present": proof.get("auth_present") is True}

    def prepare(self, request):
        require(set(request) == {"action", "context", "token"}, "invalid_prepare_request")
        context = request["context"]
        require(isinstance(context, dict) and context.get("repo") == self.profile["repo"]
                and context.get("project_number") == self.profile["project_number"], "task_scope_mismatch")
        cycle, interval = identifier(context["cycle_id"]), identifier(context["interval_id"])
        sha(context["expected_dev_sha"])
        branch = context["branch"]
        require(isinstance(branch, str) and re.fullmatch(r"agent/[A-Za-z0-9_/-]+", branch) and "//" not in branch and not branch.endswith("/"), "invalid_task_branch")
        record = {"cycle": cycle, "interval": interval, "generation": interval, "branch": branch,
                  "repo": self.profile["repo"], "base_sha": context["expected_dev_sha"]}
        with locked(self.root / "prepare.lock"):
            models.bind(self.root, cycle, record["repo"], self.manifest["worker_image"])
            previous = self.current()
            if previous != record:
                require(self.ready()["ready"], "worker_not_ready")
                directory = self.directory(interval)
                require(not (directory / "record.json").exists(), "generation_reuse_rejected")
                atomic(directory / "record.json", canonical(record))
                binding = self.bindings / (interval + ".json")
                require(not binding.exists(), "generation_reuse_rejected")
                atomic(binding, canonical(record))
                atomic(self.root / "worker.json", canonical(record))  # Durable intent before SSH or Git.
            directory = self.directory(interval)
            require(not (directory / "revoked").exists(), "worker_permit_revoked")
            key = directory / "task_key"
            if not key.exists():
                command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
            private_file(key)
            pub = " ".join(no_links(key.with_suffix(".pub")).read_text().split()[:2])
            payload = self.seed(directory, record["repo"], record["base_sha"], request["token"])
            require(not (directory / "revoked").exists(), "worker_permit_revoked")
            wire = {"action": "prepare", **record, "bundle_size": len(payload), "bundle_sha256": digest(payload), "ssh_public_key": pub}
            proof, _ = self.rpc(wire, payload)
            self.matches(proof, record)
            atomic(directory / "prepared", b"confirmed\n")
            if (directory / "revoked").exists():
                self.rpc({"action": "stop", "interval": interval, "generation": interval})
                raise ValueError("revoked_prepare")
            require(proof.get("phase") == "prepared", "worker_prepare_unconfirmed")
            return {**record, "phase": "prepared"}

    def operation(self, request):
        action = request.get("action")
        expected = {"action", "cycle", "interval", "generation"} | ({"active_ms"} if action == "start" else {"sha"} if action == "export" else set())
        require(set(request) == expected and action in ("start", "heartbeat", "stop", "export"), "invalid_worker_operation")
        record = self.bound(request)
        directory = self.directory(record["generation"])
        wire = {key: request[key] for key in ("action", "interval", "generation")}
        if action == "stop":
            atomic(directory / "revoked", b"revoked\n")
            # A still-running prepare helper could send after an idle status. Its
            # lock must be released before absence counts as a stop proof.
            with locked(self.root / "prepare.lock"):
                current, _ = self.rpc({"action": "status"})
                if current.get("phase") == "idle" or (self.known_stopped(current) and current.get("generation") != record["generation"]):
                    return {**record, "phase": "stopped"}
                self.matches(current, record)
                atomic(directory / "prepared", b"confirmed\n")
        elif action != "export":
            require(not (directory / "revoked").exists(), "worker_permit_revoked")
        if action == "start":
            selection = models.bound(self.root, record["cycle"], record["repo"])
            health = self.ready()
            require(not set(health["reasons"]) - {"worker_reconciliation_required"}, "worker_not_ready")
            require(type(request["active_ms"]) is int and 1000 <= request["active_ms"] <= 3600000, "invalid_active_budget")
            wire["active_seconds"] = request["active_ms"] // 1000
        if action == "export":
            wire["sha"] = sha(request["sha"])
        proof, raw = self.rpc(wire)
        self.matches(proof, record)
        if action == "start":
            require(proof.get("phase") == "running", "worker_start_unconfirmed")
            if (directory / "revoked").exists():
                self.rpc({"action": "stop", "interval": record["interval"], "generation": record["generation"]})
                raise ValueError("revoked_start")
            self.ssh_config(directory, proof)
            return {**record, "phase": "running", "host": "symphony-task-" + record["generation"],
                    "ssh_config": str(directory / "ssh_config"), "workspace": "/workspace/repo", "selection": selection}
        if action == "stop":
            require(proof.get("phase") == "stopped", "worker_stop_unconfirmed")
        if action == "heartbeat":
            require(proof.get("phase") == "running" and proof.get("network_ready") is True, "worker_lease_lost")
            local = capacity(self.root, self.config["disk_minimum_bytes"], self.config["disk_warning_bytes"])
            free = proof.get("free_bytes")
            require(type(free) is int and free >= 0, "worker_disk_unknown")
            remote = {"free_bytes": free, "status": "blocked" if free < self.config["disk_minimum_bytes"] else "warning" if free < self.config["disk_warning_bytes"] else "ready"}
            blocked = local["status"] == "blocked" or remote["status"] == "blocked"
            return {**record, "phase": "running", "ready": not blocked, "reasons": ["disk_space_low"] if blocked else [],
                    "controller_disk": local, "worker_disk": remote, "auth_present": proof.get("auth_present") is True}
        if action == "export":
            require(proof.get("sha") == request["sha"], "export_sha_mismatch")
            path = accept_export(directory, record["generation"], proof, raw)
            return {**record, "sha": request["sha"], "path": path}
        return {**record, "phase": proof["phase"], "free_bytes": proof.get("free_bytes")}

    @staticmethod
    def ssh_config(directory, proof):
        port = proof.get("port")
        require(type(port) is int and 1024 <= port <= 65535, "invalid_worker_endpoint")
        pub = public_key(proof["host_public_key"])
        known = directory / "known_hosts"
        atomic(known, ("[127.0.0.1]:" + str(port) + " " + pub).encode())
        def quoted(path):
            require(not any(c in str(path) for c in '\r\n\0"%\\'), "unsupported_ssh_path")
            return '"' + str(path) + '"'
        raw = (f"Host symphony-task-{proof['generation']}\n  HostName 127.0.0.1\n  Port {port}\n  User worker\n"
               f"  IdentityFile {quoted(directory / 'task_key')}\n  UserKnownHostsFile {quoted(known)}\n"
               "  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes\n  IdentitiesOnly yes\n  BatchMode yes\n"
               "  ClearAllForwardings yes\n  ForwardAgent no\n  ForwardX11 no\n  RequestTTY no\n  ConnectTimeout 5\n")
        atomic(directory / "ssh_config", raw.encode())

    def recover(self):
        record = self.current()
        if record:
            self.operation({"action": "stop", **{key: record[key] for key in ("cycle", "interval", "generation")}})
        report = self.ready()
        if self.manifest["mode"] == "controller" and report["phase"] in ("idle", "stopped", "exported") and "worker_ownership_unknown" not in report["reasons"]:
            collect(self.root, retention_days=self.config["retention_days"], dry_run=False, categories=("attempts",))
        return report

    def retire(self, request):
        require(set(request) == {"action", "report"}, "invalid_retirement_request")
        report = request["report"]
        cycle = identifier(report["cycle"])
        generations, remote_generations = [], []
        for entry in sorted(self.attempts.iterdir()):
            record = read_json(private_file(no_links(entry) / "record.json"))
            if record["cycle"] == cycle:
                generations.append(record["generation"])
                if (entry / "prepared").exists():
                    remote_generations.append(record["generation"])
        report = {**report, "generations": generations, "remote_generations": remote_generations}
        receipt = self.root / "reports" / (cycle + ".json")
        if receipt.exists():
            previous = read_json(private_file(receipt))["report"]
            require({key: value for key, value in previous.items() if key not in ("generations", "remote_generations")} == {key: value for key, value in report.items() if key not in ("generations", "remote_generations")}, "summary_changed")
            report = previous
        remote_report = {**report, "generations": report["remote_generations"]}
        proof, _ = self.rpc({"action": "retire", "cycle": cycle, "report": remote_report, "retention_days": self.config["retention_days"]})
        require(proof.get("retired") == cycle, "retirement_unconfirmed")
        retire(self.root, cycle, report, retention_days=self.config["retention_days"])
        current = self.current()
        active = None if not current or current["cycle"] == cycle else current["cycle"]
        removed = collect(self.root, active_cycle=active, retention_days=self.config["retention_days"], dry_run=False, categories=("attempts",))
        return {"retired": cycle, "removed": removed}

    def dispatch(self, request):
        action = request.get("action")
        if action == "validate":
            require(set(request) == {"action", "workflow"}, "invalid_activation_request")
            return validate(self.config, request["workflow"])
        if action == "status":
            require(set(request) == {"action"}, "invalid_status_request")
            return self.ready()
        validate(self.config, self.config["workflow"])
        if action == "prepare":
            return self.prepare(request)
        if action == "model_applied":
            require(set(request) == {"action", "cycle", "interval", "generation", "selection"}, "invalid_model_receipt")
            record = self.bound(request)
            require(not (self.directory(record["generation"]) / "revoked").exists(), "worker_permit_revoked")
            actual = models.applied(self.root, record["cycle"], record["interval"], record["repo"], request["selection"])
            return {"applied": actual}
        if action == "recover":
            require(set(request) == {"action"}, "invalid_recovery_request")
            return self.recover()
        if action == "retire":
            return self.retire(request)
        if action == "export_cycle":
            require(set(request) == {"action", "cycle", "branch", "sha"}, "invalid_export_request")
            record = self.current()
            require(record and record["cycle"] == request["cycle"] and record["branch"] == request["branch"], "export_owner_changed")
            return self.operation({"action": "export", "sha": request["sha"], **{key: record[key] for key in ("cycle", "interval", "generation")}})
        if action == "finish":
            require(set(request) == {"action", "report", "pilot_finished"} and type(request["pilot_finished"]) is bool, "invalid_finish_request")
            proof = self.recover()
            require(proof["phase"] in ("idle", "stopped", "exported") and "worker_ownership_unknown" not in proof["reasons"], "shutdown_unconfirmed")
            report = request["report"]
            if report is not None:
                require(isinstance(report, dict) and len(canonical(report)) <= 16384, "invalid_summary")
                cycle = identifier(report["cycle"])
                if report.get("outcome") == "completed":
                    self.retire({"action": "retire", "report": report})
                else:
                    require(report.get("outcome") == "cancelled", "invalid_summary_outcome")
                    target = private_dir(self.root / "preserved_reports", create=True) / (cycle + ".json")
                    if target.exists():
                        require(read_json(private_file(target)) == report, "summary_changed")
                    else:
                        atomic(target, canonical(report))
            lease = read_json(private_file(self.root / "launcher.json"))
            atomic(self.root / "shutdown.ack", canonical({"token": lease["token"], "pilot_finished": request["pilot_finished"], "stopped": True}))
            return {"stopped": True}
        return self.operation(request)
