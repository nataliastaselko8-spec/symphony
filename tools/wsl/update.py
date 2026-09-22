"""Private, resumable update preparation. The Windows descriptor is switched last.

This helper runs as the controller user with the newly verified runtime. It never
changes the source state, credentials, worker workspaces, or the old release.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def inventory(root):
    """Hash preserved regular files; locks and process-local leases are not data."""
    from symphony_runtime.common import no_links, private_dir
    root = private_dir(root)
    ignored = {"launcher.sock", "windows-disk.json", "shutdown.request", "shutdown.ack"}
    result = {}
    for file in sorted(root.rglob("*")):
        no_links(file)
        relative = str(file.relative_to(root))
        if file.name.endswith(".lock") or relative in ignored:
            continue
        info = file.lstat()
        need(info.st_uid == os.getuid() and not info.st_mode & 0o022, "unsafe_retained_state")
        if stat.S_ISDIR(info.st_mode):
            continue
        need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "nonregular_retained_state")
        need(relative != "launcher.json", "confirmed_stop_required")
        with file.open("rb") as stream:
            result[relative] = hashlib.file_digest(stream, "sha256").hexdigest()
    return result


def immutable(path, raw):
    from symphony_runtime.common import atomic, private_file
    path = Path(path)
    private_tree(path.parent)
    if path.exists():
        need(private_file(path).read_bytes() == raw, "prepared_update_changed")
    else:
        atomic(path, raw)


def private_tree(path):
    from symphony_runtime.common import no_links, private_dir
    path = no_links(path)
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    info = current.stat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022, "unsafe_update_parent")
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
    return private_dir(path)


def copy_state(source, target, hashes, exclude=()):
    private_tree(target)
    for name, checksum in hashes.items():
        if name in exclude:
            continue
        raw = (Path(source) / name).read_bytes()
        need(hashlib.sha256(raw).hexdigest() == checksum, "source_changed_during_update")
        immutable(Path(target) / name, raw)


def migration(before, after, operator):
    """Use the actual Elixir replay and store owner, not a Python state rewrite."""
    expression = r'''
    Logger.configure(level: :error)
    alias SymphonyElixir.{Config.Schema, Workflow}
    alias SymphonyElixir.DeliveryGate.{Migration, Pilot, Settings, Store}
    {:ok, old} = Workflow.load(System.fetch_env!("SYMPHONY_UPDATE_BEFORE"))
    {:ok, target} = Workflow.load(System.fetch_env!("SYMPHONY_UPDATE_AFTER"))
    {:ok, old_config} = Schema.parse(old.config)
    {:ok, new_config} = Schema.parse(target.config)
    {:ok, old_gate} = Settings.from_config(old_config)
    {:ok, new_gate} = Settings.from_config(new_config)
    {:ok, source} = Store.open(old_gate.path)
    try do
      {:ok, snapshot} = Store.request(source, %{"op" => "read"})
      {:ok, _} = Pilot.inspect(snapshot, old_gate.scope, old_config.tracker.provider["item_ids"] || [])
      {:ok, migrated} = Migration.prepare(snapshot, old.config, target.config)
      {:ok, destination} = Store.open(new_gate.path)
      try do
        {:ok, existing} = Store.request(destination, %{"op" => "read"})
        case existing do
          nil -> {:ok, true} = Store.request(destination, %{"op" => "write", "snapshot" => migrated})
          ^migrated -> :ok
        end
      after
        Store.close(destination)
      end
      IO.puts(Jason.encode!(%{migrated: true, source_revision: snapshot && snapshot["revision"], revision: migrated["revision"]}))
    after
      Store.close(source)
    end
    '''
    env = os.environ.copy()
    env.update(SYMPHONY_UPDATE_BEFORE=before["runtime_config"]["workflow"],
               SYMPHONY_UPDATE_AFTER=after["runtime_config"]["workflow"])
    for key, suffix in (("app_id", "APP_ID"), ("client_id", "APP_CLIENT_ID"), ("installation_id", "INSTALLATION_ID")):
        env["SYMPHONY_GITHUB_" + suffix] = before["github_app"][key]
    env["SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH"] = before["runtime_config"]["app_key"]
    raw = operator.run([after["controller"]["mise"], "exec", "--", "mix", "run", "--no-start", "--no-compile",
                        "--no-deps-check", "-e", expression],
                       cwd=Path(after["runtime_config"]["symphony_root"]) / "elixir", env=env, timeout=60)
    return json.loads(raw)


def prepare(request, operator):
    before, after = request["before"], request["after"]
    operator.validate(before)
    operator.validate(after)
    need(re.fullmatch(r"[0-9a-f]{24}", request["release"]), "invalid_release")
    need(before["installation_id"] == after["installation_id"] and
         before["github_app"] == after["github_app"] and before["ssh"] == after["ssh"], "update_identity_changed")
    settings, cli = operator.runtime(after)
    from symphony_runtime.common import canonical, private_dir, private_file, read_json
    old = settings.load(before["controller"]["config"])
    need(old == settings.resolve(before["runtime_config"], before["controller"]["config"]), "source_configuration_changed")
    cli.verify_source(old)
    candidate = settings.resolve(after["runtime_config"], after["controller"]["config"])
    mutable = {"symphony_root", "project_template", "state_root", "workflow", "manifest", "windows_installation_id"}
    need({k: v for k, v in old.items() if k not in mutable} ==
         {k: v for k, v in candidate.items() if k not in mutable}, "update_changes_operator_settings")
    need(candidate["windows_installation_id"] == before["installation_id"], "windows_identity_required")
    source, target = Path(old["state_root"]), Path(candidate["state_root"])
    need(source != target and not source.is_relative_to(target) and not target.is_relative_to(source), "separate_update_state_required")
    directory = private_tree(Path(after["controller"]["config"]).parent)
    with operator.stopped_locks(old):
        proof = operator.pilot_source_idle(before, old, replay_data=after)
        hashes = inventory(source)
        intent = {"schema_version": 1, "release": request["release"], "before": before, "after": after,
                  "source_files": hashes, "evidence": proof}
        immutable(directory / "update-intent.json", canonical(intent))
        copy_state(source, directory / "backup/state", hashes)
        for name in ("workflow", "manifest"):
            immutable(directory / "backup" / name, private_file(old[name]).read_bytes())
        immutable(directory / "backup/local.json", private_file(before["controller"]["config"]).read_bytes())
        file = Path(after["controller"]["config"])
        if file.exists():
            need(settings.load(file) == candidate, "prepared_configuration_changed")
        else:
            settings.configure(file, candidate)
        with operator.stopped_locks(candidate):
            need(not (target / "update-used.json").exists(), "update_already_used")
            # Last shutdown and the catalog are recomputed against the new image.
            copy_state(source, target, hashes, {"delivery.json", "delivery.json.previous", "last_shutdown.json", "model-catalog.json"})
            settings.render(candidate)
            report = migration(before, after, operator)
            settings.pin(candidate, **{ "commit": after["pins"]["symphony_commit"],
                         "revision": after["pins"]["profile_revision"], "image": after["pins"]["worker_image"]}, execute=True)
            cli.verify_source(candidate)
            need(inventory(source) == hashes, "source_changed_during_update")
            immutable(target / "update-receipt.json", canonical({"release": request["release"], "migration": report}))
    return {"prepared": True, "execution_started": False, "migration": report}


def checkpoint(request, operator, *, verify=False):
    """Freeze both copies after maintenance; rollback is refused after any new use."""
    after = request["after"]
    settings, cli = operator.runtime(after)
    from symphony_runtime.common import canonical, private_file, read_json
    config = settings.load(after["controller"]["config"])
    cli.verify_source(config)
    root = Path(config["state_root"])
    with operator.stopped_locks(config):
        need(not (root / "update-used.json").exists(), "rollback_after_start_forbidden")
        receipt = read_json(private_file(root / "update-receipt.json"))
        need(receipt["release"] == request["release"], "release_mismatch")
        if not verify:
            from symphony_runtime import models
            models.available(models.selected(root), models.catalog(root, after["pins"]["worker_image"]))
        shutdown = read_json(private_file(root / "last_shutdown.json"))
        need(shutdown.get("stopped") is True and shutdown.get("identity") == operator.stop_identity(config), "updated_stop_unconfirmed")
        old = settings.load(request["before"]["controller"]["config"])
        with operator.stopped_locks(old):
            value = {"before": inventory(old["state_root"]), "after": inventory(root),
                     "before_descriptor": request["before"], "after_descriptor": after}
            file = Path(after["controller"]["config"]).parent / "rollback-checkpoint.json"
            if verify:
                need(read_json(private_file(file)) == value, "rollback_state_changed")
            else:
                immutable(file, canonical(value))
    return {"rollback_allowed": True, "execution_started": False}


def entry(request, operator):
    action = request["action"]
    if action == "prepare":
        return prepare(request, operator)
    if action == "checkpoint-status":
        path = Path(request["after"]["controller"]["config"]).parent / "rollback-checkpoint.json"
        if path.exists():
            checkpoint(request, operator, verify=True)
            return {"checked": True}
        return {"checked": False}
    need(action in ("checkpoint", "rollback-check"), "invalid_update_action")
    return checkpoint(request, operator, verify=action == "rollback-check")
