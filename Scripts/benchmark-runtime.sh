#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
mkdir -p "$BUILD_DIR"
xcrun swiftc -O \
    "$ROOT_DIR/Sources/SonexisRuntime/Capture/AudioFrame.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/Capture/RuntimeAudioNormalizer.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeProtocol.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/PCMFrameCodec.swift" \
    "$ROOT_DIR/Tests/RuntimeBenchmark/main.swift" \
    -o "$BUILD_DIR/runtime-benchmark"
"$BUILD_DIR/runtime-benchmark"
