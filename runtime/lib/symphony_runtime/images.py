"""Remove only installation-owned image tags; never prune shared Podman storage."""
import json
import os
import time

from .common import atomic, canonical, digest, private_file, read_json, require


def namespace(root):
    return "localhost/symphony-" + digest((str(os.getuid()) + ":" + str(root)).encode())[:20] + ":"


def register(root, image, pod):
    file = root / "images.json"
    records = read_json(private_file(file)) if file.exists() else {}
    tag = namespace(root) + image.removeprefix("sha256:")
    if tag not in records:
        pod("tag", image, tag)
        records[tag] = {"image": image, "registered_at": time.time()}
        atomic(file, canonical(records))


def collect_images(root, current, pod, retention_days=7, *, dry_run=True, now=None):
    file = root / "images.json"
    if not file.exists():
        return []
    records = read_json(private_file(file))
    now = time.time() if now is None else now
    removed = []
    for tag, value in list(records.items()):
        require(tag == namespace(root) + value["image"].removeprefix("sha256:"), "foreign_image_tag")
        if value["image"] == current or now - value["registered_at"] < retention_days * 86400:
            continue
        info = json.loads(pod("image", "inspect", tag))[0]
        require(info["Id"].removeprefix("sha256:") == value["image"].removeprefix("sha256:"), "image_tag_changed")
        # Merely using a shared image does not grant ownership of its bytes.
        # Untagging is safe while another tag remains; last-tag removal additionally
        # requires a build-time installation label.
        labels = info.get("Labels") or (info.get("Config") or {}).get("Labels") or {}
        tags = info.get("RepoTags") or []
        owned_tags = [candidate for candidate in tags if candidate.startswith(namespace(root))]
        require(tag in owned_tags, "image_tag_missing")
        if len(tags) == len(owned_tags) and labels.get("io.symphony.installation") != namespace(root).removesuffix(":"):
            continue
        # Any container referencing this image keeps it. No force, image ID deletion or global prune.
        if json.loads(pod("ps", "--all", "--filter", "ancestor=" + tag, "--format=json")):
            continue
        removed.append(tag)
        if not dry_run:
            pod("image", "rm", "--no-prune", *owned_tags)
            del records[tag]
            atomic(file, canonical(records))
    return removed
