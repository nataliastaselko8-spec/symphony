"""Bounded bootstrap operations, only inside a newly registered installer-owned distro.

Requests contain metadata only. Binary assets and credentials arrive on stdin.
No machine-specific path, UID, distro name or project identity is compiled in.
"""
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

MARKER = Path("/etc/symphony-installation.json")
STAGE = Path("/var/lib/symphony-installer")
WSL_CONFIG = Path("/etc/wsl.conf")


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def run(argv, *, user=None, cwd=None, env=None, timeout=1800, stdin=None, allowed=(0,)):
    environment = {"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C.UTF-8",
                   "DEBIAN_FRONTEND": "noninteractive"}
    if user:
        account = pwd.getpwnam(user)
        environment.update(HOME=account.pw_dir, XDG_RUNTIME_DIR="/run/user/" + str(account.pw_uid))
        argv = ["runuser", "-u", user, "--", *argv]
    environment.update(env or {})
    result = subprocess.run(argv, cwd=cwd, env=environment, stdin=stdin or subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    # apt/build errors can contain remote URLs; never print arbitrary stderr or request bodies.
    need(result.returncode in allowed, "command_failed_" + Path(argv[0]).name)
    return result.stdout.decode("utf-8", errors="replace").strip()


def write(path, raw, mode=0o600, owner=None, *, immutable=False):
    path = Path(path)
    need(not any(p.is_symlink() for p in (path, *path.parents)), "symlink_destination")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if immutable and path.exists():
        need(path.read_bytes() == raw, "existing_file_differs")
        info = path.stat()
        need(info.st_mode & 0o777 == mode and info.st_uid == (owner.pw_uid if owner else 0), "existing_file_permissions")
        return
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".pending-")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, mode)
        if owner:
            os.chown(temp, owner.pw_uid, owner.pw_gid)
        os.replace(temp, path)
        descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    finally:
        Path(temp).unlink(missing_ok=True)


def check_request(request):
    need(os.geteuid() == 0, "root_bootstrap_required")
    need(re.fullmatch(r"[0-9a-f]{32}", request["id"]), "installation_id_required")
    need(request["role"] in ("controller", "worker"), "invalid_role")
    return {"id": request["id"], "role": request["role"], "schema_version": 1}


def owned(request):
    expected = check_request(request)
    need(not MARKER.is_symlink() and json.loads(MARKER.read_text()) == expected and
         MARKER.stat().st_uid == 0 and MARKER.stat().st_mode & 0o022 == 0, "foreign_distribution")
    return "symphony" if expected["role"] == "controller" else "symphony-worker"


def claim(request):
    expected = check_request(request)
    write(MARKER, json.dumps(expected, sort_keys=True).encode(), immutable=True)
    user = owned(request)
    created = False
    try: pwd.getpwnam(user)
    except KeyError:
        run(["useradd", "--create-home", "--shell", "/bin/bash", user])
        created = True
    account = pwd.getpwnam(user)
    need(account.pw_uid != 0, "unprivileged_user_required")
    # Password auth is disabled on the only management sshd; an unlocked account
    # is necessary for public-key login on distributions using PAM.
    if created:
        run(["passwd", "-d", user])
    Path(account.pw_dir).chmod(0o700)
    text = "[boot]\nsystemd=true\n[automount]\nenabled=false\nmountFsTab=false\n[interop]\nenabled=false\nappendWindowsPath=false\n[user]\ndefault=" + user + "\n"
    old = WSL_CONFIG
    changed = not old.exists() or old.read_text() != text
    write(old, text.encode(), 0o644)
    return {"claimed": True, "restart_required": changed, "user": user}


def staging(request):
    path = STAGE / request["id"]
    if "release" in request:
        need(re.fullmatch(r"[0-9a-f]{24}", request["release"]), "invalid_release")
        path = path / "releases" / request["release"]
    return path


def host_path(request):
    staging(request)  # Validate the optional release before constructing any path.
    return Path("/etc/symphony/releases") / (request["release"] + ".json") if "release" in request else Path("/etc/symphony/host.json")


def asset(request):
    name = request["asset"]
    allowed = {"controller": {"mise", "symphony", "profile", "pem"}, "worker": {"runtime", "worker_image", "windows_canary"}}
    need(name in allowed[request["role"]], "asset_not_allowed_in_role")
    need(type(request["size"]) is int and 0 < request["size"] <= 32 * 1024**3 and
         re.fullmatch(r"[0-9a-f]{64}", request["sha256"]), "invalid_asset")
    need(name != "pem" or request["size"] <= 32768, "pem_too_large")
    need(name != "windows_canary" or request["size"] <= 2 * 1024**2, "canary_too_large")
    need("release" not in request or name != "pem", "update_preserves_credential")
    return staging(request) / name


