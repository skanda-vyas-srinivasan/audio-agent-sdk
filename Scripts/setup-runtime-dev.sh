#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
"$ROOT_DIR/Scripts/install-runtime-dev.sh" "$@"
echo "Run: $ROOT_DIR/Scripts/runtime-dev.sh start"
