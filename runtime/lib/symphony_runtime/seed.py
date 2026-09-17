"""Read-only controller Git transport. Product code is never checked out here."""
import os
from pathlib import Path
import re
import tempfile

from .common import command, private_file, require, sha
from .guardian import MAX_BUNDLE


def create(directory, repo, expected, token, *, test_remote=None):
    sha(expected)
    require(isinstance(repo, str) and re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repo)
            and repo.split("/")[1] not in (".", ".."), "invalid_seed_repository")
    require(isinstance(token, str) and 0 < len(token) <= 8192 and not any(c in token for c in "\r\n\0"), "seed_credential_required")
    target = Path(directory) / "seed.bundle"
    if target.exists():
        return private_file(target).read_bytes()
    with tempfile.TemporaryDirectory(prefix="fetch-", dir=directory) as temporary:
        root = Path(temporary)
        askpass = root / "askpass"
        askpass.write_text('#!/bin/sh\ncase "$1" in *Username*) printf "%s\\n" x-access-token;; *) printf "%s\\n" "$SYMPHONY_SEED_TOKEN";; esac\n')
        askpass.chmod(0o700)
        env = {"HOME": str(root), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
               "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_ASKPASS": str(askpass), "SYMPHONY_SEED_TOKEN": token}
        prefix = ["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "protocol.allow=never",
                  "-c", "protocol.https.allow=always", "-c", "http.followRedirects=false"]
        if test_remote is not None:  # In-process tests only; not a wire/config field.
            prefix += ["-c", "protocol.file.allow=always"]
        def git(*args):
            return command(["prlimit", "--fsize=" + str(512 * 1024**2), "--as=" + str(2 * 1024**3), "--", *prefix, *args],
                           cwd=root, env=env, maximum=MAX_BUNDLE, timeout=45)
        git("init", "--bare", "repo.git")
        prefix += ["--git-dir=" + str(root / "repo.git")]
        remote = test_remote or "https://github.com/" + repo + ".git"
        git("fetch", "--no-tags", "--no-write-fetch-head", remote, "refs/heads/dev:refs/heads/dev")
        require(git("rev-parse", "refs/heads/dev^{commit}").decode().strip() == expected, "seed_dev_changed")
        git("fsck", "--strict", "--no-reflogs")
        git("bundle", "create", "seed.bundle", "refs/heads/dev")
        file = root / "seed.bundle"
        require(0 < file.stat().st_size <= MAX_BUNDLE, "seed_bundle_too_large")
        raw = file.read_bytes()
        from .common import atomic
        atomic(target, raw)
        return raw
