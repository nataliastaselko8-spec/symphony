"""Controller-only Git bundle publication. One framed request; never execute worker code."""
import hashlib
import json
import os
import re
import resource
import signal
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

MAX_BUNDLE = 80 * 1024 * 1024


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024**2, 512 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (30, 30))


def require(condition):
    if not condition:
        raise ValueError("publication rejected")


def git(args, root, extra=None, codes=(0,)):
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "LANG": "C.UTF-8",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1"}
    env.update(extra or {})
    command = ["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
               "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
               "-c", "http.followRedirects=false", "-c", "core.attributesFile=/dev/null", *args]
    with tempfile.TemporaryFile() as output_file:
        process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                   stdout=output_file, stderr=subprocess.DEVNULL,
                                   start_new_session=True, preexec_fn=limits)
        try:
            process.wait(timeout=45)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        output_file.seek(0)
        output = output_file.read(MAX_BUNDLE + 1)
        require(process.returncode in codes and len(output) <= MAX_BUNDLE)
        return output


def trusted_path(value):
    path = Path(value)
    require(path.is_absolute() and str(path) == str(path.resolve()) and not str(path).startswith("/mnt/"))
    for parent in [path, *path.parents]:
        info = parent.lstat()
        require(not stat.S_ISLNK(info.st_mode))
    return path


def publish(request, test_remote=None):
    require(sys.platform == "linux" and isinstance(request, dict))
    require(set(request) == {"bundle", "sha", "base_sha", "previous_sha", "branch", "repo", "token", "send", "digest"})
    sha, base, branch = request["sha"], request["base_sha"], request["branch"]
    require(all(isinstance(s, str) and re.fullmatch(r"[0-9a-f]{40}", s) for s in [sha, base]))
    previous = request["previous_sha"]
    require(previous is None or isinstance(previous, str) and re.fullmatch(r"[0-9a-f]{40}", previous))
    require(isinstance(branch, str) and re.fullmatch(r"agent/[A-Za-z0-9_/-]+", branch) and "//" not in branch and not branch.endswith("/"))
    require(isinstance(request["repo"], str) and re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", request["repo"]))
    require(request["repo"].split("/")[1] not in (".", ".."))
    require(isinstance(request["send"], bool))
    source = trusted_path(request["bundle"])
    info = source.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and info.st_mode & 0o022 == 0)
    require(0 < info.st_size <= MAX_BUNDLE and source.parent.stat().st_mode & 0o077 == 0)
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        data = stream.read(MAX_BUNDLE + 1)
    require(len(data) <= MAX_BUNDLE)
    digest = hashlib.sha256(data).hexdigest()
    require(request["digest"] in (None, digest))
    with tempfile.TemporaryDirectory(prefix="symphony-publish-") as temp:
        root = Path(temp)
        bundle = root / "candidate.bundle"
        bundle.write_bytes(data)
        git(["init", "--bare", "repo.git"], root)
        prefix = ["--git-dir=" + str(root / "repo.git")]
        refs = git([*prefix, "bundle", "list-heads", str(bundle)], root).decode().splitlines()
        require(refs == [sha + " refs/heads/" + branch])
        git([*prefix, "bundle", "verify", str(bundle)], root)
        git(["-c", "protocol.file.allow=always", *prefix, "fetch", "--no-tags", "--no-write-fetch-head", str(bundle), "refs/heads/" + branch + ":refs/heads/candidate"], root)
        git([*prefix, "fsck", "--strict", "--no-reflogs"], root)
        require(git([*prefix, "rev-parse", sha + "^{commit}"], root).strip().decode() == sha)
        git([*prefix, "merge-base", "--is-ancestor", base, sha], root)
        if previous:
            git([*prefix, "merge-base", "--is-ancestor", previous, sha], root)
        paths = git([*prefix, "diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", base, sha, "--"], root).split(b"\0")
        require(all(not (p == b".github" or p.startswith(b".github/") or p in (b".gitmodules", b".lfsconfig")) for p in paths))
        tree = git([*prefix, "ls-tree", "-r", "-z", sha], root).split(b"\0")
        require(len(tree) <= 100_000 and all(not p.startswith(b"160000 ") for p in tree))
        pointers = git([*prefix, "grep", "-l", "-F", "version https://git-lfs.github.com/spec/v1", sha, "--"], root, codes=(0, 1))
        require(not pointers)
        result = {"sha": sha, "digest": digest}
        if not request["send"]:
            return result
        # Test-only injection is a Python function argument, never part of the wire request.
        remote = test_remote or "https://github.com/" + request["repo"] + ".git"
        auth = {}
        extra = []
        if test_remote:
            extra = ["-c", "protocol.file.allow=always"]
        else:
            require(isinstance(request["token"], str) and request["token"] and not any(c in request["token"] for c in "\r\n\x00"))
            askpass = root / "askpass"
            askpass.write_text('#!/bin/sh\ncase "$1" in *Username*) printf "%s\\n" x-access-token;; *) printf "%s\\n" "$SYMPHONY_PUSH_TOKEN";; esac\n')
            askpass.chmod(0o700)
            auth = {"GIT_ASKPASS": str(askpass), "SYMPHONY_PUSH_TOKEN": request["token"]}
        ref = "refs/heads/" + branch
        before = git([*extra, *prefix, "ls-remote", "--refs", remote, ref], root, auth).decode().strip()
        if before == sha + "\t" + ref:
            return result
        expected = "" if previous is None else previous + "\t" + ref
        require(before == expected)
        # This is our own hook, in a fresh controller repository. It pins the old
        # value advertised by receive-pack, including a concurrent ref change
        # after ls-remote. Git's normal non-force push still enforces ancestry.
        hooks = root / "hooks"
        hooks.mkdir(mode=0o700)
        hook = hooks / "pre-push"
        hook.write_text('#!/bin/sh\ncount=0\nwhile read -r local_ref local_sha remote_ref remote_sha; do\n'
                        '  test "$remote_ref" = "$SYMPHONY_REF" && test "$remote_sha" = "$SYMPHONY_OLD" || exit 1\n'
                        '  count=$((count + 1))\ndone\ntest "$count" = 1\n')
        hook.chmod(0o700)
        auth.update({"SYMPHONY_REF": ref, "SYMPHONY_OLD": previous or "0" * 40})
        git([*extra, "-c", "core.hooksPath=" + str(hooks), *prefix, "push", "--porcelain", remote, sha + ":" + ref], root, auth)
        after = git([*extra, *prefix, "ls-remote", "--refs", remote, ref], root, auth).decode().strip()
        require(after == sha + "\t" + ref)
        return result


def main():
    try:
        size = struct.unpack(">I", sys.stdin.buffer.read(4))[0]
        require(size <= 32_768)
        request = json.loads(sys.stdin.buffer.read(size))
        result = {"ok": publish(request)}
    except Exception:
        result = {"error": "git_publication_unconfirmed"}
    raw = json.dumps(result).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(raw)) + raw)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
