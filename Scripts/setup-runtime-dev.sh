#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT_DIR/Scripts/install-runtime-dev.sh" "$@"

PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}
echo
echo "Next:"
echo "  $ROOT_DIR/Scripts/runtime-dev.sh start"
echo "  '$PREFIX/bin/sonexisctl' sources"
echo
echo "macOS will request Screen & System Audio Recording permission on first capture."
