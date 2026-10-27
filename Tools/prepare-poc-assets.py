#!/usr/bin/env python3
"""Prepare pinned ONNX assets; diagrams use the on-device Apple system model. This script performs no inference."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import uuid

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=repo.parent / "Approach-Latest-Metra",
                    help="PoC root containing MetraPipelinePoC/Resources")
parser.add_argument("--mfd-source", type=Path, help="Optional local pinned Pix2Text-MFD ONNX file")
args = parser.parse_args()

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

manifest = json.loads((repo / "Integration/poc-assets.json").read_text())
for asset in manifest["files"]:
    destination = repo / asset["destination"]
    if destination.is_file() and sha256(destination) == asset["sha256"]:
        print(f"Verified {asset['destination']}")
        continue
    source = args.source / asset["source"]
    if not source.is_file():
        raise SystemExit(f"Missing prepared model: {source}. Supply --source pointing to the preserved PoC assets.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = destination.with_name(destination.name + ".partial-" + uuid.uuid4().hex)
    try:
        shutil.copy2(source, staging)
        if staging.stat().st_size != asset["bytes"] or sha256(staging) != asset["sha256"]:
            raise SystemExit(f"Hash/size mismatch: {source}; existing model was not replaced.")
        staging.replace(destination)
    finally:
        staging.unlink(missing_ok=True)
    print(f"Prepared {asset['destination']}")
command = [sys.executable, str(repo / "Tools/prepare-mfd-assets.py")]
if args.mfd_source:
    command += ["--source", str(args.mfd_source)]
subprocess.run(command, check=True)
print("Pinned ONNX assets ready; Foundation Models are managed by iOS, with no app-bundled VLM.")
