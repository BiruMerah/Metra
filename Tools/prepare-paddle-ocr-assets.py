#!/usr/bin/env python3
"""Prepare the pinned PaddleOCR ONNX file. No inference or model conversion."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import urllib.request
import uuid

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path)
parser.add_argument('--download', action='store_true')
args = parser.parse_args()
config = json.loads((repo / 'Resources/PaddleOCR-PP-OCRv5-mobile-rec.config.json').read_text())
destination = repo / 'Resources/PaddleOCR-PP-OCRv5-mobile-rec.onnx'

def valid(path):
    return path.is_file() and path.stat().st_size == config['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == config['sha256']

if valid(destination):
    print('Verified pinned PaddleOCR ONNX asset')
    raise SystemExit(0)
if not args.source and not args.download:
    raise SystemExit('Provide --source /path/to/inference.onnx or --download')
staging = destination.with_name(destination.name + '.partial-' + uuid.uuid4().hex)
try:
    if args.source:
        shutil.copy2(args.source, staging)
    else:
        url = f"https://huggingface.co/{config['modelID']}/resolve/{config['sourceRevision']}/inference.onnx"
        with urllib.request.urlopen(url, timeout=120) as response, staging.open('wb') as output:
            shutil.copyfileobj(response, output)
    if not valid(staging):
        raise SystemExit('Model size/SHA mismatch; existing asset retained')
    staging.replace(destination)
finally:
    staging.unlink(missing_ok=True)
print('Prepared pinned PaddleOCR ONNX asset')
