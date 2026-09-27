#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$ROOT_DIR" -c debug
swift test --package-path "$ROOT_DIR/SonexisAudioEngine"
"$ROOT_DIR/.build/debug/sonexis-runtime" --version
"$ROOT_DIR/.build/debug/sonexisctl" --version

printf 'Standalone Runtime, CLI, and AudioEngine builds passed\n'
