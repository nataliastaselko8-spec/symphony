"""Versioned machine configuration, separate from project policy and credentials."""
import os
from pathlib import Path
import re

from .common import Rejected, atomic, canonical, digest, identifier, no_links, parse_json, private_dir, private_file, read_json, require, sha

VERSION = 2
ROOT = Path(__file__).resolve().parents[2]
PATHS = {"symphony_root", "project_template", "state_root", "workflow", "manifest", "ssh_config", "app_key", "operator_credential"}
KEYS = PATHS | {"schema_version", "role", "profile", "runtime_kind", "controller_distro", "controller_user", "worker_distro", "worker_user", "worker_host", "management_host", "dashboard_port", "pilot_item_ids", "disk_minimum_bytes", "disk_warning_bytes", "retention_days"}


def default_config_path():
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "symphony" / "local.json"


def defaults(config_path):
    base = Path(config_path).absolute().parent
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "symphony" / "default"
    return dict(schema_version=VERSION, role="inspection", profile="default", runtime_kind="wsl2-podman",
                symphony_root=str(ROOT.parent), project_template=None, state_root=str(state),
                workflow=str(base / "WORKFLOW.md"), manifest=str(base / "deployment.json"),
                controller_distro=None, controller_user=None, worker_distro=None, worker_user=None,
                worker_host="symphony-worker", management_host="symphony-management", ssh_config=None,
                app_key=None, operator_credential=None, dashboard_port=4080, pilot_item_ids=[],
                disk_minimum_bytes=5 * 1024**3, disk_warning_bytes=10 * 1024**3, retention_days=7)


