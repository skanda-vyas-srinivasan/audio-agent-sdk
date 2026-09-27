#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCTS_DIR=${1:-"$ROOT_DIR/.build/RuntimeRelease/Build/Products/Release"}
VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")
RUNTIME="$PRODUCTS_DIR/sonexis-runtime"
CTL="$PRODUCTS_DIR/sonexisctl"

verify_product() {
    product=$1
    expected_identifier=$2
    [ -f "$product" ] && [ ! -L "$product" ] && [ -x "$product" ] || {
        echo "release-product-check: missing executable: $product" >&2
        exit 1
    }
    codesign --verify --strict "$product"
    metadata=$(codesign -dvv "$product" 2>&1)
    printf '%s\n' "$metadata" | grep -F "Identifier=$expected_identifier" >/dev/null
    printf '%s\n' "$metadata" | grep -F 'Authority=Apple Development:' >/dev/null
    team=$(printf '%s\n' "$metadata" | sed -n 's/^TeamIdentifier=//p')
    [ -n "$team" ] || { echo "release-product-check: missing Team ID" >&2; exit 1; }
    architectures=$(lipo -archs "$product")
    case " $architectures " in *' arm64 '*) ;; *) exit 1 ;; esac
    case " $architectures " in *' x86_64 '*) ;; *) exit 1 ;; esac
    [ "$(xcrun vtool -show-build "$product" | grep -c 'minos 14.4')" -eq 2 ] || {
        echo "release-product-check: expected macOS 14.4 for both architectures" >&2
        exit 1
    }
    entitlements=$(codesign -d --entitlements :- "$product" 2>&1 || true)
    if printf '%s\n' "$entitlements" | grep -F 'com.apple.security.get-task-allow' >/dev/null; then
        echo "release-product-check: Release product contains get-task-allow: $product" >&2
        exit 1
    fi
    printf '%s\n' "$team"
}

RUNTIME_TEAM=$(verify_product "$RUNTIME" com.sonexis.runtime)
CTL_TEAM=$(verify_product "$CTL" com.sonexis.ctl)
[ "$RUNTIME_TEAM" = "$CTL_TEAM" ] || {
    echo "release-product-check: Runtime and CLI signing teams differ" >&2
    exit 1
}
strings "$RUNTIME" | grep -F '<key>NSAudioCaptureUsageDescription</key>' >/dev/null
[ "$("$RUNTIME" --version)" = "sonexis-runtime $VERSION (protocol 2)" ]
[ "$("$CTL" version)" = "sonexisctl $VERSION (protocol 2)" ]

echo "Signed universal Runtime release products passed identity, entitlement, and version checks"
