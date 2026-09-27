#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
CLI="$ROOT_DIR/.build/debug/sonexisctl"
mkdir -p "$BUILD_DIR"
swift build --package-path "$ROOT_DIR" --product sonexisctl
xcrun swiftc \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeProtocol.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/PCMFrameCodec.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/UnixDomainSocket.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeDataPlane.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeCaptureBackend.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeOutputDataPlane.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeOutputBackend.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/SonexisRuntimeServer.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/SonexisRuntimeClient.swift" \
    "$ROOT_DIR/Tests/RuntimeIntegration/main.swift" \
    -o "$BUILD_DIR/runtime-integration"
SONEXISCTL_BINARY="$CLI" \
PYTHON_BINARY="/usr/bin/python3" \
PYTHONPATH="$ROOT_DIR/SDKs/python/src" \
PYTHON_SMOKE="$ROOT_DIR/SDKs/python/tests/runtime_smoke.py" \
    "$BUILD_DIR/runtime-integration"
