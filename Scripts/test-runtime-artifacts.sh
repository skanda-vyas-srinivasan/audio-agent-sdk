#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CURRENT_VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")
SOURCE=${1:-"$ROOT_DIR/.build/runtime-release/$CURRENT_VERSION"}
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sonexis-artifact-test.XXXXXX")
cleanup() {
    if [ -d "$TEST_DIR" ] && [ ! -L "$TEST_DIR" ]; then
        case "$TEST_DIR" in
            */sonexis-artifact-test.*) rm -rf "$TEST_DIR" ;;
            *) echo "artifact-test: refusing unsafe cleanup: $TEST_DIR" >&2 ;;
        esac
    fi
}
trap cleanup EXIT HUP INT TERM

expect_failure() {
    if "$@" >"$TEST_DIR/expected-failure.log" 2>&1; then
        echo "Expected command to reject modified artifacts: $*" >&2
        exit 1
    fi
}

"$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$SOURCE" >/dev/null
VERSION=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["runtime_version"])' \
    "$SOURCE/manifest.json")
TEAM=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["signing"]["team_identifier"])' \
    "$SOURCE/manifest.json")
COMMIT=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' \
    "$SOURCE/manifest.json")
SONEXIS_EXPECTED_TEAM_ID="$TEAM" SONEXIS_EXPECTED_SOURCE_COMMIT="$COMMIT" \
    "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$SOURCE" >/dev/null
expect_failure env SONEXIS_EXPECTED_TEAM_ID=AAAAAAAAAA \
    "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$SOURCE"
expect_failure env SONEXIS_EXPECTED_SOURCE_COMMIT=0000000000000000000000000000000000000000 \
    "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$SOURCE"

copy_fixture() {
    [ ! -L "$TEST_DIR/candidate" ] || {
        echo "artifact-test: refusing symlink candidate cleanup" >&2
        exit 1
    }
    rm -rf "$TEST_DIR/candidate"
    mkdir "$TEST_DIR/candidate"
    cp "$SOURCE"/* "$TEST_DIR/candidate/"
}

# Payload tampering must fail the manifest digest before a package is unpacked.
copy_fixture
printf '\000' >>"$TEST_DIR/candidate/sonexis-runtime-$VERSION.tgz"
expect_failure "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$TEST_DIR/candidate"

# An exact inventory prevents unsigned/unreviewed files from riding beside a
# valid release bundle.
copy_fixture
touch "$TEST_DIR/candidate/unexpected"
expect_failure "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$TEST_DIR/candidate"

# A fully renamed bundle with a rewritten manifest and matching checksum file
# still cannot lie about the signed binaries' embedded version.
copy_fixture
export CANDIDATE="$TEST_DIR/candidate"
export VERSION
/usr/bin/python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["CANDIDATE"])
old_version = os.environ["VERSION"]
new_version = "9.9.9"
manifest_path = root / "manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["runtime_version"] = new_version
for item in manifest["artifacts"]:
    old_name = item["name"]
    new_name = old_name.replace(old_version, new_version)
    (root / old_name).rename(root / new_name)
    item["name"] = new_name
manifest_path.write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
checksums = {}
for line in (root / "SHA256SUMS").read_text(encoding="ascii").splitlines():
    digest, name = line.split("  ", 1)
    checksums[name.replace(old_version, new_version)] = digest
checksums["manifest.json"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
(root / "SHA256SUMS").write_text(
    "".join(f"{checksums[name]}  {name}\n" for name in sorted(checksums)),
    encoding="ascii",
)
PY
expect_failure "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$TEST_DIR/candidate"

# Symlinks are rejected even when their target is a byte-for-byte valid package.
copy_fixture
PACKAGE="$TEST_DIR/candidate/sonexis-runtime-$VERSION.tgz"
mv "$PACKAGE" "$TEST_DIR/package-target.tgz"
ln -s "$TEST_DIR/package-target.tgz" "$PACKAGE"
expect_failure "$ROOT_DIR/Scripts/verify-runtime-artifacts.sh" "$TEST_DIR/candidate"

echo "Runtime artifact tamper, inventory, manifest, and symlink rejection tests passed"
