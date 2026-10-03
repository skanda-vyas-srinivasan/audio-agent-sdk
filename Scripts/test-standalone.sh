#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT_DIR/Scripts/check-runtime-version.py"
"$ROOT_DIR/Scripts/check-repository-independence.py"
swift build --package-path "$ROOT_DIR" -c debug
swift test --package-path "$ROOT_DIR"
swift test --package-path "$ROOT_DIR/SonexisAudioEngine"
"$ROOT_DIR/.build/debug/sonexis-runtime" --version
"$ROOT_DIR/.build/debug/sonexisctl" --version
if [ "${AUDIOPLANE_TEST_GUI_DISCOVERY:-0}" = "1" ]; then
    "$ROOT_DIR/Scripts/test-runtime-discovery.sh"
fi

"$ROOT_DIR/Scripts/test-runtime-protocol.sh"
"$ROOT_DIR/Scripts/test-runtime-core.sh"
"$ROOT_DIR/Scripts/test-runtime-output-core.sh"
"$ROOT_DIR/Scripts/test-runtime-integration.sh"
"$ROOT_DIR/Scripts/test-runtime-fuzz.sh"
"$ROOT_DIR/Scripts/test-runtime-stress.sh"
"$ROOT_DIR/Scripts/test-runtime-output-tsan.sh"
"$ROOT_DIR/Scripts/test-python-sdk.sh"
"$ROOT_DIR/Scripts/test-agent-torture.sh"
"$ROOT_DIR/Scripts/test-runtime-examples.sh"
"$ROOT_DIR/Scripts/test-runtime-packages.sh"

printf 'Standalone Runtime release gate passed\n'
