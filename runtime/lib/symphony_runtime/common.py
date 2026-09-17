"""Small, bounded I/O primitives shared by the trusted runtime helpers."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


class Rejected(Exception):
    """A configuration or operation was rejected without disclosing secrets."""


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def lease_clock():
    import time
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}", value), "invalid_identifier")
    return value


def sha(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value), "invalid_commit")
    return value


def read_json(path, maximum=1024 * 1024):
    with Path(path).open("rb") as source:
        raw = source.read(maximum + 1)
    require(len(raw) <= maximum, "json_too_large")
    return parse_json(raw)


def parse_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate_json_key")
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=pairs)
    except (ValueError, UnicodeError) as exc:
        raise Rejected("invalid_json") from exc


def no_links(path):
    path = Path(os.path.abspath(path))
    for part in [*reversed(path.parents), path]:
        require(not part.is_symlink(), "symlink_path")
    return path


def private_dir(path, create=False):
    path = no_links(path)
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    require(stat.S_ISDIR(info.st_mode), "directory_required")
    if os.name == "posix":
        require(info.st_uid == os.getuid() and info.st_mode & 0o077 == 0, "private_directory_required")
    return path


def private_file(path):
    path = no_links(path)
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "regular_file_required")
    if os.name == "posix":
        require(info.st_uid == os.getuid() and info.st_mode & 0o077 == 0, "private_file_required")
    return path


def atomic(path, data):
    path = no_links(path)
    parent = private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=parent)
    try:
        with os.fdopen(fd, "wb") as target:
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        if os.name == "posix":
            descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def locked(path):
    require(os.name == "posix", "linux_lock_required")
    import fcntl
    path = no_links(path)
    private_dir(path.parent)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid(), "unsafe_lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Rejected("already_running") from exc
        yield
    finally:
        os.close(descriptor)


def command(argv, *, cwd=None, timeout=30, input_data=None, maximum=1024 * 1024, env=None, error_file=None):
    """Never inherit controller credentials or evaluate shell fragments."""
    base = {"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C.UTF-8"}
    if env:
        base.update(env)
    import time
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(argv, cwd=cwd, env=base, stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                                   stdout=output, stderr=errors, start_new_session=True)
        deadline = time.monotonic() + timeout
        pending = input_data
        try:
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0, "command_timeout")
                require(os.fstat(output.fileno()).st_size <= maximum and os.fstat(errors.fileno()).st_size <= 1024 * 1024, "command_output_too_large")
                try:
                    process.communicate(pending, timeout=min(0.1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    pending = None  # communicate retains its partially written input between calls.
        except Rejected:
            if os.name == "posix":
                import signal
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait()
            raise
        output.seek(0)
        raw = output.read(maximum + 1)
        if process.returncode != 0 and error_file:
            errors.seek(0)
            atomic(error_file, errors.read(16384))
    require(len(raw) <= maximum, "command_output_too_large")
    require(process.returncode == 0, "command_failed_" + Path(str(argv[0])).name)
    return raw