def receive(request):
    owned(request)
    target = asset(request)
    need(not any(p.is_symlink() for p in (target, *target.parents)), "symlink_asset")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if target.exists():
        with target.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest == request["sha256"] and target.stat().st_size == request["size"]:
            # Drain input to avoid SIGPIPE in a resumed Windows binary transfer.
            while sys.stdin.buffer.read(1024 * 1024): pass
            return {"received": request["asset"], "reused": True}
        raise ValueError("existing_asset_differs")
    fd, temporary = tempfile.mkstemp(dir=target.parent, prefix=".receiving-")
    digest, size = hashlib.sha256(), 0
    try:
        with os.fdopen(fd, "wb") as stream:
            while block := sys.stdin.buffer.read(1024 * 1024):
                size += len(block)
                need(size <= request["size"], "asset_too_large")
                digest.update(block)
                stream.write(block)
            need(size == request["size"] and digest.hexdigest() == request["sha256"], "asset_checksum_mismatch")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        descriptor = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return {"received": request["asset"]}


def packages(request):
    user = owned(request)
    # WSL can return a root shell while systemd is still starting after import.
    for _ in range(60):
        if Path("/proc/1/comm").read_text().strip() == "systemd":
            break
        time.sleep(1)
    need(Path("/proc/1/comm").read_text().strip() == "systemd", "systemd_restart_required")
    common = ["ca-certificates", "python3", "git", "openssh-client", "curl", "openssl"]
    extra = (["build-essential", "autoconf", "m4", "libncurses-dev", "libssl-dev", "libreadline-dev", "zlib1g-dev"]
             if request["role"] == "controller" else
             ["podman", "passt", "uidmap", "openssh-server", "iptables", "util-linux", "dbus-user-session"])
    run(["apt-get", "update"])
    run(["apt-get", "install", "-y", "--no-install-recommends", *common, *extra])
    if request["role"] == "worker":
        run(["systemctl", "mask", "--now", "ssh.service", "ssh.socket"])
        for name, flag in (("subuid", "--add-subuids"), ("subgid", "--add-subgids")):
            rows = [line.split(":") for line in Path("/etc/" + name).read_text().splitlines() if line]
            if not any(row[0] == user and int(row[2]) >= 65536 for row in rows):
                start = max([100000, *(int(row[1]) + int(row[2]) for row in rows)])
                run(["usermod", flag, str(start) + "-" + str(start + 65535), user])
        run(["loginctl", "enable-linger", user])
        run(["systemctl", "start", "user@" + str(pwd.getpwnam(user).pw_uid) + ".service"])
    return {"packages_ready": True}


def clone(bundle, destination, commit, user):
    need(re.fullmatch(r"[0-9a-f]{40}", commit), "full_commit_required")
    if not destination.exists():
        # The root-owned bundle is opened by root; git receives it as a private
        # copy in the new account, never through a mounted Windows directory.
        local = destination.parent / (destination.name + ".bundle")
        account = pwd.getpwnam(user)
        shutil.copyfile(bundle, local)
        os.chown(local, account.pw_uid, account.pw_gid)
        local.chmod(0o600)
        # Checkout is part of clone. Never repair an interrupted/changed working
        # tree with reset --hard: it might contain work the operator retained.
        run(["git", "clone", str(local), str(destination)], user=user)
    # A completed clone already points at the exact bundle HEAD, even if Setup
    # was interrupted immediately before the detached checkout.
    need(run(["git", "-C", str(destination), "rev-parse", "HEAD"], user=user) == commit, "source_commit_mismatch")
    need(not run(["git", "-C", str(destination), "status", "--porcelain"], user=user), "source_not_clean")
    run(["git", "-C", str(destination), "checkout", "--detach", commit], user=user)


def controller(request):
    user = owned(request)
    need(request["role"] == "controller", "controller_required")
    account = pwd.getpwnam(user)
    home = Path(account.pw_dir)
    stage = staging(request)
    source_home = home
    if "release" in request:
        source_home = home / ".local/share/symphony/releases" / request["release"]
        run(["install", "-d", "-m", "700", str(source_home)], user=user)
    manifest = request["manifest"]
    for name, pin in (("symphony", "symphony_commit"), ("profile", "profile_revision")):
        clone(stage / name, source_home / name, manifest[pin], user)
    mise = source_home / ".local/bin/mise"
    run(["install", "-d", "-m", "700", str(mise.parent)], user=user)
    write(mise, (stage / "mise").read_bytes(), 0o700, account, immutable=True)
    for version in manifest["toolchain"].values():
        need(re.fullmatch(r"[0-9][0-9A-Za-z.+-]{1,50}", version), "invalid_toolchain")
    tools = [name + "@" + manifest["toolchain"][name] for name in ("erlang", "elixir")]
    build_controller(stage, source_home, user, mise, manifest, tools)
    ssh = home / ".ssh"
    run(["install", "-d", "-m", "700", str(ssh)], user=user)
    key = ssh / "management_ed25519"
    if not key.exists():
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], user=user)
    pub = " ".join(key.with_suffix(".pub").read_text().split()[:2])
    return {"controller_ready": True, "public_key": pub, "home": str(home), "source_home": str(source_home), "mise": str(mise)}


