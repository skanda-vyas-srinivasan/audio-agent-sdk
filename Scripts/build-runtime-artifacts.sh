#!/bin/sh
set -eu
export PIP_DISABLE_PIP_VERSION_CHECK=1

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PRODUCTS_DIR=${1:-"$ROOT_DIR/.build/RuntimeRelease/Build/Products/Release"}
OUTPUT_PARENT=${2:-"$ROOT_DIR/.build/runtime-release"}
VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")

error() {
    echo "runtime-artifacts: $*" >&2
    exit 1
}

cd "$ROOT_DIR"
[ -z "$(git status --porcelain --untracked-files=all)" ] || \
    error "source tree must be clean"
SOURCE_COMMIT=$(git rev-parse HEAD)
"$ROOT_DIR/Scripts/check-runtime-version.py"

[ -d "$PRODUCTS_DIR" ] && [ ! -L "$PRODUCTS_DIR" ] || \
    error "products path is not a regular directory: $PRODUCTS_DIR"
PRODUCTS_DIR=$(CDPATH= cd -- "$PRODUCTS_DIR" && pwd -P)
"$ROOT_DIR/Scripts/verify-runtime-release-products.sh" "$PRODUCTS_DIR"

mkdir -p "$OUTPUT_PARENT"
[ -d "$OUTPUT_PARENT" ] && [ ! -L "$OUTPUT_PARENT" ] || \
    error "output parent is not a regular directory: $OUTPUT_PARENT"
OUTPUT_PARENT=$(CDPATH= cd -- "$OUTPUT_PARENT" && pwd -P)
[ "$(stat -f '%u' "$OUTPUT_PARENT")" = "$(id -u)" ] || \
    error "output parent is not owned by the current user: $OUTPUT_PARENT"
OUTPUT_MODE=$(stat -f '%Lp' "$OUTPUT_PARENT")
case "$OUTPUT_MODE" in
    *[2367][0-7]|*[0-7][2367])
        error "output parent must not be group- or world-writable: $OUTPUT_PARENT"
        ;;
esac

DESTINATION="$OUTPUT_PARENT/$VERSION"
LOCK="$OUTPUT_PARENT/.runtime-$VERSION.lock"
[ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || \
    error "destination already exists: $DESTINATION"
mkdir "$LOCK" 2>/dev/null || \
    error "another artifact build is active for Runtime $VERSION"

STAGING=
cleanup() {
    if [ -n "$STAGING" ] && [ -d "$STAGING" ] && [ ! -L "$STAGING" ]; then
        case "$STAGING" in
            "$OUTPUT_PARENT"/.runtime-"$VERSION".*) rm -rf "$STAGING" ;;
            *) echo "runtime-artifacts: refusing unsafe staging cleanup: $STAGING" >&2 ;;
        esac
    fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

umask 077
STAGING=$(mktemp -d "$OUTPUT_PARENT/.runtime-$VERSION.XXXXXX")

copy_tracked_tree() {
    source_prefix=$1
    destination=$2
    mkdir "$destination"
    git ls-files "$source_prefix" | while IFS= read -r path; do
        relative=${path#"$source_prefix/"}
        [ "$relative" != "$path" ] || error "unexpected tracked path: $path"
        [ -f "$ROOT_DIR/$path" ] && [ ! -L "$ROOT_DIR/$path" ] || \
            error "package source is not a regular file: $path"
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

RUNTIME_NAME="sonexis-runtime-$VERSION-macos-universal"
CTL_NAME="sonexisctl-$VERSION-macos-universal"
WHEEL_NAME="sonexis-$VERSION-py3-none-any.whl"
SDIST_NAME="sonexis-$VERSION.tar.gz"
NPM_NAME="sonexis-runtime-$VERSION.tgz"
for artifact in "$RUNTIME_NAME" "$CTL_NAME" "$WHEEL_NAME" "$SDIST_NAME" "$NPM_NAME"; do
    [ -f "$STAGING/$artifact" ] && [ ! -L "$STAGING/$artifact" ] || \
        error "expected artifact was not produced: $artifact"
done
[ "$(find "$STAGING" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 5 ] || \
    error "package build produced an unexpected top-level artifact"

[ -z "$(git status --porcelain --untracked-files=all)" ] || \
    error "source tree changed while artifacts were being built"
[ "$(git rev-parse HEAD)" = "$SOURCE_COMMIT" ] || \
    error "source commit changed while artifacts were being built"
COMMIT=$SOURCE_COMMIT
TEAM=$(codesign -dvv "$PRODUCTS_DIR/sonexis-runtime" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ -n "$TEAM" ] || error "signed Runtime has no TeamIdentifier"
export STAGING VERSION COMMIT TEAM
/usr/bin/python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["STAGING"])
names = sorted(path.name for path in root.iterdir() if path.is_file())
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
    for artifact in "$CTL_NAME" "$NPM_NAME" "$RUNTIME_NAME" \
        "$WHEEL_NAME" "$SDIST_NAME" manifest.json; do
        shasum -a 256 "$artifact"
    done >SHA256SUMS
)
chmod 755 "$STAGING" "$STAGING/$RUNTIME_NAME" "$STAGING/$CTL_NAME"
chmod 644 "$STAGING/$WHEEL_NAME" "$STAGING/$SDIST_NAME" \
    "$STAGING/$NPM_NAME" "$STAGING/manifest.json" "$STAGING/SHA256SUMS"
MANIFEST_SHA256=$(shasum -a 256 "$STAGING/manifest.json" | awk '{print $1}')

[ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || \
    error "destination appeared during build: $DESTINATION"
SONEXIS_EXPECTED_TEAM_ID="$TEAM" SONEXIS_EXPECTED_SOURCE_COMMIT="$COMMIT" \
    SONEXIS_EXPECTED_MANIFEST_SHA256="$MANIFEST_SHA256" \
    "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$STAGING"
mv "$STAGING" "$DESTINATION"
STAGING=
echo "Created Sonexis Runtime $VERSION artifacts at $DESTINATION"
