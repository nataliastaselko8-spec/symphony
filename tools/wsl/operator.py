"""Operator convenience commands around an already installed, pinned runtime.

Transferred through stdin by symphony.ps1; never installed in the task container.
Only the existing root host supervisor and controller runtime execute workloads.
"""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time


class Refused(Exception):
    pass


def need(condition, reason):
    if not condition:
        raise Refused(reason)


def absolute(value):
    need(isinstance(value, str) and value.startswith("/") and
         all(ord(c) >= 32 for c in value) and not any(c in value for c in '\\"%'), "invalid_linux_path")
    path = Path(value)
    need(str(path) == value and ".." not in path.parts, "noncanonical_linux_path")
    return path


def validate(data):
    need(data.get("schema_version") == 1, "installation_version_required")
    for role in ("controller", "worker"):
        need(isinstance(data.get(role), dict), "installation_role_required")
        distro = data[role].get("distro")
        need(isinstance(distro, str) and distro and not distro.startswith("-") and
             all(ord(c) >= 32 for c in distro), "invalid_distro")
        absolute(data[role]["config"])
    need(re.fullmatch(r"[a-z_][a-z0-9_-]*", data["controller"]["user"]) is not None, "invalid_controller_user")
    absolute(data["controller"]["mise"])
    for value in data["ssh"].values():
        absolute(value)
    for name in ("symphony_commit", "profile_revision"):
        need(re.fullmatch(r"[0-9a-f]{40}", data["pins"][name]) is not None, "invalid_commit")
    need(re.fullmatch(r"sha256:[0-9a-f]{64}", data["pins"]["worker_image"]) is not None, "invalid_image")
    app = data["github_app"]
    need(all(isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9_]+", v) for v in app.values()) and
         set(app) == {"app_id", "client_id", "installation_id"}, "invalid_app_identifiers")
    config = data["runtime_config"]
    need(config.get("schema_version") == 2 and config.get("role") == "controller" and
         config.get("runtime_kind") == "wsl2-podman", "controller_configuration_required")
    for role in ("controller", "worker"):
        need(config.get(role + "_distro") == data[role]["distro"], "installation_distro_mismatch")
    need(config.get("controller_user") == data["controller"]["user"], "installation_user_mismatch")
    paths = [absolute(config[name]) for name in
             ("symphony_root", "project_template", "state_root", "workflow", "manifest", "ssh_config",
              "app_key", "operator_credential")]
    paths += [absolute(data["controller"]["config"]), absolute(data["ssh"]["identity"]),
              absolute(data["ssh"]["known_hosts"])]
    need(len(set(paths)) == len(paths), "installation_paths_overlap")
    return data


def run(args, timeout=45, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, **kwargs)
    need(result.returncode == 0, "command_failed_" + Path(args[0]).name)
    return result.stdout.strip()


def root_path(path):
    path = absolute(str(path))
    for entry in (path, *path.parents):
        info = entry.lstat()
        need(not entry.is_symlink() and info.st_uid == 0 and not info.st_mode & 0o022,
             "root_owned_configuration_required")
    return path


def host_configuration(data):
    need(os.geteuid() == 0, "root_host_action_required")
    file = root_path(data["worker"]["config"])
    host = json.loads(file.read_text())
    need(set(host) == {"package", "user", "image", "root", "name", "management_port", "management_public_key"},
         "invalid_host_configuration")
    need(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,40}", host["name"]) is not None, "invalid_host_name")
    need(host["image"] == data["pins"]["worker_image"], "host_image_mismatch")
    need(host["user"] == data["runtime_config"]["worker_user"], "host_user_mismatch")
    package = root_path(host["package"])
    for entry in package.rglob("*"):
        root_path(entry)
    need((package / "scripts/host.py").is_file(), "host_package_missing")
    identity = hashlib.sha256(str(file).encode()).hexdigest()[:24]
    return host, "symphony-host-" + identity + ".service", "Symphony operator " + identity


