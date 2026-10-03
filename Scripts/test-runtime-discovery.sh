#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$ROOT_DIR"
python3 "$ROOT_DIR/Tests/RuntimeDiscovery/check.py"
