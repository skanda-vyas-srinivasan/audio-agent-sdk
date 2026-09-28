#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
IDENTITY=${AUDIOPLANE_SIGNING_IDENTITY:-${SONEXIS_SIGNING_IDENTITY:-}}

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9][0-9]*) [A-F0-9]* "\(Apple Development:.*\)"$/\1/p' \
        | head -n 1)
fi
[ -n "$IDENTITY" ] || {
    echo "No Apple Development signing identity was found." >&2
    echo "Configure Xcode signing, or set AUDIOPLANE_SIGNING_IDENTITY explicitly." >&2
    exit 1
}

make -C "$ROOT_DIR/AudioPlaneHALDriver" clean all test test-tsan inspect \
    SIGN_IDENTITY="$IDENTITY"

BUNDLE="$ROOT_DIR/AudioPlaneHALDriver/.build/AudioPlaneInput.driver"
codesign --verify --strict "$BUNDLE"
codesign -dvv "$BUNDLE" 2>&1 | grep -F 'Authority=Apple Development:' >/dev/null || {
    echo "AudioPlane Input is not Apple Development signed" >&2
    exit 1
}
IDENTIFIER=$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^Identifier=//p')
[ "$IDENTIFIER" = "com.audioplane.input.driver" ] || {
    echo "Unexpected driver identifier: $IDENTIFIER" >&2
    exit 1
}
TEAM=$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ -n "$TEAM" ] || { echo "Signed driver has no TeamIdentifier" >&2; exit 1; }

echo "Built and tested Apple Development-signed AudioPlane Input:"
echo "  $BUNDLE"
echo "  bundle ID: com.audioplane.input.driver"
echo "  team: $TEAM"