def unit_property(unit, prop):
    result = subprocess.run(["systemctl", "show", unit, "--property=" + prop, "--value"],
                            text=True, capture_output=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 else ""


def policy_directory(host):
    return Path("/run/symphony-runtime") / host["name"]


def host_info(data):
    host, unit, marker = host_configuration(data)
    sys.path.insert(0, str(Path(host["package"]) / "lib"))
    from symphony_runtime.config import package_digest
    from symphony_runtime.cgroups import service_group
    policy = policy_directory(host) / "network.json"
    result = {"host": host, "ready": False, "ownership": "absent", "unit": unit,
              "runtime_sha256": package_digest(Path(host["package"]))}
    if policy.exists():
        evidence = json.loads(root_path(policy).read_text())
        key = root_path(policy.parent / "management_host_key.pub").read_text().split()
        need(len(key) >= 2 and key[0] == "ssh-ed25519", "invalid_management_host_key")
        service = "symphony-" + host["name"]
        actual = service_group(unit_property(service + ".service", "ControlGroup"), service + ".service")
        need(evidence.get("image") == host["image"] and evidence.get("cgroup") == actual, "host_policy_scope_mismatch")
        need(evidence.get("boot_id") == Path("/proc/sys/kernel/random/boot_id").read_text().strip(), "stale_host_boot")
        ready = (evidence.get("ready") is True and
                 evidence["valid_until_monotonic"] > time.clock_gettime(time.CLOCK_BOOTTIME) and
                 unit_property(service + ".service", "ActiveState") == "active" and
                 unit_property(service + "-management.service", "ActiveState") == "active")
        result.update(ready=ready,
                      public_key=" ".join(key[:2]), ownership="external")
    if unit_property(unit, "ActiveState") in ("active", "activating", "deactivating"):
        need(unit_property(unit, "Description") == marker, "foreign_supervisor_unit")
        result["ownership"] = "managed"
    return result


def host_start(data):
    info = host_info(data)
    if info["ready"]:
        need(info["ownership"] == "managed", "external_supervisor_not_adopted")
        return info
    host, unit, marker = host_configuration(data)
    need(not policy_directory(host).exists(), "existing_host_scope_requires_review")
    need(info["ownership"] != "managed", "supervisor_not_ready")
    run(["systemd-run", "--unit=" + unit, "--collect", "--service-type=exec", "--description=" + marker,
         "--property=KillMode=mixed", "--property=TimeoutStopSec=120", "/usr/bin/python3", "-I", "-B",
         str(Path(host["package"]) / "scripts/host.py"), "--config", data["worker"]["config"]])
    for _ in range(40):
        time.sleep(0.5)
        try:
            info = host_info(data)
            if info["ready"]:
                return info
        except FileNotFoundError:
            pass  # The key and policy are published at different startup stages.
    raise Refused("supervisor_start_not_confirmed_check_journal")


def worker_status(host):
    sys.path.insert(0, str(Path(host["package"]) / "lib"))
    from symphony_runtime.guardian import header, send_header
    import socket
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(Path(host["root"]) / "control.sock"))
        with connection.makefile("rwb", buffering=0) as stream:
            send_header(stream, {"action": "status"})
            return header(stream).get("ok", {})


def host_stop(data):
    info = host_info(data)
    if info["ownership"] != "managed":
        return {"host_stopped": info["ownership"] == "absent", "ownership": info["ownership"]}
    host, unit, marker = host_configuration(data)
    proof = worker_status(host)
    need(proof.get("phase") in ("idle", "stopped", "exported"), "worker_not_stopped_keep_supervisor")
    run(["systemctl", "stop", unit], timeout=130)
    need(not policy_directory(host).exists(), "host_stop_not_confirmed")
    return {"host_stopped": True, "ownership": "managed"}