def controller_artifact(path, user):
    need(not any(p.is_symlink() for p in (path, *path.parents)), "unsafe_controller_artifact")
    need(path.is_file(), "controller_artifact_missing")
    info = path.stat()
    need(info.st_nlink == 1 and info.st_uid == pwd.getpwnam(user).pw_uid and
         info.st_mode & 0o111 and not info.st_mode & 0o022 and
         0 < info.st_size <= 256 * 1024**2, "unsafe_controller_artifact")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build_controller(stage, home, user, mise, manifest, tools):
    """Retain accepted build bytes across Setup retries; never silently repin them."""
    cwd = home / "symphony/elixir"
    artifact = cwd / "bin/symphony"
    receipt = stage / "controller-build.json"
    need(not any(p.is_symlink() for p in (receipt, *receipt.parents)), "unsafe_controller_build_receipt")
    inputs = {"schema_version": 1, "symphony_commit": manifest["symphony_commit"],
              "toolchain": manifest["toolchain"], "mise_sha256": hashlib.sha256(mise.read_bytes()).hexdigest()}
    if receipt.exists():
        info = receipt.stat()
        need(receipt.is_file() and info.st_nlink == 1 and info.st_uid == os.geteuid() and
             info.st_mode & 0o777 == 0o600 and info.st_size <= 4096, "unsafe_controller_build_receipt")
        try:
            saved = json.loads(receipt.read_text())
        except (ValueError, UnicodeError):
            raise ValueError("invalid_controller_build_receipt") from None
        need(isinstance(saved, dict) and set(saved) == set(inputs) | {"artifact_sha256"} and
             all(saved.get(key) == value for key, value in inputs.items()), "controller_build_inputs_changed")
        need(saved["artifact_sha256"] == controller_artifact(artifact, user), "controller_artifact_changed")
        return
    # A deployment manifest binds the exact executable. Losing its build receipt
    # must not trigger a rebuild, even if the source revision is unchanged.
    deployment = home / ".config/symphony/pilot/deployment.json"
    need(not deployment.exists() and not deployment.is_symlink(),
         "controller_build_receipt_missing_for_existing_manifest")
    environment = {"MISE_YES": "1", "MISE_TRUSTED_CONFIG_PATHS": str(cwd),
                   "KERL_CONFIGURE_OPTIONS": "--without-javac --without-wx"}
    run([str(mise), "install", *tools], user=user, cwd=cwd, env=environment, timeout=3600)
    run([str(mise), "exec", *tools, "--", "mix", "local.hex", "--force"], user=user, cwd=cwd, env=environment)
    run([str(mise), "exec", *tools, "--", "mix", "local.rebar", "--force"], user=user, cwd=cwd, env=environment)
    for action in ("setup", "build"):
        run([str(mise), "exec", *tools, "--", "mix", action], user=user, cwd=cwd, env=environment, timeout=1800)
    value = {**inputs, "artifact_sha256": controller_artifact(artifact, user)}
    write(receipt, json.dumps(value, sort_keys=True).encode(), immutable=True)


