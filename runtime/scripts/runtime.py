#!/usr/bin/env python3
"""Trusted entry point; package lookup is relative to this installation."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