def runtime(data):
    need(os.geteuid() != 0, "controller_must_not_be_root")
    import pwd
    need(pwd.getpwuid(os.getuid()).pw_name == data["controller"]["user"], "controller_user_mismatch")
    root = absolute(data["runtime_config"]["symphony_root"])
    need(run(["git", "-C", str(root), "rev-parse", "HEAD"]) == data["pins"]["symphony_commit"], "runtime_commit_mismatch")
    need(not run(["git", "-C", str(root), "status", "--porcelain"]), "runtime_checkout_dirty")
    sys.path.insert(0, str(root / "runtime/lib"))
    from symphony_runtime import config, cli
    return config, cli


def stopped_locks(config):
    from contextlib import ExitStack
    from symphony_runtime.common import locked
    stack = ExitStack()
    try:
        for name in ("launcher.lock", "prepare.lock"):
            stack.enter_context(locked(Path(config["state_root"]) / name))
        return stack
    except BaseException:
        stack.close()
        raise


def sync_ssh(data, config, info):
    from symphony_runtime.common import atomic, private_file
    from symphony_runtime.guardian import public_key
    from symphony_runtime.config import package_digest
    need(info["ready"] and info["host"]["image"] == data["pins"]["worker_image"], "host_not_ready")
    need(info["runtime_sha256"] == package_digest(Path(config["symphony_root"]) / "runtime"), "host_runtime_mismatch")
    need(info["host"]["user"] == config["worker_user"], "host_user_mismatch")
    identity = private_file(data["ssh"]["identity"])
    pub = " ".join(identity.with_suffix(identity.suffix + ".pub").read_text().split()[:2])
    need(pub == info["host"]["management_public_key"], "management_identity_mismatch")
    key = public_key(info["public_key"])
    host = info["host"]
    port = host["management_port"]
    need(type(port) is int and 1024 <= port <= 65535 and
         re.fullmatch(r"[a-z_][a-z0-9_-]*", host["user"]), "invalid_management_endpoint")
    known = absolute(data["ssh"]["known_hosts"])
    atomic(known, ("[127.0.0.1]:" + str(port) + " " + key).encode())
    text = (f'Host {config["management_host"]}\n  HostName 127.0.0.1\n  Port {port}\n  User {host["user"]}\n'
            f'  IdentityFile "{identity}"\n  UserKnownHostsFile "{known}"\n'
            "  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes\n  IdentitiesOnly yes\n"
            "  BatchMode yes\n  ClearAllForwardings yes\n  ForwardAgent no\n  ForwardX11 no\n"
            "  RequestTTY no\n  ConnectTimeout 5\n")
    atomic(config["ssh_config"], text.encode())


def setup(data, info):
    settings, cli = runtime(data)
    from symphony_runtime.common import atomic, private_dir, private_file
    file = absolute(data["controller"]["config"])
    expected = settings.resolve(data["runtime_config"], file)
    need(expected["role"] == "controller", "controller_role_required")
    if file.exists():
        config = settings.load(file)
        need(config == expected, "existing_config_differs_choose_new_config_keep_state")
    else:
        config = settings.configure(file, data["runtime_config"])
    with stopped_locks(config):
        private_file(config["app_key"])
        credential = absolute(config["operator_credential"])
        need(not any((parent / ".git").exists() for parent in credential.parents), "credential_inside_repository")
        private_dir(credential.parent, create=True)
        if not credential.exists():
            atomic(credential, (secrets.token_urlsafe(32) + "\n").encode())
        token = private_file(credential).read_text().strip()
        need(re.fullmatch(r"[A-Za-z0-9_-]{43,128}", token) is not None and
             len(base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))) >= 32,
             "invalid_existing_operator_credential")
        sync_ssh(data, config, info)
        settings.render(config)
        settings.pin(config, data["pins"]["symphony_commit"], data["pins"]["profile_revision"],
                     data["pins"]["worker_image"], execute=True)
        cli.verify_source(config)
    return {"configured": True, "execution_started": False, "config": str(file),
            "dashboard": "http://localhost:" + str(config["dashboard_port"])}


