#!/usr/bin/env python3
"""Entry point for the dedicated, delegated host service; never run as root."""
import argparse
from pathlib import Path
import signal
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.guardian import Guardian, serve

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True)
parser.add_argument("--image", required=True)
parser.add_argument("--cgroup", required=True)
parser.add_argument("--policy", required=True)
args = parser.parse_args()
event = threading.Event()
for number in (signal.SIGINT, signal.SIGTERM):
    signal.signal(number, lambda *_: event.set())
deadline = time.monotonic() + 30
while not Path(args.policy).exists() and not event.is_set():
    if time.monotonic() >= deadline:
        raise SystemExit("network_policy_missing")
    time.sleep(0.05)
if not event.is_set():
    serve(Guardian(args.root, args.image, args.cgroup, args.policy), event)
