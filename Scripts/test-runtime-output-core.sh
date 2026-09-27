#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/RuntimeTests"
mkdir -p "$BUILD_DIR"
xcrun clang -std=c11 -c \
    "$ROOT_DIR/SonexisAudioEngine/Sources/SonexisAudioEngineC/RealtimeAudioRing.c" \
    -I "$ROOT_DIR/SonexisAudioEngine/Sources/SonexisAudioEngineC/include" \
    -o "$BUILD_DIR/RealtimeAudioRing-output.o"
xcrun swiftc \
    -I "$ROOT_DIR/SonexisAudioEngine/Sources/SonexisAudioEngineC/include" \
    "$ROOT_DIR/SonexisAudioEngine/Sources/SonexisAudioEngine/RealtimeRingBuffer.swift" \
    "$ROOT_DIR/SonexisAudioEngine/Sources/SonexisAudioEngine/CoreAudioSupport.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeProtocol.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/PCMFrameCodec.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/UnixDomainSocket.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeOutputDataPlane.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/IPC/RuntimeOutputBackend.swift" \
    "$ROOT_DIR/Sources/SonexisRuntime/Output/RuntimeHALPlaybackBackend.swift" \
    "$ROOT_DIR/Tests/RuntimeOutputCore/main.swift" \
    "$BUILD_DIR/RealtimeAudioRing-output.o" \
    -framework AVFoundation -framework CoreAudio \
    -o "$BUILD_DIR/runtime-output-core"
"$BUILD_DIR/runtime-output-core"
