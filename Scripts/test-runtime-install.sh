#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PRODUCTS="$ROOT_DIR/.build/signed-dev/bin"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sonexis-install-test.XXXXXX")
PREFIX="$TEST_ROOT/install"
STATE="$TEST_ROOT/state"
SOCKETS="$TEST_ROOT/sockets"
cleanup() {
    find "$TEST_ROOT" -type f -delete 2>/dev/null || true
    find "$TEST_ROOT" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
chmod 700 "$TEST_ROOT"

SONEXIS_DEV_PREFIX="$PREFIX" "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --products-dir "$PRODUCTS"

# Replacement must preserve a managed directory if any foreign file appears.
touch "$PREFIX/user-file"
if SONEXIS_DEV_PREFIX="$PREFIX" "$ROOT_DIR/Scripts/install-runtime-dev.sh" \
    --products-dir "$PRODUCTS" >/dev/null 2>&1; then
    echo "installer replaced a modified managed directory" >&2
    exit 1
fi
[ -f "$PREFIX/user-file" ]
rm "$PREFIX/user-file"

# Uninstall must preserve modified managed binaries rather than deleting them.
printf '\0' >> "$PREFIX/bin/sonexis-runtime"
if SONEXIS_DEV_PREFIX="$PREFIX" SONEXIS_RUNTIME_STATE_DIR="$STATE" \
    SONEXIS_RUNTIME_DIR="$SOCKETS" "$ROOT_DIR/Scripts/uninstall-runtime-dev.sh" \
    >/dev/null 2>&1; then
    echo "uninstaller deleted a modified managed binary" >&2
    exit 1
fi
[ -f "$PREFIX/bin/sonexis-runtime" ]
install -m 700 "$PRODUCTS/sonexis-runtime" "$PREFIX/bin/sonexis-runtime"

SONEXIS_DEV_PREFIX="$PREFIX" SONEXIS_RUNTIME_STATE_DIR="$STATE" \
    SONEXIS_RUNTIME_DIR="$SOCKETS" "$ROOT_DIR/Scripts/runtime-dev.sh" start >/dev/null
SONEXIS_DEV_PREFIX="$PREFIX" SONEXIS_RUNTIME_STATE_DIR="$STATE" \
    SONEXIS_RUNTIME_DIR="$SOCKETS" "$ROOT_DIR/Scripts/runtime-dev.sh" status >/dev/null
SONEXIS_DEV_PREFIX="$PREFIX" SONEXIS_RUNTIME_STATE_DIR="$STATE" \
    SONEXIS_RUNTIME_DIR="$SOCKETS" "$ROOT_DIR/Scripts/runtime-dev.sh" stop >/dev/null
SONEXIS_DEV_PREFIX="$PREFIX" SONEXIS_RUNTIME_STATE_DIR="$STATE" \
    SONEXIS_RUNTIME_DIR="$SOCKETS" "$ROOT_DIR/Scripts/uninstall-runtime-dev.sh" >/dev/null
[ ! -e "$PREFIX" ]

echo "Standalone Runtime install lifecycle and tamper-preservation tests passed"
