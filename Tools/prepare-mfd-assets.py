#!/usr/bin/env python3
"""Copy or explicitly download the pinned MFD ONNX asset; no inference."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import urllib.request
import uuid

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, help='Existing local MFD ONNX file')
parser.add_argument('--download', action='store_true', help='Download the exact pinned official HF revision')
args = parser.parse_args()
config = json.loads((repo / 'Resources/Pix2Text-MFD.config.json').read_text())
destination = repo / 'Resources/Pix2Text-MFD.onnx'

def valid(path):
    if not path.is_file() or path.stat().st_size != config['bytes']:
        return False
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest() == config['sha256']

if valid(destination):
    print('Verified Resources/Pix2Text-MFD.onnx')
    raise SystemExit(0)
if not args.source and not args.download:
    raise SystemExit('MFD asset missing/invalid. Run python3 Tools/prepare-mfd-assets.py --source /path/to/mfd.onnx or --download.')
staging = destination.with_name(destination.name + '.partial-' + uuid.uuid4().hex)
try:
    if args.source:
        shutil.copy2(args.source, staging)
    else:
        url = f"https://huggingface.co/{config['modelID']}/resolve/{config['sourceRevision']}/{config['sourceFile']}"
        with urllib.request.urlopen(url, timeout=120) as response, staging.open('wb') as output:
            shutil.copyfileobj(response, output)
    if not valid(staging):
        raise SystemExit('MFD hash/size mismatch; existing asset retained.')
    staging.replace(destination)
finally:
    staging.unlink(missing_ok=True)
print('Prepared pinned Resources/Pix2Text-MFD.onnx')
