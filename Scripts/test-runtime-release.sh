#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
"$ROOT_DIR/Scripts/test-standalone.sh"
"$ROOT_DIR/Scripts/build-signed-runtime-dev.sh"

RUNTIME="$ROOT_DIR/.build/signed-dev/bin/sonexis-runtime"
CLI="$ROOT_DIR/.build/signed-dev/bin/sonexisctl"
[ "$($RUNTIME --version)" = "sonexis-runtime 1.0.0 (protocol 2)" ]
[ "$($CLI version)" = "sonexisctl 1.0.0 (protocol 2)" ]
codesign --verify --strict "$RUNTIME"
codesign --verify --strict "$CLI"
strings "$RUNTIME" | grep -F '<key>NSAudioCaptureUsageDescription</key>' >/dev/null
[ "$(codesign -dvv "$RUNTIME" 2>&1 | sed -n 's/^Identifier=//p')" = \
    "com.sonexis.runtime" ]
"$ROOT_DIR/Scripts/test-runtime-install.sh"

echo "Standalone Sonexis Runtime release gate passed"
