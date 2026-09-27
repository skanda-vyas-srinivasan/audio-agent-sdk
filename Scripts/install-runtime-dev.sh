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

PARENT=$(dirname -- "$PREFIX")
mkdir -p "$PARENT"
[ -d "$PARENT" ] && [ ! -L "$PARENT" ] || {
    echo "install parent is not a real directory: $PARENT" >&2; exit 1;
}
[ "$(stat -f %u "$PARENT")" = "$(id -u)" ] || {
    echo "install parent belongs to another user" >&2; exit 1;
}
if [ -e "$PREFIX" ]; then
    [ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] \
        && [ -f "$PREFIX/manifest.plist" ] && [ ! -L "$PREFIX/manifest.plist" ] \
        && [ "$(plutil -extract install_kind raw -o - "$PREFIX/manifest.plist" 2>/dev/null)" = \
            "sonexis-runtime-standalone-dev" ] || {
        echo "refusing to replace unmanaged install: $PREFIX" >&2; exit 1;
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
