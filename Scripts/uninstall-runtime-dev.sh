#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}
if [ "${1:-}" = "--prefix" ] && [ "$#" -eq 2 ]; then PREFIX=$2
elif [ "$#" -ne 0 ]; then echo "Usage: $0 [--prefix ABSOLUTE_PATH]" >&2; exit 2; fi
case "$PREFIX" in /*) ;; *) echo "prefix must be absolute" >&2; exit 2 ;; esac
[ -e "$PREFIX" ] || { echo "No development install at $PREFIX"; exit 0; }
MANIFEST="$PREFIX/manifest.plist"
[ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] && [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || {
    echo "refusing unsafe or unmanaged install path" >&2; exit 1;
}
[ "$(plutil -extract install_kind raw -o - "$MANIFEST" 2>/dev/null)" = \
    "sonexis-runtime-standalone-dev" ] || {
    echo "refusing install with foreign manifest" >&2; exit 1;
}
SONEXIS_DEV_PREFIX="$PREFIX" "$ROOT_DIR/Scripts/runtime-dev.sh" stop || {
    echo "stop the managed Runtime before uninstalling" >&2; exit 1;
}
[ -z "$(find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name bin ! -name manifest.plist -print -quit)" ]
[ -z "$(find "$PREFIX/bin" -mindepth 1 -maxdepth 1 \
    ! -name sonexis-runtime ! -name sonexisctl -print -quit)" ]
rm -f "$PREFIX/bin/sonexis-runtime" "$PREFIX/bin/sonexisctl" "$MANIFEST"
rmdir "$PREFIX/bin" "$PREFIX"
echo "Uninstalled Sonexis Runtime development tools from $PREFIX"
