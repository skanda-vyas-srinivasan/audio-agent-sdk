#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}
if [ "${1:-}" = "--prefix" ] && [ "$#" -eq 2 ]; then PREFIX=$2
elif [ "$#" -ne 0 ]; then echo "Usage: $0 [--prefix ABSOLUTE_PATH]" >&2; exit 2; fi
case "$PREFIX" in /*) ;; *) echo "prefix must be absolute" >&2; exit 2 ;; esac
case "$PREFIX" in /|"$HOME"|/Users|/Applications|/Library)
    echo "refusing broad install prefix: $PREFIX" >&2; exit 2 ;;
esac
[ -e "$PREFIX" ] || { echo "No development install at $PREFIX"; exit 0; }
MANIFEST="$PREFIX/manifest.plist"
[ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] && [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || {
    echo "refusing unsafe or unmanaged install path" >&2; exit 1;
}
[ "$(plutil -extract install_kind raw -o - "$MANIFEST" 2>/dev/null)" = \
    "sonexis-runtime-standalone-dev" ] || {
    echo "refusing install with foreign manifest" >&2; exit 1;
}
[ "$(stat -f %u "$PREFIX")" = "$(id -u)" ] || {
    echo "refusing install owned by another user" >&2; exit 1;
}
[ -d "$PREFIX/bin" ] && [ ! -L "$PREFIX/bin" ] \
    && [ -f "$PREFIX/bin/sonexis-runtime" ] && [ ! -L "$PREFIX/bin/sonexis-runtime" ] \
    && [ -f "$PREFIX/bin/sonexisctl" ] && [ ! -L "$PREFIX/bin/sonexisctl" ] || {
    echo "refusing invalid managed layout" >&2; exit 1;
}
[ -z "$(find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name bin ! -name manifest.plist -print -quit)" ] \
    && [ -z "$(find "$PREFIX/bin" -mindepth 1 -maxdepth 1 \
        ! -name sonexis-runtime ! -name sonexisctl -print -quit)" ] || {
    echo "unexpected files found; preserving install" >&2; exit 1;
}
[ "$(plutil -extract runtime_sha256 raw -o - "$MANIFEST" 2>/dev/null)" = \
    "$(shasum -a 256 "$PREFIX/bin/sonexis-runtime" | awk '{print $1}')" ] || {
    echo "Runtime hash differs from manifest; preserving install" >&2; exit 1;
}
[ "$(plutil -extract cli_sha256 raw -o - "$MANIFEST" 2>/dev/null)" = \
    "$(shasum -a 256 "$PREFIX/bin/sonexisctl" | awk '{print $1}')" ] || {
    echo "CLI hash differs from manifest; preserving install" >&2; exit 1;
}
SONEXIS_DEV_PREFIX="$PREFIX" "$ROOT_DIR/Scripts/runtime-dev.sh" stop || {
    echo "stop the managed Runtime before uninstalling" >&2; exit 1;
}
rm -f "$PREFIX/bin/sonexis-runtime" "$PREFIX/bin/sonexisctl" "$MANIFEST"
rmdir "$PREFIX/bin" "$PREFIX"
echo "Uninstalled Sonexis Runtime development tools from $PREFIX"
