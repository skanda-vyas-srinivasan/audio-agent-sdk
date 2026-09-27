#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

git diff --check
Scripts/check-runtime-version.py
xcodebuild -project Sonexis.xcodeproj -scheme Sonexis -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
    CODE_SIGNING_ALLOWED=NO build
Scripts/test-all.sh
Scripts/test-runtime-fuzz.sh
Scripts/test-runtime-stress.sh
Scripts/test-runtime-output-tsan.sh
Scripts/test-concurrency-tsan.sh
Scripts/test-python-sdk.sh
Scripts/test-runtime-examples.sh
Scripts/test-runtime-packages.sh
xcodebuild -project Sonexis.xcodeproj -scheme sonexis-runtime -configuration Release \
    -destination 'platform=macOS' -derivedDataPath .build/RuntimeRelease build
xcodebuild -project Sonexis.xcodeproj -scheme sonexisctl -configuration Release \
    -destination 'platform=macOS' -derivedDataPath .build/RuntimeRelease build
Scripts/test-runtime-distribution.sh \
    "$ROOT_DIR/.build/RuntimeRelease/Build/Products/Release"

echo "Sonexis Runtime release gate passed"
