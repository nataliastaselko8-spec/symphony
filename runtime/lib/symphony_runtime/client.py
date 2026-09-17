"""Controller transport. SSH destination is installed configuration, never model input."""
import io
from pathlib import Path
import subprocess

from .common import atomic, canonical, digest, identifier, private_dir, private_file, require
from .guardian import MAX_BUNDLE, header, receive, send_header


def exchange(ssh_config, destination, request, body=b""):
    identifier(destination)
    private_file(ssh_config)
    request_stream = io.BytesIO()
    send_header(request_stream, request)
    request_stream.write(body)
    args = ["ssh", "-F", str(ssh_config), "-T", "-oBatchMode=yes", "-oIdentitiesOnly=yes", "-oStrictHostKeyChecking=yes",
            "-oClearAllForwardings=yes", "-oConnectTimeout=5", destination]
    # stdout is capped in a temporary file; neither logs nor argv contain a bundle or token.
    from .common import command
    raw = command(args, input_data=request_stream.getvalue(), maximum=MAX_BUNDLE + 16388, timeout=90)
    stream = io.BytesIO(raw)
    response = header(stream)
    require("error" not in response and "ok" in response, "worker_transport_rejected")
    data = receive(stream, response.get("body_size", 0))
    require(stream.read(1) == b"", "trailing_transport_data")
    return response["ok"], data


def accept_export(directory, generation, proof, raw):
    identifier(generation)
    root = private_dir(directory)
    require(not root.is_relative_to("/mnt"), "linux_export_directory_required")
    require(0 < len(raw) <= MAX_BUNDLE and proof["size"] == len(raw) and proof["sha256"] == digest(raw), "export_transport_digest_mismatch")
    target = root / (generation + ".bundle")
    if target.exists():
        require(private_file(target).read_bytes() == raw, "existing_export_differs")
    else:
        atomic(target, raw)
    return str(target)
