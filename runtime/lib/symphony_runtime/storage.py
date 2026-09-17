"""Installation-scoped storage. Only successfully retired cycles become collectible."""
import os
from pathlib import Path
import shutil
import time

from .common import atomic, canonical, digest, identifier, no_links, private_dir, private_file, read_json, require

GIB = 1024**3


def capacity(path, minimum=5 * GIB, warning=10 * GIB):
    require(type(minimum) is int and type(warning) is int and 0 < minimum <= warning, "invalid_disk_thresholds")
    free = shutil.disk_usage(path).free
    return {"free_bytes": free, "minimum_bytes": minimum, "warning_bytes": warning,
            "status": "blocked" if free < minimum else "warning" if free < warning else "ready"}


def bounded_log(path, data, maximum=2 * 1024**2, copies=3):
    """Append bounded diagnostics; never redirect an unlimited child output here."""
    path = no_links(path)
    private_dir(path.parent)
    if path.exists():
        private_file(path)
    if path.exists() and path.stat().st_size + len(data) > maximum:
        for index in range(copies, 0, -1):
            previous = path if index == 1 else path.with_name(path.name + "." + str(index - 1))
            target = path.with_name(path.name + "." + str(index))
            if previous.exists():
                private_file(previous)
                if target.exists():
                    private_file(target)
                os.replace(previous, target)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "ab") as stream:
        stream.write(data[-maximum:])


def retire(root, cycle, report, now=None, retention_days=7):
    """The caller is the trusted controller; worker task text cannot invoke this."""
    identifier(cycle)
    require(isinstance(report, dict) and report.get("outcome") == "completed" and report.get("cycle") == cycle,
            "successful_cycle_required")
    raw = canonical(report)
    require(len(raw) <= 16384, "retirement_report_too_large")
    reports = private_dir(Path(root) / "reports", create=True)
    target = reports / (cycle + ".json")
    require(type(retention_days) is int and 1 <= retention_days <= 3650, "invalid_retention")
    value = {"report": report, "sha256": digest(raw), "completed_at": time.time() if now is None else now, "retention_days": retention_days}
    if target.exists():
        old = read_json(private_file(target))
        require(old["report"] == report and old["sha256"] == value["sha256"], "retirement_changed")
        return old
    atomic(target, canonical(value))
    return value


def collect(root, *, active_cycle=None, retention_days=7, now=None, dry_run=True, categories=("workspaces", "codex", "cycles")):
    require(type(retention_days) is int and 1 <= retention_days <= 3650, "invalid_retention")
    root = private_dir(root)
    require(not root.is_relative_to("/mnt") and root != Path.home(), "dedicated_linux_storage_required")
    reports = root / "reports"
    if not reports.exists():
        return []
    private_dir(reports)
    now = time.time() if now is None else now
    removed = []
    for file in sorted(reports.glob("*.json")):
        cycle = identifier(file.stem)
        value = read_json(private_file(file))
        report = value.get("report", {})
        require(report.get("cycle") == cycle and report.get("outcome") == "completed" and digest(canonical(report)) == value.get("sha256"), "invalid_retirement_report")
        completed = value.get("completed_at")
        require(type(completed) in (int, float) and completed > 0, "invalid_retirement_time")
        recorded_retention = value.get("retention_days", 7)
        require(type(recorded_retention) is int and 1 <= recorded_retention <= 3650, "invalid_retention")
        if cycle == active_cycle or now - completed < max(retention_days, recorded_retention) * 86400:
            continue
        for category in categories:
            require(category in ("workspaces", "codex", "cycles", "keys", "seeds", "exports", "attempts"), "invalid_storage_category")
            parent = no_links(root / category)
            if not parent.exists():
                continue
            private_dir(parent)
            names = [cycle] if category in ("workspaces", "codex", "cycles") else report.get("generations", [])
            require(isinstance(names, list) and len(names) <= 1000, "invalid_generation_list")
            for name in names:
                identifier(name)
                path = no_links(parent / name)
                require(path.parent == parent and path.is_relative_to(root), "cleanup_path_escape")
                if not path.exists():
                    continue
                private_dir(path)
                removed.append(category + "/" + name)
                if not dry_run:
                    require(shutil.rmtree.avoids_symlink_attacks, "safe_tree_removal_required")
                    shutil.rmtree(path)
    return removed
