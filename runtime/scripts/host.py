#!/usr/bin/env python3
"""Explicit privileged host setup; run only from an inspected, root-owned Linux copy."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.host import main
from symphony_runtime.common import Rejected
try:
    main()
except (Rejected, OSError) as error:
    raise SystemExit(str(error) if isinstance(error, Rejected) else "host_runtime_io_error")