def resolve(raw, config_path):
    require(isinstance(raw, dict) and not set(raw) - KEYS, "unknown_configuration_field")
    require(type(raw.get("schema_version")) is int and raw["schema_version"] in (1, VERSION), "unsupported_configuration_version")
    result = defaults(config_path)
    result.update(raw)
    require(result["role"] in ("inspection", "controller"), "invalid_role")
    require(result["runtime_kind"] == "wsl2-podman", "unsupported_runtime")
    ids = result["pilot_item_ids"]
    require(isinstance(ids, list) and len(ids) <= 1 and all(isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,200}", v) for v in ids), "one_pilot_item_required")
    require(type(result["retention_days"]) is int and 1 <= result["retention_days"] <= 3650, "invalid_retention")
    low, warning = result["disk_minimum_bytes"], result["disk_warning_bytes"]
    require(type(low) is int and type(warning) is int and 1024**3 <= low <= warning, "invalid_disk_thresholds")
    identifier(result["profile"])
    require(type(result["dashboard_port"]) is int and 1024 <= result["dashboard_port"] <= 65535, "invalid_dashboard_port")
    for key in ("worker_host", "management_host"):
        identifier(result[key])
    for key in ("controller_distro", "controller_user", "worker_distro", "worker_user"):
        value = result[key]
        require(value is None or (isinstance(value, str) and value and not value.startswith("-") and not any(ord(c) < 32 for c in value)), "invalid_" + key)
    for key in PATHS:
        value = result[key]
        if value is None:
            continue
        require(isinstance(value, str) and value and not any(ord(c) < 32 for c in value), "invalid_path")
        path = Path(value).expanduser()
        if not path.is_absolute():
            path = Path(config_path).absolute().parent / path
        result[key] = str(no_links(path))
    state = Path(result["state_root"])
    source = Path(result["symphony_root"])
    require(state != Path.home() and len(state.parts) >= 4, "dedicated_state_directory_required")
    require(not state.is_relative_to(source) and not source.is_relative_to(state), "state_source_overlap")
    if os.name == "posix":
        require(not state.is_relative_to("/mnt") and not state.is_relative_to("/tmp"), "state_requires_private_linux_storage")
    for key in ("app_key", "operator_credential"):
        if result[key]:
            credential = Path(result[key])
            require(not credential.is_relative_to(source) and not credential.is_relative_to(state), "credential_storage_overlap")
    require(result["workflow"] != result["project_template"], "template_output_overlap")
    return result


def load(path):
    return resolve(read_json(private_file(path)), path)


def configure(path, supplied):
    path = no_links(path)
    require(not path.exists(), "configuration_exists")
    config = resolve({**defaults(path), **supplied}, path)
    private_dir(path.parent, create=True)
    private_dir(config["state_root"], create=True)
    atomic(path, canonical(config) + b"\n")
    return config


def render(config):
    """JSON is a YAML subset. Only complete, allowlisted string slots are expanded."""
    require(config["project_template"], "project_template_required")
    template = no_links(config["project_template"])
    text = template.read_text(encoding="utf-8")
    require(len(text.encode()) < 1024 * 1024 and text.startswith("---\n"), "invalid_workflow_template")
    front, separator, prompt = text[4:].partition("\n---\n")
    require(separator, "invalid_workflow_template")
    import json
    try:
        settings = parse_json(front)
    except ValueError as exc:
        raise Rejected("template_front_matter_requires_json") from exc
    bindings = {
        "workspace_root": "/workspace", "state_path": str(Path(config["state_root"]) / "delivery.json"),
        "worker_host": config["worker_host"], "app_key": config["app_key"],
        "operator_credential": config["operator_credential"], "dashboard_port": config["dashboard_port"],
        "dashboard_origin": "http://localhost:" + str(config["dashboard_port"]),
        "pilot_item_ids": config["pilot_item_ids"],
    }
    def bind(value):
        if isinstance(value, dict):
            return {key: bind(child) for key, child in value.items()}
        if isinstance(value, list):
            return [bind(child) for child in value]
        if isinstance(value, str) and "${runtime." in value:
            match = re.fullmatch(r"\$\{runtime\.([a-z_]+)\}", value)
            require(match is not None and match[1] in bindings, "unknown_template_slot")
            require(bindings[match[1]] is not None, "missing_template_binding_" + match[1])
            return bindings[match[1]]
        return value
    resolved = bind(settings)
    require(isinstance(resolved, dict) and resolved.get("tracker", {}).get("kind") == "github_projects", "projects_workflow_required")
    require("${runtime." not in prompt, "runtime_slots_not_allowed_in_prompt")
    raw = b"---\n" + canonical(resolved) + b"\n---\n" + prompt.encode()
    output = no_links(config["workflow"])
    private_dir(output.parent)
    if output.exists():
        require(output.read_bytes() == raw, "workflow_changed_explicit_regeneration_required")
    else:
        atomic(output, raw)
    return digest(raw)


def validate_manifest(config):
    manifest = read_json(private_file(config["manifest"]))
    fields = {"schema_version", "mode", "symphony_commit", "workflow_sha256", "profile_revision", "worker_image"}
    require(type(manifest.get("schema_version")) is int and manifest["schema_version"] in (1, VERSION), "invalid_manifest_version")
    if manifest["schema_version"] == VERSION:
        fields |= {"artifact_sha256", "runtime_sha256", "config_sha256"}
    require(set(manifest) == fields, "invalid_manifest")
    require(manifest["mode"] in ("inspection", "controller"), "invalid_manifest_mode")
    require(manifest["schema_version"] == VERSION or manifest["mode"] == "inspection", "execution_integration_required")
    sha(manifest["symphony_commit"])
    sha(manifest["profile_revision"])
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", manifest["worker_image"] or ""), "image_digest_required")
    require(manifest["workflow_sha256"] == digest(private_file(config["workflow"]).read_bytes()), "workflow_digest_mismatch")
    if manifest["mode"] == "controller":
        require(config["schema_version"] == VERSION and config["role"] == "controller", "controller_role_required")
        require(manifest["config_sha256"] == digest(canonical(config)), "configuration_digest_mismatch")
        require(manifest["runtime_sha256"] == package_digest(Path(config["symphony_root"]) / "runtime"), "runtime_digest_mismatch")
        require(manifest["artifact_sha256"] == artifact_digest(config), "artifact_digest_mismatch")
    return manifest


def pin(config, commit, revision, image, *, execute=False):
    """Only explicit accepted revisions; never fetch or select latest."""
    sha(commit)
    sha(revision)
    require(isinstance(image, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", image), "image_digest_required")
    require(not execute or config["role"] == "controller" and config["schema_version"] == VERSION, "controller_role_required")
    value = {"schema_version": VERSION, "mode": "controller" if execute else "inspection", "symphony_commit": commit,
             "profile_revision": revision, "worker_image": image,
             "workflow_sha256": digest(private_file(config["workflow"]).read_bytes()),
             "artifact_sha256": artifact_digest(config) if execute else None,
             "runtime_sha256": package_digest(Path(config["symphony_root"]) / "runtime") if execute else None,
             "config_sha256": digest(canonical(config))}
    target = no_links(config["manifest"])
    if target.exists():
        require(read_json(private_file(target)) == value, "manifest_exists_choose_new_local_profile")
    else:
        atomic(target, canonical(value))
    return value


def artifact_digest(config):
    file = no_links(Path(config["symphony_root"]) / "elixir/bin/symphony")
    require(file.is_file() and file.stat().st_nlink == 1, "artifact_required")
    return digest(file.read_bytes())


def package_digest(root):
    root = no_links(root)
    files = {}
    for directory in ("lib", "scripts", "worker", "config"):
        for file in sorted((root / directory).rglob("*")):
            no_links(file)
            if file.is_file() and file.suffix not in (".pyc", ".pyo"):
                require(file.stat().st_nlink == 1, "unsafe_runtime_file")
                files[str(file.relative_to(root))] = digest(file.read_bytes())
    require(files and (root / "scripts/controller.py").is_file(), "runtime_package_missing")
    return digest(canonical(files))


def workflow_settings(config):
    text = private_file(config["workflow"]).read_text()
    require(text.startswith("---\n"), "invalid_workflow")
    front, separator, _ = text[4:].partition("\n---\n")
    require(separator, "invalid_workflow")
    return parse_json(front)
