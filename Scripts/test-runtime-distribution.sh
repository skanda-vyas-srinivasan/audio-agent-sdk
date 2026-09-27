#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCTS_DIR=${1:-"$ROOT_DIR/.build/RuntimeDevInstall/Build/Products/Debug"}
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sonexis-distribution-test.XXXXXX")
PREFIX="$TEST_DIR/Install With Spaces/dev"
STATE_DIR="$TEST_DIR/state"
RUNTIME_DIR="$TEST_DIR/socket"
cleanup() {
    if [ -d "$PREFIX" ]; then
        SONEXIS_DEV_PREFIX="$PREFIX" SONEXIS_RUNTIME_STATE_DIR="$STATE_DIR" \
            SONEXIS_RUNTIME_DIR="$RUNTIME_DIR" \
            "$ROOT_DIR/Scripts/runtime-dev.sh" stop >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

expect_failure() {
    if "$@" >"$TEST_DIR/expected-failure.log" 2>&1; then
        echo "Expected command to fail: $*" >&2
        exit 1
    fi
}

mkdir -p "$TEST_DIR/Install With Spaces"
touch "$TEST_DIR/Install With Spaces/unrelated-sentinel"

SONEXIS_DEV_PREFIX="$PREFIX" "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --prefix "$PREFIX" --products-dir "$PRODUCTS_DIR"
SONEXIS_DEV_PREFIX="$PREFIX" "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --prefix "$PREFIX" --products-dir "$PRODUCTS_DIR"
"$PREFIX/bin/sonexis-runtime" --help >/dev/null
"$PREFIX/bin/sonexis-runtime" --version | grep -F "$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")" >/dev/null
"$PREFIX/bin/sonexisctl" version | grep -F "$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")" >/dev/null
expect_failure "$PREFIX/bin/sonexis-runtime" --socket-dir relative
expect_failure "$PREFIX/bin/sonexisctl" frobnicate
grep -F 'Unknown command: frobnicate' "$TEST_DIR/expected-failure.log" >/dev/null
expect_failure "$PREFIX/bin/sonexisctl" sources unexpected
grep -F 'Usage:' "$TEST_DIR/expected-failure.log" >/dev/null

export SONEXIS_DEV_PREFIX="$PREFIX"
export SONEXIS_RUNTIME_STATE_DIR="$STATE_DIR"
export SONEXIS_RUNTIME_DIR="$RUNTIME_DIR"
UNSAFE_STATE_PARENT="$TEST_DIR/unsafe-state-parent"
mkdir "$UNSAFE_STATE_PARENT"
chmod 777 "$UNSAFE_STATE_PARENT"
expect_failure env SONEXIS_RUNTIME_STATE_DIR="$UNSAFE_STATE_PARENT/state" \
    "$ROOT_DIR/Scripts/runtime-dev.sh" start
"$ROOT_DIR/Scripts/runtime-dev.sh" start >/dev/null
[ "$(stat -f %Lp "$STATE_DIR")" = 700 ]
"$ROOT_DIR/Scripts/runtime-dev.sh" stop >/dev/null
rm -f "$STATE_DIR/runtime.log" "$STATE_DIR/runtime.log.previous"
touch "$TEST_DIR/log-target"
ln -s "$TEST_DIR/log-target" "$STATE_DIR/runtime.log"
expect_failure "$ROOT_DIR/Scripts/runtime-dev.sh" start
[ ! -s "$TEST_DIR/log-target" ]
rm "$STATE_DIR/runtime.log"
"$ROOT_DIR/Scripts/runtime-dev.sh" start >/dev/null
"$ROOT_DIR/Scripts/runtime-dev.sh" start | grep -F 'already running' >/dev/null
expect_failure "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --prefix "$PREFIX" --products-dir "$PRODUCTS_DIR"
"$ROOT_DIR/Scripts/runtime-dev.sh" status | grep -F 'managed pid' >/dev/null
"$PREFIX/bin/sonexisctl" status --socket "$RUNTIME_DIR/control.sock" >/dev/null
expect_failure env -u SONEXIS_RUNTIME_STATE_DIR -u SONEXIS_RUNTIME_DIR \
    "$ROOT_DIR/Scripts/uninstall-runtime-dev.sh" --prefix "$PREFIX"
[ -x "$PREFIX/bin/sonexis-runtime" ]
MANAGED_PID=$(sed -n '1p' "$STATE_DIR/runtime.pid")
kill -KILL "$MANAGED_PID"
ATTEMPTS=0
while kill -0 "$MANAGED_PID" 2>/dev/null && [ "$ATTEMPTS" -lt 50 ]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 0.1
done
"$ROOT_DIR/Scripts/runtime-dev.sh" start >/dev/null
"$ROOT_DIR/Scripts/runtime-dev.sh" status | grep -F 'managed pid' >/dev/null
"$ROOT_DIR/Scripts/runtime-dev.sh" stop >/dev/null
"$ROOT_DIR/Scripts/runtime-dev.sh" stop | grep -F 'not running' >/dev/null

touch "$PREFIX/unexpected-file"
expect_failure "$ROOT_DIR/Scripts/uninstall-runtime-dev.sh" --prefix "$PREFIX"
[ -f "$PREFIX/unexpected-file" ]
rm "$PREFIX/unexpected-file"
"$ROOT_DIR/Scripts/uninstall-runtime-dev.sh" --prefix "$PREFIX" >/dev/null
"$ROOT_DIR/Scripts/uninstall-runtime-dev.sh" --prefix "$PREFIX" >/dev/null
[ -f "$TEST_DIR/Install With Spaces/unrelated-sentinel" ]
[ ! -e "$PREFIX" ]

UNMANAGED="$TEST_DIR/unmanaged"
mkdir "$UNMANAGED"
touch "$UNMANAGED/sentinel"
expect_failure "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --prefix "$UNMANAGED" --products-dir "$PRODUCTS_DIR"
[ -f "$UNMANAGED/sentinel" ]

SYMLINK_TARGET="$TEST_DIR/symlink-target"
SYMLINK_PREFIX="$TEST_DIR/symlink-prefix"
mkdir "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_PREFIX"
expect_failure "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --prefix "$SYMLINK_PREFIX" --products-dir "$PRODUCTS_DIR"
[ -L "$SYMLINK_PREFIX" ]

UNSIGNED_PRODUCTS="$TEST_DIR/unsigned-products"
mkdir "$UNSIGNED_PRODUCTS"
cp "$PRODUCTS_DIR/sonexis-runtime" "$UNSIGNED_PRODUCTS/sonexis-runtime"
cp "$PRODUCTS_DIR/sonexisctl" "$UNSIGNED_PRODUCTS/sonexisctl"
codesign --remove-signature "$UNSIGNED_PRODUCTS/sonexis-runtime"
expect_failure "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --prefix "$TEST_DIR/unsigned-install" --products-dir "$UNSIGNED_PRODUCTS"

echo "Runtime development install/lifecycle/uninstall tests passed"
