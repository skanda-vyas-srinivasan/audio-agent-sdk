#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}
PRODUCTS_DIR=

usage() { echo "Usage: $0 [--prefix ABSOLUTE_PATH] [--products-dir PATH]" >&2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) [ "$#" -ge 2 ] || { usage; exit 2; }; PREFIX=$2; shift 2 ;;
        --products-dir) [ "$#" -ge 2 ] || { usage; exit 2; }; PRODUCTS_DIR=$2; shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
case "$PREFIX" in /*) ;; *) echo "prefix must be absolute" >&2; exit 2 ;; esac
case "$PREFIX" in /|"$HOME"|/Users|/Applications|/Library)
    echo "refusing broad install prefix: $PREFIX" >&2; exit 2 ;;
esac

if [ -z "$PRODUCTS_DIR" ]; then
    PRODUCTS_DIR="$ROOT_DIR/.build/signed-dev/bin"
    "$ROOT_DIR/Scripts/build-signed-runtime-dev.sh" "$PRODUCTS_DIR"
fi
for name in sonexis-runtime sonexisctl; do
    product="$PRODUCTS_DIR/$name"
    [ -f "$product" ] && [ ! -L "$product" ] && [ -x "$product" ] || {
        echo "missing regular executable: $product" >&2; exit 1;
    }
    codesign --verify --strict "$product"
    codesign -dvv "$product" 2>&1 | grep -F 'Authority=Apple Development:' >/dev/null || {
        echo "$product is not Apple Development signed" >&2; exit 1;
    }
done
RUNTIME_SOURCE="$PRODUCTS_DIR/sonexis-runtime"
CTL_SOURCE="$PRODUCTS_DIR/sonexisctl"
RUNTIME_TEAM=$(codesign -dvv "$RUNTIME_SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
CLI_TEAM=$(codesign -dvv "$CTL_SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ -n "$RUNTIME_TEAM" ] && [ "$RUNTIME_TEAM" = "$CLI_TEAM" ] || {
    echo "Runtime and CLI must have the same nonempty TeamIdentifier" >&2; exit 1;
}
[ "$(codesign -dvv "$RUNTIME_SOURCE" 2>&1 | sed -n 's/^Identifier=//p')" = \
    "com.sonexis.runtime" ] || { echo "unexpected Runtime identifier" >&2; exit 1; }
[ "$(codesign -dvv "$CTL_SOURCE" 2>&1 | sed -n 's/^Identifier=//p')" = \
    "com.sonexis.ctl" ] || { echo "unexpected CLI identifier" >&2; exit 1; }
strings "$RUNTIME_SOURCE" | grep -F '<key>NSAudioCaptureUsageDescription</key>' >/dev/null || {
    echo "Runtime lacks NSAudioCaptureUsageDescription" >&2; exit 1;
}
VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")
[ "$("$RUNTIME_SOURCE" --version)" = "sonexis-runtime $VERSION (protocol 2)" ] || {
    echo "Runtime version does not match RUNTIME_VERSION" >&2; exit 1;
}
[ "$("$CTL_SOURCE" version)" = "sonexisctl $VERSION (protocol 2)" ] || {
    echo "CLI version does not match RUNTIME_VERSION" >&2; exit 1;
}

PARENT=$(dirname -- "$PREFIX")
mkdir -p "$PARENT"
[ -d "$PARENT" ] && [ ! -L "$PARENT" ] || {
    echo "install parent is not a real directory: $PARENT" >&2; exit 1;
}
[ "$(stat -f %u "$PARENT")" = "$(id -u)" ] || {
    echo "install parent belongs to another user" >&2; exit 1;
}

verify_managed_install() {
    [ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] || return 1
    [ "$(stat -f %u "$PREFIX")" = "$(id -u)" ] || return 1
    [ -d "$PREFIX/bin" ] && [ ! -L "$PREFIX/bin" ] || return 1
    [ -f "$PREFIX/bin/sonexis-runtime" ] && [ ! -L "$PREFIX/bin/sonexis-runtime" ] || return 1
    [ -f "$PREFIX/bin/sonexisctl" ] && [ ! -L "$PREFIX/bin/sonexisctl" ] || return 1
    [ -f "$PREFIX/manifest.plist" ] && [ ! -L "$PREFIX/manifest.plist" ] || return 1
    [ -z "$(find "$PREFIX" -mindepth 1 -maxdepth 1 \
        ! -name bin ! -name manifest.plist -print -quit)" ] || return 1
    [ -z "$(find "$PREFIX/bin" -mindepth 1 -maxdepth 1 \
        ! -name sonexis-runtime ! -name sonexisctl -print -quit)" ] || return 1
    [ "$(plutil -extract install_kind raw -o - "$PREFIX/manifest.plist" 2>/dev/null)" = \
        "sonexis-runtime-standalone-dev" ] || return 1
    [ "$(plutil -extract runtime_sha256 raw -o - "$PREFIX/manifest.plist" 2>/dev/null)" = \
        "$(shasum -a 256 "$PREFIX/bin/sonexis-runtime" | awk '{print $1}')" ] || return 1
    [ "$(plutil -extract cli_sha256 raw -o - "$PREFIX/manifest.plist" 2>/dev/null)" = \
        "$(shasum -a 256 "$PREFIX/bin/sonexisctl" | awk '{print $1}')" ] || return 1
}
if [ -e "$PREFIX" ]; then
    verify_managed_install || {
        echo "refusing to replace modified or unmanaged install: $PREFIX" >&2; exit 1;
    }
fi

STAGE=$(mktemp -d "$PARENT/.sonexis-runtime-stage.XXXXXX")
PREVIOUS="$PARENT/.sonexis-runtime-previous.$$"
cleanup() { [ ! -d "$STAGE" ] || rm -rf "$STAGE"; }
trap cleanup EXIT HUP INT TERM
chmod 700 "$STAGE"
mkdir -m 700 "$STAGE/bin"
install -m 700 "$PRODUCTS_DIR/sonexis-runtime" "$STAGE/bin/sonexis-runtime"
install -m 700 "$PRODUCTS_DIR/sonexisctl" "$STAGE/bin/sonexisctl"
plutil -create xml1 "$STAGE/manifest.plist"
plutil -insert install_kind -string sonexis-runtime-standalone-dev "$STAGE/manifest.plist"
plutil -insert runtime_sha256 -string \
    "$(shasum -a 256 "$STAGE/bin/sonexis-runtime" | awk '{print $1}')" "$STAGE/manifest.plist"
plutil -insert cli_sha256 -string \
    "$(shasum -a 256 "$STAGE/bin/sonexisctl" | awk '{print $1}')" "$STAGE/manifest.plist"
chmod 600 "$STAGE/manifest.plist"

[ ! -e "$PREVIOUS" ] && [ ! -L "$PREVIOUS" ] || {
    echo "temporary previous path already exists" >&2; exit 1;
}
if [ -d "$PREFIX" ]; then mv "$PREFIX" "$PREVIOUS"; fi
if ! mv "$STAGE" "$PREFIX"; then
    [ ! -d "$PREVIOUS" ] || mv "$PREVIOUS" "$PREFIX"
    exit 1
fi
if [ -d "$PREVIOUS" ]; then rm -rf "$PREVIOUS"; fi
trap - EXIT HUP INT TERM
echo "Installed signed Runtime development tools at $PREFIX"
