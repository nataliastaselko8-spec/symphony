"""Create a portable, secret-free installer input from explicit accepted artifacts.

Run on the release maintainer's Linux/WSL checkout, not on each target computer.
The bundle directory is distributed through a trusted project channel.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def hash_file(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def create(args):
    source, profile = Path(args.symphony), Path(args.profile)
    for root, revision in ((source, args.symphony_commit), (profile, args.profile_revision)):
        require(re.fullmatch(r"[0-9a-f]{40}", revision), "full_commit_required")
        require(git(root, "rev-parse", "HEAD").decode().strip() == revision and
                not git(root, "status", "--porcelain"), "clean_accepted_checkout_required")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", args.worker_image), "image_id_required")
    lock = json.loads(git(profile, "show", args.profile_revision + ":worker/profile-lock.json"))
    require(lock["symphony_commit"] == args.symphony_commit and lock["runtime_contract"] == 2,
            "profile_runtime_pin_mismatch")
    for version in (args.erlang, args.elixir):
        require(re.fullmatch(r"[0-9]+\.[0-9][0-9A-Za-z.+-]{0,48}", version), "explicit_tool_version_required")
    destination = Path(args.output).absolute()
    require(not destination.exists(), "new_bundle_directory_required")
    for root in (source.resolve(), profile.resolve()):
        require(not destination.is_relative_to(root), "bundle_must_be_outside_source")
    destination.mkdir(mode=0o700, parents=True)
    assets = {}
    for name, original in (("rootfs", args.rootfs), ("mise", args.mise), ("worker_image", args.image_archive)):
        file = Path(original)
        require(file.is_file() and not file.is_symlink(), "regular_artifact_required")
        target = destination / (name + ".asset")
        shutil.copyfile(file, target)
        assets[name] = {"file": target.name, "sha256": hash_file(target), "size": target.stat().st_size}
    for name, root in (("symphony", source), ("profile", profile)):
        target = destination / (name + ".bundle")
        git(root, "bundle", "create", str(target), "HEAD")
        assets[name] = {"file": target.name, "sha256": hash_file(target), "size": target.stat().st_size}
    target = destination / "runtime.tar"
    with target.open("wb") as output:
        subprocess.run(["git", "-C", str(source), "archive", args.symphony_commit + ":runtime"], stdout=output, check=True)
    assets["runtime"] = {"file": target.name, "sha256": hash_file(target), "size": target.stat().st_size}
    # The same reviewed Windows/Linux installer is used on every computer.
    installer = {}
    for name in ("symphony.ps1", "setup.ps1", "support.ps1", "manager.ps1", "operator.ps1", "operator.py", "provision.py"):
        raw = git(source, "show", args.symphony_commit + ":tools/wsl/" + name)
        installer[name] = hashlib.sha256(raw.replace(b"\r\n", b"\n")).hexdigest()
    # Record the OCI/Docker archive's content hash; target Podman verifies the actual
    # image ID and profile labels after loading, before any task can run.
    manifest = {"schema_version": 1, "architecture": "x86_64", "runtime_contract": 2,
                "symphony_commit": args.symphony_commit, "profile_revision": args.profile_revision,
                "worker_image": args.worker_image, "toolchain": {"erlang": args.erlang, "elixir": args.elixir},
                "assets": assets, "installer": installer}
    (destination / "bundle.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {"bundle": str(destination / "bundle.json"), "sha256": hash_file(destination / "bundle.json")}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("symphony", "profile", "symphony-commit", "profile-revision", "rootfs", "mise",
                 "image-archive", "worker-image", "erlang", "elixir", "output"):
        parser.add_argument("--" + name, required=True)
    print(json.dumps(create(parser.parse_args())))
