"""Runs ONLY in an uncredentialed, network-disabled transfer container."""
import os
from pathlib import Path
import re
import resource
import subprocess
import sys

LIMIT = 80 * 1024 * 1024
resource.setrlimit(resource.RLIMIT_FSIZE, (LIMIT, LIMIT))
resource.setrlimit(resource.RLIMIT_CPU, (35, 35))
ENV = {"PATH": "/usr/bin:/bin", "HOME": "/tmp", "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
       "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0"}


def git(*args, cwd="/workspace/repo"):
    return subprocess.check_output(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
                                    "-c", "core.fsmonitor=false", "-c", "protocol.allow=never", "-c", "protocol.file.allow=always", *args],
                                   cwd=cwd, env=ENV, stderr=subprocess.DEVNULL, timeout=40).decode().strip()


def repository():
    path = Path("/workspace/repo")
    assert path.is_dir() and not path.is_symlink()
    assert (path / ".git").is_dir() and not (path / ".git").is_symlink()
    assert not (path / ".git/objects/info/alternates").exists()
    assert not (path / ".git/info/grafts").exists()
    return path


def main():
    action, expected, branch = sys.argv[1:]
    assert re.fullmatch(r"[0-9a-f]{40}", expected)
    assert re.fullmatch(r"agent/[A-Za-z0-9_/-]+", branch) and "//" not in branch
    if action == "seed":
        assert git("bundle", "list-heads", "/input/seed.bundle", cwd="/tmp") == expected + " refs/heads/dev"
        if not Path("/workspace/repo").exists():
            git("clone", "--no-checkout", "--no-hardlinks", "--single-branch", "--branch", "dev", "/input/seed.bundle", "repo", cwd="/workspace")
            repository()
            git("fsck", "--strict")
            git("checkout", "--detach", expected)
            # The project hook (PR-12) owns branch creation and continuation policy.
        else:
            repository()
            git("fetch", "--no-tags", "--no-write-fetch-head", "/input/seed.bundle", "refs/heads/dev:refs/remotes/origin/dev")
            git("fsck", "--strict")
    elif action == "export":
        repository()
        assert git("rev-parse", "--verify", "refs/heads/" + branch) == expected
        git("fsck", "--strict", "--no-reflogs")
        git("bundle", "create", "/output/candidate.bundle", "refs/heads/" + branch)
        assert git("bundle", "list-heads", "/output/candidate.bundle") == expected + " refs/heads/" + branch
    else:
        raise ValueError("invalid transfer action")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("git_transfer_rejected", file=sys.stderr)
        raise SystemExit(1)
