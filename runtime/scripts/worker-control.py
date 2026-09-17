#!/usr/bin/env python3
"""SSH forced-command relay. Root/socket paths come only from installed configuration."""
import argparse
from pathlib import Path
import socket
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.common import private_dir, require
from symphony_runtime.guardian import MAX_BUNDLE, header, receive, send_bytes, send_header

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True)
args = parser.parse_args()
root = private_dir(args.root)
request = header(sys.stdin.buffer)
size = request.get("bundle_size", 0)
require(type(size) is int and 0 <= size <= MAX_BUNDLE, "invalid_body_size")
body = receive(sys.stdin.buffer, size)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(90)
    client.connect(str(root / "control.sock"))
    stream = client.makefile("rwb", buffering=0)
    send_header(stream, request)
    send_bytes(stream, body)
    response = header(stream)
    send_header(sys.stdout.buffer, response)
    send_bytes(sys.stdout.buffer, receive(stream, response.get("body_size", 0)))
