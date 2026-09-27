#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}

if [ "${1:-}" = "--prefix" ]; then
    [ "$#" -eq 2 ] || { echo "Usage: $0 [--prefix ABSOLUTE_PATH]" >&2; exit 2; }
    PREFIX=$2
elif [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--prefix ABSOLUTE_PATH]" >&2
    exit 2
fi

case "$PREFIX" in
    /*) ;;
    *) echo "uninstall-runtime-dev: prefix must be absolute" >&2; exit 2 ;;
esac
case "$PREFIX" in
    /|"$HOME"|/Users|/Applications|/Library)
        echo "uninstall-runtime-dev: refusing broad prefix: $PREFIX" >&2
        exit 2
        ;;
esac

if [ ! -e "$PREFIX" ]; then
    echo "No Sonexis Runtime development install at $PREFIX"
    exit 0
fi
[ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] || {
    echo "uninstall-runtime-dev: prefix is not a real directory" >&2
    exit 1
}
[ "$(stat -f %u "$PREFIX")" = "$(id -u)" ] || {
    echo "uninstall-runtime-dev: prefix belongs to another user" >&2
    exit 1
}
MANIFEST="$PREFIX/manifest.plist"
[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || {
    echo "uninstall-runtime-dev: refusing unmanaged directory" >&2
    exit 1
}
[ -d "$PREFIX/bin" ] && [ ! -L "$PREFIX/bin" ] || {
    echo "uninstall-runtime-dev: invalid managed bin directory" >&2
    exit 1
}
[ -f "$PREFIX/bin/sonexis-runtime" ] && [ ! -L "$PREFIX/bin/sonexis-runtime" ] || {
    echo "uninstall-runtime-dev: invalid managed Runtime executable" >&2
    exit 1
}
[ -f "$PREFIX/bin/sonexisctl" ] && [ ! -L "$PREFIX/bin/sonexisctl" ] || {
    echo "uninstall-runtime-dev: invalid managed CLI executable" >&2
    exit 1
}
[ -z "$(find "$PREFIX" -mindepth 1 -maxdepth 1 \
    ! -name bin ! -name manifest.plist -print -quit)" ] || {
    echo "uninstall-runtime-dev: unexpected files in install; preserving directory" >&2
    exit 1
}
[ -z "$(find "$PREFIX/bin" -mindepth 1 -maxdepth 1 \
    ! -name sonexis-runtime ! -name sonexisctl -print -quit)" ] || {
    echo "uninstall-runtime-dev: unexpected binaries in install; preserving directory" >&2
    exit 1
}
[ "$(plutil -extract install_kind raw -o - "$MANIFEST" 2>/dev/null)" = "sonexis-runtime-dev" ] || {
    echo "uninstall-runtime-dev: manifest does not identify a development install" >&2
    exit 1
}
[ "$(plutil -extract runtime_sha256 raw -o - "$MANIFEST" 2>/dev/null)" = \
    "$(shasum -a 256 "$PREFIX/bin/sonexis-runtime" | awk '{print $1}')" ] || {
    echo "uninstall-runtime-dev: Runtime hash differs from manifest; preserving directory" >&2
    exit 1
}
[ "$(plutil -extract cli_sha256 raw -o - "$MANIFEST" 2>/dev/null)" = \
    "$(shasum -a 256 "$PREFIX/bin/sonexisctl" | awk '{print $1}')" ] || {
    echo "uninstall-runtime-dev: CLI hash differs from manifest; preserving directory" >&2
    exit 1
}

SONEXIS_DEV_PREFIX="$PREFIX" "$ROOT_DIR/Scripts/runtime-dev.sh" stop || {
    echo "uninstall-runtime-dev: stop the managed Runtime before uninstalling" >&2
    exit 1
}

rm -f "$PREFIX/bin/sonexis-runtime" "$PREFIX/bin/sonexisctl" "$MANIFEST"
rmdir "$PREFIX/bin"
if ! rmdir "$PREFIX"; then
    echo "uninstall-runtime-dev: unexpected files remain; preserved $PREFIX" >&2
    exit 1
fi
echo "Uninstalled Sonexis Runtime development tools from $PREFIX"
