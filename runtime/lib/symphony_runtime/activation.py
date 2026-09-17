"""An execution lease belongs to a live launcher, a pinned package and one scope."""
import os
from pathlib import Path

from . import config as settings
from .common import private_file, read_json, require


def process(pid):
    require(type(pid) is int and pid > 1, "invalid_launcher_pid")
    path = Path("/proc") / str(pid)
    require(path.stat().st_uid == os.getuid(), "launcher_owner_mismatch")
    fields = (path / "stat").read_text().split(") ", 1)[1].split()
    return {"start": fields[19], "parent": int(fields[1])}


def validate(config, workflow, *, descendant=True):
    from .cli import verify_source
    manifest = settings.validate_manifest(config)
    require(manifest["mode"] == "controller" and config["role"] == "controller", "execution_activation_required")
    verify_source(config)
    require(str(Path(workflow).absolute()) == config["workflow"], "activation_workflow_mismatch")
    record = read_json(private_file(Path(config["state_root"]) / "launcher.json"))
    require(record.get("mode") == "controller" and process(record["pid"])["start"] == record["start"], "launcher_lease_missing")
    if descendant:
        pid = os.getpid()
        for _ in range(10):
            if pid == record["pid"]:
                break
            pid = process(pid)["parent"]
        require(pid == record["pid"], "launcher_ancestry_mismatch")
    parsed = settings.workflow_settings(config)
    provider = parsed.get("tracker", {}).get("provider", {})
    require(parsed.get("tracker", {}).get("kind") == "github_projects" and isinstance(provider.get("github_app"), dict), "projects_app_profile_required")
    require(provider.get("item_ids") == config["pilot_item_ids"], "pilot_filter_mismatch")
    require(parsed.get("workspace", {}).get("root") == "/workspace", "prepared_workspace_root_required")
    require(parsed.get("delivery", {}).get("state_path") == str(Path(config["state_root"]) / "delivery.json"), "delivery_storage_mismatch")
    require(parsed.get("agent", {}).get("max_concurrent_agents") == 1, "single_controller_required")
    for name in ("app_key", "operator_credential", "ssh_config"):
        private_file(config[name])
    return {"workflow": config["workflow"], "workflow_sha256": manifest["workflow_sha256"],
            "repo": provider["repo"], "project_number": provider["project_number"],
            "pilot_item_ids": config["pilot_item_ids"], "state_root": config["state_root"],
            "worker_image": manifest["worker_image"], "mode": "controller", "launch_token": record["token"]}
