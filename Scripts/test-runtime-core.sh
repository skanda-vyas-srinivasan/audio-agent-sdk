#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
mkdir -p "$BUILD_DIR"
xcrun swiftc \
    "$ROOT_DIR/SonexisAudioEngine/Sources/SonexisAudioEngine/AudioSource.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/Capture/AudioFrame.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/Capture/CaptureMetrics.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/Capture/RuntimeAudioNormalizer.swift" \
    "$ROOT_DIR/Tests/RuntimeCore/main.swift" \
    -o "$BUILD_DIR/runtime-core"
"$BUILD_DIR/runtime-core"
