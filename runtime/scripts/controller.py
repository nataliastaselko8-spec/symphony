#!/usr/bin/env python3
"""Private framed controller helper; not installed as a worker command."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime import config
from symphony_runtime.controller import Controller
from symphony_runtime.guardian import header, send_header


def main():
    try:
        if len(sys.argv) != 3 or sys.argv[1] != "--config":
            raise ValueError("configuration_required")
        request = header(sys.stdin.buffer)
        result = Controller(config.load(sys.argv[2])).dispatch(request)
        send_header(sys.stdout.buffer, {"ok": result})
    except Exception:
        send_header(sys.stdout.buffer, {"error": "controller_operation_unconfirmed"})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
