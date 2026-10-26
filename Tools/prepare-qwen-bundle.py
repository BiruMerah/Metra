#!/usr/bin/env python3
"""Prepare the pinned Qwen bundle as regular files; no inference or download."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import uuid

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, help="Local checkpoint folder or pinned Hugging Face snapshot")
args = parser.parse_args()
manifest = json.loads((repo / "Integration/qwen-bundle-assets.json").read_text())
destination = repo / "Resources/Qwen3-VL-2B-4bit"

def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def matches(folder):
    return all((folder / row["file"]).is_file() and
               (folder / row["file"]).stat().st_size == row["bytes"] and
               sha256(folder / row["file"]) == row["sha256"] for row in manifest["files"])

if destination.is_dir() and matches(destination):
    (destination / "metra-bundle-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Bundled Qwen verified; no new copy required.")
    raise SystemExit(0)

candidates = [args.source] if args.source else [
    Path.home() / ".cache/huggingface/hub/models--mlx-community--Qwen3-VL-2B-Instruct-4bit/snapshots" / manifest["revision"],
    Path("/private/tmp/MetraQwenTransfer-build27/Qwen3-VL-2B-4bit"),
]
source = next((folder for folder in candidates if folder and (folder / "model.safetensors").is_file()), None)
if source is None:
    raise SystemExit("Local Qwen checkpoint not found. Run Tools/prepare-qwen-bundle.py --source /path/to/checkpoint before building.")
staging = destination.with_name(destination.name + ".partial-" + uuid.uuid4().hex)
staging.mkdir(parents=True)
try:
    for row in manifest["files"]:
        original = source / row["file"]
        if not original.is_file():
            raise SystemExit(f"Missing checkpoint file: {original}")
        target = staging / row["file"]
        shutil.copy2(original, target, follow_symlinks=True)
        if target.stat().st_size != row["bytes"] or sha256(target) != row["sha256"]:
            raise SystemExit(f"Pinned file hash/size mismatch: {original}")
    (staging / "metra-bundle-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # Existing bundle, if any, is retained until the complete new copy verifies.
    previous = destination.with_name(destination.name + ".previous-" + uuid.uuid4().hex)
    if destination.exists():
        destination.rename(previous)
    try:
        staging.rename(destination)
    except BaseException:
        if previous.exists(): previous.rename(destination)
        raise
    if previous.exists(): shutil.rmtree(previous)
finally:
    if staging.exists(): shutil.rmtree(staging)
print(f"Prepared {len(manifest['files'])} pinned files in {destination}; iPhone import is not required.")
