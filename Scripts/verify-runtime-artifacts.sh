#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")
ARTIFACT_DIR=${1:-"$ROOT_DIR/.build/runtime-release/$VERSION"}

[ -d "$ARTIFACT_DIR" ] && [ ! -L "$ARTIFACT_DIR" ] || {
    echo "runtime-artifacts: missing regular artifact directory" >&2
    exit 1
}
(
    cd "$ARTIFACT_DIR"
    shasum -a 256 -c SHA256SUMS >/dev/null
)

RUNTIME="$ARTIFACT_DIR/sonexis-runtime-$VERSION-macos-universal"
CTL="$ARTIFACT_DIR/sonexisctl-$VERSION-macos-universal"

for product in "$RUNTIME" "$CTL"; do
    [ -f "$product" ] && [ ! -L "$product" ] && [ -x "$product" ]
    codesign --verify --strict "$product"
    archs=$(lipo -archs "$product")
    case " $archs " in *' arm64 '*) ;; *) exit 1 ;; esac
    case " $archs " in *' x86_64 '*) ;; *) exit 1 ;; esac
done
[ "$("$RUNTIME" --version)" = "sonexis-runtime $VERSION (protocol 2)" ]
[ "$("$CTL" version)" = "sonexisctl $VERSION (protocol 2)" ]
codesign -dvv "$RUNTIME" 2>&1 | grep -F 'Identifier=com.sonexis.runtime' >/dev/null
codesign -dvv "$CTL" 2>&1 | grep -F 'Identifier=com.sonexis.ctl' >/dev/null
strings "$RUNTIME" | grep -F '<key>NSAudioCaptureUsageDescription</key>' >/dev/null

WHEEL=$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.whl' -print -quit)
SDIST=$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
NPM_PACKAGE=$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.tgz' -print -quit)
[ -n "$WHEEL" ] && [ -n "$SDIST" ] && [ -n "$NPM_PACKAGE" ]
unzip -l "$WHEEL" | grep -E 'LICENSE|py\.typed' >/dev/null
tar -tzf "$SDIST" | grep -E '/LICENSE$' >/dev/null
tar -tzf "$NPM_PACKAGE" | grep -E '^package/dist/index\.(js|d\.ts)$' >/dev/null

export ARTIFACT_DIR VERSION
/usr/bin/python3 - <<'PY'
import hashlib
import json
import os
import subprocess
from pathlib import Path

root = Path(os.environ["ARTIFACT_DIR"])
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
assert manifest["schema_version"] == 1
assert manifest["runtime_version"] == os.environ["VERSION"]
assert manifest["protocol_version"] == 2
assert manifest["platform"] == "macos"
assert manifest["minimum_macos"] == "14.4"
assert manifest["architectures"] == ["arm64", "x86_64"]
assert manifest["source_commit"] == subprocess.check_output(
    ["git", "rev-parse", "HEAD"], text=True).strip()
listed = {item["name"]: item for item in manifest["artifacts"]}
for name, item in listed.items():
    path = root / name
    assert path.is_file() and not path.is_symlink()
    assert path.stat().st_size == item["size_bytes"]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"]
expected = {p.name for p in root.iterdir() if p.is_file()} - {"manifest.json", "SHA256SUMS"}
assert set(listed) == expected
PY

echo "Sonexis Runtime $VERSION artifact manifest and checksums passed"
