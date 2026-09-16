"""Private Linux file owner for DeliveryGate; framed JSON over a local stdio port.

No shell, network, workflow execution, or business transitions. Python's standard
library supplies flock and directory fsync, which are not provided by File.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile

MAX_BYTES = 16 * 1024 * 1024


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def safe_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
        raise ValueError("unsafe_file")


def read_bytes(path):
    try:
        safe_file(path)
        with path.open("rb") as source:
            value = source.read(MAX_BYTES + 1)
        if len(value) > MAX_BYTES:
            raise ValueError("snapshot_too_large")
        return value
    except FileNotFoundError:
        return None


def unpack(raw):
    if raw is None:
        return None
    envelope = json.loads(raw)
    if set(envelope) != {"digest", "snapshot"}:
        raise ValueError("invalid_envelope")
    if hashlib.sha256(encode(envelope["snapshot"])).hexdigest() != envelope["digest"]:
        raise ValueError("checksum_mismatch")
    return envelope["snapshot"]


def atomic_write(path, raw, directory_fd):
    if len(raw) > MAX_BYTES:
        raise ValueError("snapshot_too_large")
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".tmp-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as target:
            target.write(raw)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        os.fsync(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Store:
    def __init__(self, filename):
        self.path = Path(filename)
        if not self.path.is_absolute() or str(self.path) != os.path.abspath(filename) or str(self.path).startswith("/mnt/"):
            raise ValueError("invalid_path")
        for ancestor in [self.path.parent, *self.path.parent.parents]:
            if ancestor.is_symlink():
                raise ValueError("symlink_directory")
            if (ancestor / ".git").exists():
                raise ValueError("store_inside_checkout")
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.path.parent.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("unsafe_directory")
        self.directory_fd = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
        lock_path = self.path.with_name(self.path.name + ".lock")
        self.lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        safe_file(lock_path)
        fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.backup = self.path.with_name(self.path.name + ".previous")
        self.expected = read_bytes(self.path)
        self.trusted = False

    def read(self):
        self.trusted = False
        self.expected = read_bytes(self.path)
        if self.expected is None and os.fstat(self.lock_fd).st_size:
            raise ValueError("previously_initialized_store_missing")
        value = unpack(self.expected)
        self.trusted = True
        return value

    def backup_read(self):
        return unpack(read_bytes(self.backup))

    def write(self, snapshot, restore=False):
        if read_bytes(self.path) != self.expected:
            raise ValueError("external_change")
        if not self.trusted and not restore:
            raise ValueError("recovery_required")
        if self.expected is not None and not restore:
            atomic_write(self.backup, self.expected, self.directory_fd)
        if restore and self.expected is not None:
            # Preserve the damaged/current file for investigation; never replace
            # the known-good backup with the damaged input.
            quarantine = self.path.with_name(self.path.name + ".quarantine-" + os.urandom(8).hex())
            atomic_write(quarantine, self.expected, self.directory_fd)
        payload = encode({"digest": hashlib.sha256(encode(snapshot)).hexdigest(), "snapshot": snapshot})
        os.pwrite(self.lock_fd, b"initialized\n", 0)
        os.fsync(self.lock_fd)
        os.fsync(self.directory_fd)
        atomic_write(self.path, payload, self.directory_fd)
        self.expected = payload
        self.trusted = True


def send(value):
    encoded = encode(value)
    sys.stdout.buffer.write(struct.pack("!I", len(encoded)) + encoded)
    sys.stdout.buffer.flush()


def receive():
    header = sys.stdin.buffer.read(4)
    if not header:
        return None
    if len(header) != 4:
        raise ValueError("truncated_frame")
    length = struct.unpack("!I", header)[0]
    if length > MAX_BYTES:
        raise ValueError("frame_too_large")
    data = sys.stdin.buffer.read(length)
    if len(data) != length:
        raise ValueError("truncated_frame")
    return json.loads(data)


def main():
    try:
        store = Store(sys.argv[1])
    except (OSError, ValueError):
        send({"error": "store_open_failed"})
        return
    send({"ok": True})
    while True:
        request = receive()
        if request is None:
            return
        try:
            operation = request["op"]
            if operation == "read":
                result = store.read()
            elif operation == "backup":
                result = store.backup_read()
            elif operation in ("write", "restore"):
                store.write(request["snapshot"], restore=operation == "restore")
                result = True
            else:
                raise ValueError("unknown_operation")
            send({"ok": result})
        except (OSError, ValueError, KeyError, TypeError):
            send({"error": "store_operation_failed"})


if __name__ == "__main__":
    main()