def extract_runtime(archive, destination):
    need(not any(p.is_symlink() for p in (destination, *destination.parents)), "symlink_destination")
    destination.mkdir(mode=0o755, parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        need(len(members) < 4096 and sum(item.size for item in members) <= 128 * 1024**2, "runtime_archive_too_large")
        seen = set()
        for item in members:
            name = PurePosixPath(item.name)
            need(name.parts and not name.is_absolute() and ".." not in name.parts and "\\" not in item.name and
                 (item.isdir() or item.isfile()) and item.size <= 16 * 1024**2, "unsafe_archive_member")
            need(str(name) not in seen, "duplicate_archive_member")
            seen.add(str(name))
        for item in members:
            target = destination / item.name
            need(not any(p.is_symlink() for p in (target, *target.parents)), "symlink_destination")
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            if item.isdir(): target.mkdir(mode=0o755, parents=True, exist_ok=True)
            else:
                write(target, source.extractfile(item).read(), 0o755 if item.mode & 0o111 else 0o644, immutable=True)


def worker(request):
    user = owned(request)
    need(request["role"] == "worker", "worker_required")
    manifest = request["manifest"]
    need(re.fullmatch(r"[0-9a-f]{40}", manifest["symphony_commit"]), "commit_required")
    stage = staging(request)
    package = Path("/opt/symphony-runtime") / manifest["symphony_commit"]
    extract_runtime(stage / "runtime", package)
    with (stage / "worker_image").open("rb") as image:
        run(["podman", "load"], user=user, stdin=image)
    inspection = json.loads(run(["podman", "image", "inspect", manifest["worker_image"]], user=user))[0]
    need(inspection["Id"].removeprefix("sha256:") == manifest["worker_image"].removeprefix("sha256:"), "worker_image_mismatch")
    labels = inspection.get("Labels") or inspection.get("Config", {}).get("Labels", {})
    need(labels.get("io.symphony.profile-revision") == manifest["profile_revision"] and
         labels.get("io.symphony.runtime-contract") == "2", "worker_profile_mismatch")
    home = Path(pwd.getpwnam(user).pw_dir)
    run(["install", "-d", "-m", "700", str(home / "state")], user=user)
    sys.path.insert(0, str(package / "lib"))
    from symphony_runtime.guardian import public_key
    port = request["port"]
    need(type(port) is int and 1024 <= port <= 65535, "invalid_port")
    host = {"package": str(package), "user": user, "image": manifest["worker_image"], "root": str(home / "state"),
            "name": "install-" + request["id"][:20], "management_port": port,
            "management_public_key": public_key(request["public_key"]).strip()}
    write(host_path(request), json.dumps(host, sort_keys=True).encode(), immutable=True)
    report = run(["python3", "-I", "-B", str(package / "scripts/host-preflight.py"), "--worker", user, "--image", manifest["worker_image"]], allowed=(0, 2))
    result = json.loads(report)
    require_preflight(result)
    return result


def require_preflight(result):
    if result.get("host_prerequisites_ready") is True:
        return
    # Only bounded machine codes, never arbitrary command output or secrets.
    failures = [row for row in result.get("checks", []) if row.get("status") == "NOT_READY"]
    reason = "host_preflight_not_ready"
    if failures:
        candidate = "host_preflight_" + str(failures[0].get("check", "")) + "_" + str(failures[0].get("reason", ""))
        if re.fullmatch(r"[a-zA-Z0-9_]{1,180}", candidate):
            reason = candidate
    raise ValueError(reason)


def smoke(request):
    owned(request)
    need(request["role"] == "worker", "worker_required")
    host = json.loads(host_path(request).read_text())
    output = run(["python3", "-I", "-B", host["package"] + "/tests/runtime_smoke.py", "--worker", host["user"],
         "--image", host["image"], "--package", host["package"],
         "--windows-canary", str(staging(request) / "windows_canary")], timeout=1200)
    report = {"isolation_smoke": "PASS", "execution_started": False, "image": host["image"],
              "package": host["package"], "checked_at": int(time.time()), "output": output[-131072:]}
    write(staging(request) / "smoke-report.json", json.dumps(report).encode())
    return report


def credential(request):
    user = owned(request)
    need(request["role"] == "controller", "controller_required")
    account = pwd.getpwnam(user)
    directory = Path(account.pw_dir) / ".config/symphony/github-app"
    run(["install", "-d", "-m", "700", str(directory)], user=user)
    staged = STAGE / request["id"] / "pem"
    run(["openssl", "pkey", "-in", str(staged), "-noout"])
    write(directory / "private-key.pem", staged.read_bytes(), owner=account, immutable=True)
    staged.unlink()
    return {"credential_imported": True}


def credential_status(request):
    user = owned(request)
    need(request["role"] == "controller", "controller_required")
    file = Path(pwd.getpwnam(user).pw_dir) / ".config/symphony/github-app/private-key.pem"
    need(not file.is_symlink(), "symlink_credential")
    return {"present": file.is_file() and file.stat().st_mode & 0o777 == 0o600 and
            file.stat().st_uid == pwd.getpwnam(user).pw_uid}


def dispatch(request):
    actions = {"claim": claim, "identity": lambda r: {"user": owned(r)}, "receive": receive,
               "packages": packages, "controller": controller, "worker": worker, "smoke": smoke,
               "credential": credential, "credential-status": credential_status}
    return actions[request["action"]](request)


if __name__ == "__main__":
    try:
        request = json.loads(base64.b64decode(sys.argv[2]))
        print(json.dumps(dispatch(request)))
    except Exception as error:
        reason = str(error) if type(error) is ValueError else "bootstrap_io_or_configuration_error"
        print(json.dumps({"error": reason}), file=sys.stderr)
        raise SystemExit(1)
