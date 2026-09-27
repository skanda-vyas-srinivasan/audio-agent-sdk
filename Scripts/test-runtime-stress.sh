#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
mkdir -p "$BUILD_DIR"
xcrun swiftc \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeProtocol.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/PCMFrameCodec.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/UnixDomainSocket.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeDataPlane.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeCaptureBackend.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeOutputDataPlane.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeOutputBackend.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/SonexisRuntimeServer.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/SonexisRuntimeClient.swift" \
    "$ROOT_DIR/Tests/RuntimeStress/main.swift" \
    -o "$BUILD_DIR/runtime-stress"
"$BUILD_DIR/runtime-stress"
