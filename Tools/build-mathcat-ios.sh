#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${1:-$repo_root/../Approach-Latest-Metra/tools/mathcat-build/source/mathcat-0.7.5}"
build_root="$repo_root/.build/mathcat-native"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$build_root/crate/src"

# Build this repository's bridge against an unchanged MathCAT 0.7.5 source tree.
# Staging resolves the legacy PoC dependency path without modifying that tree.
python3 - "$repo_root" "$source_dir" "$build_root/crate" <<'PY'
from pathlib import Path
import json
import re
import shutil
import sys

repo, source, staging = map(Path, sys.argv[1:])
source = source.resolve()
package = (source / "Cargo.toml").read_text().split("[package]", 1)[1].split("\n[", 1)[0]
if not (re.search(r'^name\s*=\s*"mathcat"\s*$', package, re.M)
        and re.search(r'^version\s*=\s*"0\.7\.5"\s*$', package, re.M)):
    raise SystemExit("Expected unchanged MathCAT 0.7.5 source")
bridge = repo / "Libraries/MathCATNative"
manifest = (bridge / "Cargo.toml").read_text()
old_path = 'path = "../../tools/mathcat-build/source/mathcat-0.7.5"'
if manifest.count(old_path) != 1:
    raise SystemExit("Unexpected MathCAT bridge dependency declaration")
(staging / "Cargo.toml").write_text(manifest.replace(old_path, "path = " + json.dumps(str(source))))
shutil.copy2(bridge / "Cargo.lock", staging / "Cargo.lock")
shutil.copy2(bridge / "src/lib.rs", staging / "src/lib.rs")
PY

cargo build --manifest-path "$build_root/crate/Cargo.toml" \
  --target-dir "$build_root/target" --locked --release --target aarch64-apple-ios
cp "$build_root/target/aarch64-apple-ios/release/libmetra_mathcat.a" \
  "$repo_root/Libraries/MathCATNative/lib/ios-arm64/libmetra_mathcat.a"
rustc --version > "$repo_root/Libraries/MathCATNative/rust-version.txt"