def install_helper(request):
    data = request["installation"]
    runtime(data)
    from symphony_runtime.common import atomic, private_dir, private_file
    source = base64.b64decode(request["source"], validate=True)
    directory = private_dir(Path(data["controller"]["config"]).parent / "operator-helper" /
                            hashlib.sha256(source).hexdigest(), create=True)
    script = directory / "operator.py"
    if script.exists():
        need(private_file(script).read_bytes() == source, "installed_helper_changed")
    else:
        atomic(script, source)
    # Per-descriptor immutable file: another configuration never replaces a running command's inputs.
    raw = json.dumps(data, sort_keys=True).encode()
    installation = directory / (hashlib.sha256(raw).hexdigest() + ".json")
    if installation.exists():
        need(private_file(installation).read_bytes() == raw, "installation_changed")
    else:
        atomic(installation, raw)
    return {"script": str(script), "installation": str(installation)}


def pilot_source_idle(data, config):
    """Replay the existing store with its own scope; never reset uncertain work."""
    from symphony_runtime.common import private_file, read_json
    root = Path(config["state_root"])
    need(not (root / "worker.json").exists(), "pilot_source_has_worker_history")
    shutdown = root / "last_shutdown.json"
    need(shutdown.exists() and read_json(private_file(shutdown)).get("stopped") is True,
         "confirmed_stop_required_before_pilot")
    expression = r'''
    Logger.configure(level: :error)
    alias SymphonyElixir.{Config.Schema, Workflow}
    alias SymphonyElixir.DeliveryGate.{Settings, Snapshot, Store}
    {:ok, workflow} = Workflow.load(System.fetch_env!("SYMPHONY_PILOT_WORKFLOW"))
    {:ok, settings} = Schema.parse(workflow.config)
    {:ok, gate} = Settings.from_config(settings)
    {:ok, port} = Store.open(gate.path)
    result = try do
      case Store.request(port, %{"op" => "read"}) do
        {:ok, nil} -> true
        {:ok, snapshot} ->
          case Snapshot.decode(snapshot, gate.scope) do
            {:ok, verified} ->
              state = verified["state"]
              state["status"] in ["idle", "bootstrap_required"] and
                Enum.all?(~w(cycle last_cycle operator_pause environment_problem), &(state[&1] == nil))
            _ -> false
          end
        _ -> false
      end
    after
      Store.close(port)
    end
    IO.puts(Jason.encode!(%{pilot_source_idle: result}))
    '''
    env = os.environ.copy()
    env["SYMPHONY_PILOT_WORKFLOW"] = config["workflow"]
    for name, value in data["github_app"].items():
        env[{"app_id": "SYMPHONY_GITHUB_APP_ID", "client_id": "SYMPHONY_GITHUB_APP_CLIENT_ID",
             "installation_id": "SYMPHONY_GITHUB_INSTALLATION_ID"}[name]] = value
    env["SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH"] = config["app_key"]
    raw = run([data["controller"]["mise"], "exec", "--", "mix", "run", "--no-start", "--no-compile",
               "--no-deps-check", "-e", expression], cwd=Path(config["symphony_root"]) / "elixir", env=env, timeout=45)
    need(json.loads(raw).get("pilot_source_idle") is True, "pilot_source_requires_operator_recovery")


def pilot_candidate(report, config, settings, issue):
    provider = settings.workflow_settings(config)["tracker"]["provider"]
    need(report["project"]["repo"] == provider["repo"], "pilot_repository_mismatch")
    matches = [row for row in report["items"] if row.get("native_ref", {}).get("issue_number") == issue
               and row["native_ref"].get("repo") == provider["repo"]]
    need(len(matches) == 1, "pilot_issue_must_have_one_project_card")
    row = matches[0]
    need(not row["archived"] and row["issue_state"] == "OPEN" and row["state"] == provider["states"]["ready"]
         and row["native_ref"]["agent_allowed_option_id"] == report["schema"]["agent_allowed_option_id"]
         and not set(row["reasons"]) - {"outside_item_scope"}, "pilot_requires_ready_and_agent_allowed")
    need(re.fullmatch(r"PVTI_[A-Za-z0-9_-]{1,190}", row["item_id"]) is not None, "invalid_pilot_item_id")
    return row


