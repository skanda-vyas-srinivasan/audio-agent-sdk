#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

git diff --check
Scripts/check-runtime-version.py
Scripts/check-runtime-docs.py
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
Scripts/verify-runtime-release-products.sh \
    "$ROOT_DIR/.build/RuntimeRelease/Build/Products/Release"
Scripts/test-runtime-distribution.sh \
    "$ROOT_DIR/.build/RuntimeRelease/Build/Products/Release"

ARTIFACT_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sonexis-release-artifacts.XXXXXX")
cleanup_artifacts() { rm -rf "$ARTIFACT_TEST_ROOT"; }
trap cleanup_artifacts EXIT HUP INT TERM
Scripts/build-runtime-artifacts.sh \
    "$ROOT_DIR/.build/RuntimeRelease/Build/Products/Release" \
    "$ARTIFACT_TEST_ROOT"
Scripts/test-runtime-artifacts.sh \
    "$ARTIFACT_TEST_ROOT/$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")"
cleanup_artifacts
trap - EXIT HUP INT TERM

echo "Sonexis Runtime release gate passed"
