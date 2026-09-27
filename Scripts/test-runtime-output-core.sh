#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
mkdir -p "$BUILD_DIR"
xcrun clang -std=c11 -c \
    "$ROOT_DIR/Sonexis/ProcessTapEngine/RealtimeAudioRing.c" \
    -o "$BUILD_DIR/RealtimeAudioRing-output.o"
xcrun swiftc \
    -import-objc-header "$ROOT_DIR/Tools/Runtime-Bridging-Header.h" \
    -I "$ROOT_DIR/Sonexis/ProcessTapEngine" \
    "$ROOT_DIR/Sonexis/ProcessTapEngine/RealtimeRingBuffer.swift" \
    "$ROOT_DIR/Sonexis/ProcessTapEngine/CoreAudioSupport.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeProtocol.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/PCMFrameCodec.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/UnixDomainSocket.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeOutputDataPlane.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/IPC/RuntimeOutputBackend.swift" \
    "$ROOT_DIR/Sonexis/RuntimeCore/Output/RuntimeHALPlaybackBackend.swift" \
    "$ROOT_DIR/Tests/RuntimeOutputCore/main.swift" \
    "$BUILD_DIR/RealtimeAudioRing-output.o" \
    -framework AVFoundation -framework CoreAudio \
    -o "$BUILD_DIR/runtime-output-core"
"$BUILD_DIR/runtime-output-core"
