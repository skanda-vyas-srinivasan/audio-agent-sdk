#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
OUTPUT_DIR=${1:-"$ROOT_DIR/.build/signed-dev/bin"}
IDENTITY=${SONEXIS_SIGNING_IDENTITY:-}

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9][0-9]*) [A-F0-9]* "\(Apple Development:.*\)"$/\1/p' \
        | head -n 1)
fi
[ -n "$IDENTITY" ] || {
    echo "No Apple Development signing identity was found." >&2
    echo "Configure Xcode signing, or set SONEXIS_SIGNING_IDENTITY explicitly." >&2
    exit 1
}

"$ROOT_DIR/Scripts/check-runtime-version.py"
swift build --package-path "$ROOT_DIR" -c release

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR" ;;
esac
mkdir -p "$OUTPUT_DIR"
install -m 700 "$ROOT_DIR/.build/release/sonexis-runtime" "$OUTPUT_DIR/sonexis-runtime"
install -m 700 "$ROOT_DIR/.build/release/sonexisctl" "$OUTPUT_DIR/sonexisctl"

codesign --force --sign "$IDENTITY" --identifier com.sonexis.runtime \
    --timestamp=none "$OUTPUT_DIR/sonexis-runtime"
codesign --force --sign "$IDENTITY" --identifier com.sonexis.ctl \
    --timestamp=none "$OUTPUT_DIR/sonexisctl"

for product in "$OUTPUT_DIR/sonexis-runtime" "$OUTPUT_DIR/sonexisctl"; do
    codesign --verify --strict "$product"
    codesign -dvv "$product" 2>&1 | grep -F 'Authority=Apple Development:' >/dev/null
    codesign -dvv "$product" 2>&1 | grep -E '^TeamIdentifier=.+$' >/dev/null
done

[ "$(codesign -dvv "$OUTPUT_DIR/sonexis-runtime" 2>&1 | sed -n 's/^Identifier=//p')" = \
    "com.sonexis.runtime" ]
[ "$(codesign -dvv "$OUTPUT_DIR/sonexisctl" 2>&1 | sed -n 's/^Identifier=//p')" = \
    "com.sonexis.ctl" ]
strings "$OUTPUT_DIR/sonexis-runtime" \
    | grep -F '<key>NSAudioCaptureUsageDescription</key>' >/dev/null
strings "$OUTPUT_DIR/sonexis-runtime" \
    | grep -F '<key>NSMicrophoneUsageDescription</key>' >/dev/null

RUNTIME_TEAM=$(codesign -dvv "$OUTPUT_DIR/sonexis-runtime" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p')
CLI_TEAM=$(codesign -dvv "$OUTPUT_DIR/sonexisctl" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p')
[ "$RUNTIME_TEAM" = "$CLI_TEAM" ]

echo "Built Apple Development-signed products in $OUTPUT_DIR"
echo "  Runtime: com.sonexis.runtime (team $RUNTIME_TEAM)"
echo "  CLI:     com.sonexis.ctl"
