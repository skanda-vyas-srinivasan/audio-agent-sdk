#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
CLI="$ROOT_DIR/.build/DerivedData/Build/Products/Debug/sonexisctl"
mkdir -p "$BUILD_DIR"
xcodebuild -quiet \
    -project "$ROOT_DIR/Sonexis.xcodeproj" \
    -scheme sonexisctl \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$ROOT_DIR/.build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build
xcrun swiftc \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeProtocol.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/PCMFrameCodec.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/UnixDomainSocket.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeDataPlane.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeCaptureBackend.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/SonexisRuntimeServer.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/SonexisRuntimeClient.swift" \
    "$ROOT_DIR/Tests/RuntimeIntegration/main.swift" \
    -o "$BUILD_DIR/runtime-integration"
SONEXISCTL_BINARY="$CLI" "$BUILD_DIR/runtime-integration"
