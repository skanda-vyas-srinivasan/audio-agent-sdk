#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")
PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}
DERIVED_DATA="$ROOT_DIR/.build/RuntimeDevInstall"
PRODUCTS_DIR=

usage() {
    echo "Usage: $0 [--prefix ABSOLUTE_PATH] [--products-dir PATH]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            PREFIX=$2
            shift 2
            ;;
        --products-dir)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            PRODUCTS_DIR=$2
            shift 2
            ;;
        *) usage; exit 2 ;;
    esac
done

case "$PREFIX" in
    /*) ;;
    *) echo "install-runtime-dev: prefix must be absolute" >&2; exit 2 ;;
esac
case "$PREFIX" in
    /|"$HOME"|/Users|/Applications|/Library)
        echo "install-runtime-dev: refusing broad prefix: $PREFIX" >&2
        exit 2
        ;;
esac

"$ROOT_DIR/Scripts/check-runtime-version.py"

if [ -z "$PRODUCTS_DIR" ]; then
    build_scheme() {
        if [ -n "${SONEXIS_DEVELOPMENT_TEAM:-}" ]; then
            xcodebuild -project "$ROOT_DIR/Sonexis.xcodeproj" -scheme "$1" \
                -configuration Debug -destination 'platform=macOS' \
                -derivedDataPath "$DERIVED_DATA" \
                DEVELOPMENT_TEAM="$SONEXIS_DEVELOPMENT_TEAM" build
        else
            xcodebuild -project "$ROOT_DIR/Sonexis.xcodeproj" -scheme "$1" \
                -configuration Debug -destination 'platform=macOS' \
                -derivedDataPath "$DERIVED_DATA" build
        fi
    }
    build_scheme sonexis-runtime
    build_scheme sonexisctl
    PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Debug"
fi

RUNTIME_SOURCE="$PRODUCTS_DIR/sonexis-runtime"
CTL_SOURCE="$PRODUCTS_DIR/sonexisctl"
for product in "$RUNTIME_SOURCE" "$CTL_SOURCE"; do
    [ -f "$product" ] && [ ! -L "$product" ] && [ -x "$product" ] || {
        echo "install-runtime-dev: missing regular executable: $product" >&2
        exit 1
    }
    codesign --verify --strict "$product"
    codesign -dvv "$product" 2>&1 | grep -F 'Authority=Apple Development:' >/dev/null || {
        echo "install-runtime-dev: product is not Apple Development signed: $product" >&2
        echo "Configure Xcode signing or set SONEXIS_DEVELOPMENT_TEAM, then rebuild." >&2
        exit 1
    }
    codesign -dvv "$product" 2>&1 | grep -E '^TeamIdentifier=.+$' >/dev/null || {
        echo "install-runtime-dev: product has no signing TeamIdentifier: $product" >&2
        exit 1
    }
done

RUNTIME_TEAM=$(codesign -dvv "$RUNTIME_SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
CTL_TEAM=$(codesign -dvv "$CTL_SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$RUNTIME_TEAM" = "$CTL_TEAM" ] || {
    echo "install-runtime-dev: Runtime and CLI signing teams differ" >&2
    exit 1
}

RUNTIME_ID=$(codesign -dvv "$RUNTIME_SOURCE" 2>&1 | sed -n 's/^Identifier=//p')
CTL_ID=$(codesign -dvv "$CTL_SOURCE" 2>&1 | sed -n 's/^Identifier=//p')
[ "$RUNTIME_ID" = "com.sonexis.runtime" ] || {
    echo "install-runtime-dev: unexpected Runtime identity: $RUNTIME_ID" >&2
    exit 1
}
[ "$CTL_ID" = "com.sonexis.ctl" ] || {
    echo "install-runtime-dev: unexpected CLI identity: $CTL_ID" >&2
    exit 1
}
strings "$RUNTIME_SOURCE" | grep -F '<key>NSAudioCaptureUsageDescription</key>' >/dev/null || {
    echo "install-runtime-dev: Runtime lacks NSAudioCaptureUsageDescription" >&2
    exit 1
}
[ "$("$RUNTIME_SOURCE" --version)" = "sonexis-runtime $VERSION (protocol 2)" ] || {
    echo "install-runtime-dev: Runtime executable version disagrees with $VERSION" >&2
    exit 1
}
[ "$("$CTL_SOURCE" version)" = "sonexisctl $VERSION (protocol 2)" ] || {
    echo "install-runtime-dev: CLI executable version disagrees with $VERSION" >&2
    exit 1
}

PARENT=$(dirname -- "$PREFIX")
if [ ! -e "$PARENT" ]; then
    mkdir -p "$PARENT"
    chmod 700 "$PARENT"
fi
[ -d "$PARENT" ] && [ ! -L "$PARENT" ] || {
    echo "install-runtime-dev: install parent is not a real directory: $PARENT" >&2
    exit 1
}
[ "$(stat -f %u "$PARENT")" = "$(id -u)" ] || {
    echo "install-runtime-dev: install parent belongs to another user: $PARENT" >&2
    exit 1
}

verify_managed_install() {
    [ -d "$PREFIX/bin" ] && [ ! -L "$PREFIX/bin" ] || return 1
    [ -f "$PREFIX/bin/sonexis-runtime" ] && [ ! -L "$PREFIX/bin/sonexis-runtime" ] || return 1
    [ -f "$PREFIX/bin/sonexisctl" ] && [ ! -L "$PREFIX/bin/sonexisctl" ] || return 1
    [ -z "$(find "$PREFIX" -mindepth 1 -maxdepth 1 \
        ! -name bin ! -name manifest.plist -print -quit)" ] || return 1
    [ -z "$(find "$PREFIX/bin" -mindepth 1 -maxdepth 1 \
        ! -name sonexis-runtime ! -name sonexisctl -print -quit)" ] || return 1
    MANIFEST="$PREFIX/manifest.plist"
    [ "$(plutil -extract install_kind raw -o - "$MANIFEST" 2>/dev/null)" = \
        "sonexis-runtime-dev" ] || return 1
    [ "$(plutil -extract runtime_sha256 raw -o - "$MANIFEST" 2>/dev/null)" = \
        "$(shasum -a 256 "$PREFIX/bin/sonexis-runtime" | awk '{print $1}')" ] || return 1
    [ "$(plutil -extract cli_sha256 raw -o - "$MANIFEST" 2>/dev/null)" = \
        "$(shasum -a 256 "$PREFIX/bin/sonexisctl" | awk '{print $1}')" ] || return 1
}

if [ -e "$PREFIX" ]; then
    [ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] || {
        echo "install-runtime-dev: existing prefix is not a real directory" >&2
        exit 1
    }
    [ "$(stat -f %u "$PREFIX")" = "$(id -u)" ] || {
        echo "install-runtime-dev: existing prefix belongs to another user" >&2
        exit 1
    }
    [ -f "$PREFIX/manifest.plist" ] && [ ! -L "$PREFIX/manifest.plist" ] || {
        echo "install-runtime-dev: refusing to replace an unmanaged directory" >&2
        exit 1
    }
    verify_managed_install || {
        echo "install-runtime-dev: existing install failed manifest/layout integrity checks" >&2
        exit 1
    }
    if /usr/sbin/lsof -t -- "$PREFIX/bin/sonexis-runtime" 2>/dev/null | grep -q .; then
        echo "install-runtime-dev: Runtime is using this install; stop it before reinstalling" >&2
        exit 1
    fi
fi

STAGE=$(mktemp -d "$PARENT/.sonexis-runtime-dev-stage.XXXXXX")
PREVIOUS=$(mktemp -d "$PARENT/.sonexis-runtime-dev-previous.XXXXXX")
rmdir "$PREVIOUS"
cleanup() {
    [ ! -d "$STAGE" ] || rm -rf "$STAGE"
    [ ! -d "$PREVIOUS" ] || rm -rf "$PREVIOUS"
}
trap cleanup EXIT HUP INT TERM
chmod 700 "$STAGE"
mkdir -m 700 "$STAGE/bin"
install -m 700 "$RUNTIME_SOURCE" "$STAGE/bin/sonexis-runtime"
install -m 700 "$CTL_SOURCE" "$STAGE/bin/sonexisctl"

plutil -create xml1 "$STAGE/manifest.plist"
plutil -insert install_kind -string sonexis-runtime-dev "$STAGE/manifest.plist"
plutil -insert version -string "$VERSION" "$STAGE/manifest.plist"
plutil -insert protocol_version -integer 2 "$STAGE/manifest.plist"
plutil -insert runtime_identifier -string com.sonexis.runtime "$STAGE/manifest.plist"
plutil -insert cli_identifier -string com.sonexis.ctl "$STAGE/manifest.plist"
plutil -insert runtime_sha256 -string "$(shasum -a 256 "$STAGE/bin/sonexis-runtime" | awk '{print $1}')" "$STAGE/manifest.plist"
plutil -insert cli_sha256 -string "$(shasum -a 256 "$STAGE/bin/sonexisctl" | awk '{print $1}')" "$STAGE/manifest.plist"
chmod 600 "$STAGE/manifest.plist"

if [ -d "$PREFIX" ]; then
    mv "$PREFIX" "$PREVIOUS"
fi
if ! mv "$STAGE" "$PREFIX"; then
    [ ! -d "$PREVIOUS" ] || mv "$PREVIOUS" "$PREFIX"
    exit 1
fi
if [ -d "$PREVIOUS" ]; then
    rm -rf "$PREVIOUS"
fi
trap - EXIT HUP INT TERM

echo "Installed Sonexis Runtime $VERSION development tools:"
echo "  $PREFIX/bin/sonexis-runtime"
echo "  $PREFIX/bin/sonexisctl"
echo "Run: $ROOT_DIR/Scripts/runtime-dev.sh start"
