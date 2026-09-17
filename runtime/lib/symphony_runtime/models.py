"""Operator selection and immutable cycle pins; no implicit model or effort defaults."""
import time

from .common import Rejected, atomic, canonical, identifier, private_dir, private_file, read_json, require


def pair(value):
    require(isinstance(value, dict) and set(value) == {"model", "effort"}, "model_selection_required")
    for key in ("model", "effort"):
        text = value[key]
        require(isinstance(text, str) and 0 < len(text) <= 200 and text.strip() == text
                and all(32 < ord(c) < 127 for c in text), "invalid_model_selection")
    return value


def normalize(data):
    require(isinstance(data, list) and 0 < len(data) <= 2000, "invalid_model_catalog")
    result = []
    for item in data:
        require(isinstance(item, dict), "invalid_model_catalog")
        if item.get("hidden") is True:
            continue
        efforts = item.get("supportedReasoningEfforts")
        require(isinstance(efforts, list) and len(efforts) <= 20, "invalid_model_catalog")
        values = [pair({"model": item.get("model"), "effort": e.get("reasoningEffort")})["effort"] for e in efforts if isinstance(e, dict)]
        require(len(values) == len(efforts) and len(values) == len(set(values)), "invalid_model_catalog")
        if values:
            result.append({"model": item["model"], "efforts": values})
    require(result and len({item["model"] for item in result}) == len(result), "ambiguous_model_catalog")
    return result


def catalog(root, image):
    path = root / "model-catalog.json"
    require(path.exists(), "model_catalog_required")
    value = read_json(private_file(path))
    require(value.get("image") == image and type(value.get("queried_at")) is int
            and 0 <= int(time.time()) - value["queried_at"] <= 86400, "model_catalog_refresh_required")
    return value["models"]


def available(selection, models):
    pair(selection)
    item = next((item for item in models if item["model"] == selection["model"]), None)
    require(item is not None, "selected_model_unavailable")
    require(selection["effort"] in item["efforts"], "selected_effort_unavailable")
    return selection


def selected(root):
    file = root / "model-selection.json"
    require(file.exists(), "model_selection_required")
    return pair(read_json(private_file(file)))


def ready(root, image):
    choice = None
    try:
        choice = selected(root)
        available(choice, catalog(root, image))
        return {"selected": choice, "reasons": []}
    except (Rejected, ValueError, OSError, KeyError, TypeError) as exc:
        return {"selected": choice, "reasons": [str(exc) if isinstance(exc, Rejected) else "model_selection_unreadable"]}


def bind(root, cycle, repo, image):
    choice = available(selected(root), catalog(root, image))
    path = private_dir(root / "execution-profiles", create=True) / (identifier(cycle) + ".json")
    value = {"cycle": cycle, "repo": repo, "selection": choice}
    if path.exists():
        require(read_json(private_file(path)) == value, "cycle_model_selection_changed")
    else:
        atomic(path, canonical(value))
    return choice


def bound(root, cycle, repo):
    value = read_json(private_file(root / "execution-profiles" / (identifier(cycle) + ".json")))
    require(value.get("cycle") == cycle and value.get("repo") == repo, "model_cycle_mismatch")
    choice = pair(value["selection"])
    require(choice == selected(root), "cycle_model_selection_changed")
    return choice


def applied(root, cycle, interval, repo, actual):
    choice = bound(root, cycle, repo)
    require(pair(actual) == choice, "model_application_mismatch")
    path = private_dir(root / "model-receipts", create=True) / (identifier(interval) + ".json")
    value = {"cycle": cycle, "interval": interval, "selection": choice}
    if path.exists():
        require(read_json(private_file(path)) == value, "model_application_changed")
    else:
        atomic(path, canonical(value))
    return choice
