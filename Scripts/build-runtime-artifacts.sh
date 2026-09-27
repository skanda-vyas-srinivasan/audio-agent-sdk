#!/bin/sh
set -eu
export PIP_DISABLE_PIP_VERSION_CHECK=1

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCTS_DIR=${1:-"$ROOT_DIR/.build/RuntimeRelease/Build/Products/Release"}
OUTPUT_PARENT=${2:-"$ROOT_DIR/.build/runtime-release"}
VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")
DESTINATION="$OUTPUT_PARENT/$VERSION"

cd "$ROOT_DIR"
[ -z "$(git status --porcelain --untracked-files=all)" ] || {
    echo "runtime-artifacts: source tree must be clean" >&2
    exit 1
}
"$ROOT_DIR/Scripts/check-runtime-version.py"
"$ROOT_DIR/Scripts/verify-runtime-release-products.sh" "$PRODUCTS_DIR"
[ ! -e "$DESTINATION" ] || {
    echo "runtime-artifacts: destination already exists: $DESTINATION" >&2
    exit 1
}

mkdir -p "$OUTPUT_PARENT"
STAGING=$(mktemp -d "$OUTPUT_PARENT/.runtime-$VERSION.XXXXXX")
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT HUP INT TERM

copy_tracked_tree() {
    source_prefix=$1
    destination=$2
    mkdir "$destination"
    git ls-files "$source_prefix" | while IFS= read -r path; do
        relative=${path#"$source_prefix/"}
        mkdir -p "$destination/$(dirname -- "$relative")"
        cp "$ROOT_DIR/$path" "$destination/$relative"
    done
}

cp "$PRODUCTS_DIR/sonexis-runtime" \
    "$STAGING/sonexis-runtime-$VERSION-macos-universal"
cp "$PRODUCTS_DIR/sonexisctl" \
    "$STAGING/sonexisctl-$VERSION-macos-universal"

copy_tracked_tree SDKs/python "$STAGING/python-src"
(
    cd "$STAGING/python-src"
    /usr/bin/python3 setup.py sdist --dist-dir "$STAGING" >/dev/null
    /usr/bin/python3 -m pip wheel --no-deps --no-build-isolation \
        --wheel-dir "$STAGING" . >/dev/null
)

copy_tracked_tree SDKs/typescript "$STAGING/typescript-src"
(
    cd "$STAGING/typescript-src"
    npm ci --ignore-scripts >/dev/null
    npm test >/dev/null
    npm pack --pack-destination "$STAGING" >/dev/null
)

rm -rf "$STAGING/python-src" "$STAGING/typescript-src"
COMMIT=$(git rev-parse HEAD)
TEAM=$(codesign -dvv "$PRODUCTS_DIR/sonexis-runtime" 2>&1 | sed -n 's/^TeamIdentifier=//p')
export STAGING VERSION COMMIT TEAM
/usr/bin/python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["STAGING"])
names = sorted(p.name for p in root.iterdir() if p.is_file())
artifacts = []
for name in names:
    path = root / name
    artifacts.append({
        "name": name,
        "size_bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    })
manifest = {
    "schema_version": 1,
    "runtime_version": os.environ["VERSION"],
    "protocol_version": 2,
    "source_commit": os.environ["COMMIT"],
    "platform": "macos",
    "minimum_macos": "14.4",
    "architectures": ["arm64", "x86_64"],
    "signing": {
        "kind": "Apple Development",
        "team_identifier": os.environ["TEAM"],
        "runtime_identifier": "com.sonexis.runtime",
        "cli_identifier": "com.sonexis.ctl",
        "notarized": False,
    },
    "artifacts": artifacts,
}
(root / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

(
    cd "$STAGING"
    for artifact in *; do
        [ "$artifact" = SHA256SUMS ] || shasum -a 256 "$artifact"
    done >SHA256SUMS
)
mv "$STAGING" "$DESTINATION"
trap - EXIT HUP INT TERM
"$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$DESTINATION"
echo "Created Sonexis Runtime $VERSION artifacts at $DESTINATION"
