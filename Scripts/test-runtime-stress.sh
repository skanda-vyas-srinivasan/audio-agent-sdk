#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
mkdir -p "$BUILD_DIR"
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
    "$ROOT_DIR/Tests/RuntimeStress/main.swift" \
    -o "$BUILD_DIR/runtime-stress"
"$BUILD_DIR/runtime-stress"