def select_pilot(data, config, settings, cli, issue):
    """One initial pilot, new immutable profile; the previous store stays untouched."""
    from symphony_runtime import models
    from symphony_runtime.common import atomic, canonical, digest, private_dir, private_file, read_json
    need(type(issue) is int and 1 <= issue <= 2**31 - 1, "positive_issue_number_required")
    if config["pilot_item_ids"]:
        need(data.get("pilot", {}).get("issue") == issue and
             config["pilot_item_ids"] == [data["pilot"].get("item_id")], "pilot_already_selected")
        return {"installation": data, "selected": data["pilot"], "execution_started": False}
    with stopped_locks(config):
        pilot_source_idle(data, config)
        report = controller_action(data, "inspect", {})
        row = pilot_candidate(report, config, settings, issue)
        old_root = Path(config["state_root"])
        models.available(models.selected(old_root), models.catalog(old_root, data["pins"]["worker_image"]))
        identity = digest(canonical({"source": data["controller"]["config"], "repo": report["project"]["repo"],
                                     "item": row["item_id"]}))[:24]
        directory = private_dir(Path(data["controller"]["config"]).parent / ("pilot-" + identity), create=True)
        target = directory / "local.json"
        supplied = {**config, "pilot_item_ids": [row["item_id"]], "profile": "pilot-" + identity,
                    "state_root": str(old_root.parent / (old_root.name + "-" + identity)),
                    "workflow": str(directory / "WORKFLOW.md"), "manifest": str(directory / "deployment.json")}
        expected = settings.resolve(supplied, target)
        if target.exists():
            need(settings.load(target) == expected, "existing_pilot_profile_differs")
            proposed = expected
        else:
            proposed = settings.configure(target, supplied)
        with stopped_locks(proposed):
            new_root = Path(proposed["state_root"])
            need(not any((new_root / name).exists() for name in ("delivery.json", "delivery.json.lock", "worker.json", "launcher.json")),
                 "prepared_pilot_already_used")
            for name in ("model-selection.json", "model-catalog.json"):
                raw = private_file(old_root / name).read_bytes()
                output = new_root / name
                if output.exists():
                    need(private_file(output).read_bytes() == raw, "prepared_pilot_model_changed")
                else:
                    atomic(output, raw)
            settings.render(proposed)
            settings.pin(proposed, data["pins"]["symphony_commit"], data["pins"]["profile_revision"],
                         data["pins"]["worker_image"], execute=True)
            cli.verify_source(proposed)
        selected = {"issue": issue, "repo": report["project"]["repo"], "item_id": row["item_id"], "url": row["url"],
                    "source_config": data["controller"]["config"], "source_state_root": config["state_root"]}
        candidate = copy.deepcopy(data)
        candidate["controller"]["config"] = str(target)
        candidate["runtime_config"] = proposed
        candidate["pilot"] = selected
        return {"installation": candidate, "selected": selected, "execution_started": False}


