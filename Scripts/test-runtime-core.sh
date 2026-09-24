#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
mkdir -p "$BUILD_DIR"
xcrun swiftc \
    "$ROOT_DIR/Sonexis/RuntimeCore/Capture/AudioSource.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/Capture/AudioFrame.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/Capture/CaptureMetrics.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/Capture/RuntimeAudioNormalizer.swift" \
    "$ROOT_DIR/Tests/RuntimeCore/main.swift" \
    -o "$BUILD_DIR/runtime-core"
"$BUILD_DIR/runtime-core"