def controller_action(data, action, options):
    settings, cli = runtime(data)
    from symphony_runtime.common import private_file
    config = settings.load(data["controller"]["config"])
    need(config == settings.resolve(data["runtime_config"], data["controller"]["config"]), "installation_config_mismatch")
    cli.verify_source(config)
    if action == "select-pilot":
        return select_pilot(data, config, settings, cli, options.get("issue"))
    if action == "stop":
        outcome = cli.stop_inspection(config)
        need(outcome.get("stopped") is True, "controller_stop_unconfirmed")
        # Absence of a launcher PID alone is not proof that the worker has stopped.
        from symphony_runtime.common import locked
        # recover() acquires prepare.lock itself for a retained task. Keep the
        # launcher locked, but only probe prepare.lock before calling recover.
        # This also refuses an in-flight orphaned prepare after its launcher died.
        with locked(Path(config["state_root"]) / "launcher.lock"):
            with locked(Path(config["state_root"]) / "prepare.lock"):
                pass
            proof = cli.confirm_shutdown(config)
            need(proof["stopped"], "worker_stop_unconfirmed")
        return proof
    if action == "status":
        return cli.status_report(config)
    if action == "sync":
        with stopped_locks(config):
            sync_ssh(data, config, options["host_info"])
        return {"ssh_ready": True}
    if action == "token":
        need(os.isatty(1), "local_terminal_required_for_token")
        print(private_file(config["operator_credential"]).read_text().strip())
        return None
    if action == "catalog":
        from symphony_runtime.models import catalog
        return {"models": catalog(Path(config["state_root"]), data["pins"]["worker_image"])}
    if action in ("start", "inspect"):
        need(action == "inspect" or not config["pilot_item_ids"] or options.get("execute") is True, "use_execute_for_selected_pilot")
        # Read-only mode has an empty exact item filter. Existing runtime admission remains authoritative.
        for name, value in data["github_app"].items():
            target = {"app_id": "SYMPHONY_GITHUB_APP_ID", "client_id": "SYMPHONY_GITHUB_APP_CLIENT_ID",
                      "installation_id": "SYMPHONY_GITHUB_INSTALLATION_ID"}[name]
            os.environ[target] = value
        root = Path(config["symphony_root"])
        erlang = run([data["controller"]["mise"], "where", "erlang"], cwd=root / "elixir")
        need(Path(erlang, "bin/escript").is_file(), "erlang_not_installed")
        os.environ["PATH"] = str(Path(erlang) / "bin") + ":/usr/local/bin:/usr/bin:/bin"
        if action == "inspect":
            os.environ["SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH"] = config["app_key"]
            return json.loads(run([str(root / "elixir/bin/symphony"), "--dry-run", config["workflow"]], timeout=180))
        options = {"supervised": True} if options.get("supervised") else {}
        raise SystemExit(cli.launch(config, execute=True, config_path=data["controller"]["config"], **options))
    if action == "check":
        return cli.preflight(config, execute=True)
    from symphony_runtime import maintenance
    if action in ("login", "models"):
        return maintenance.login(config, discover=action == "models")
    if action == "select-model":
        return maintenance.select_model(config, options["model"], options["effort"])
    raise Refused("unknown_controller_action")


def entry(request):
    try:
        data = validate(request["installation"])
        action = request["action"]
        if action in ("host-info", "host-start", "host-stop"):
            result = {"host-info": host_info, "host-start": host_start, "host-stop": host_stop}[action](data)
        elif action == "setup":
            result = setup(data, request["host_info"])
        elif action == "install-helper":
            result = install_helper(request)
        else:
            result = controller_action(data, action, request)
        if result is not None:
            print(json.dumps(result))
    except Exception as error:
        runtime_rejection = type(error).__module__ == "symphony_runtime.common" and type(error).__name__ == "Rejected"
        reason = str(error) if isinstance(error, Refused) or runtime_rejection else "operator_configuration_or_io_error"
        print(json.dumps({"error": reason}), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__" and len(sys.argv) > 1:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--installation", required=True)
    parser.add_argument("action", choices=("start", "stop", "status", "check", "login", "models", "select-model", "select-pilot", "token", "inspect", "catalog"))
    parser.add_argument("--issue", type=int)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--model")
    parser.add_argument("--effort")
    parser.add_argument("--supervised", action="store_true")
    arguments = parser.parse_args()
    entry({**vars(arguments), "installation": json.loads(Path(arguments.installation).read_text())})
