#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}
expect_prefix=0
for argument in "$@"; do
    if [ "$expect_prefix" = "1" ]; then
        PREFIX=$argument
        expect_prefix=0
    elif [ "$argument" = "--prefix" ]; then
        expect_prefix=1
    fi
done
"$ROOT_DIR/Scripts/install-runtime-dev.sh" "$@"

echo
echo "Next:"
if [ "$PREFIX" = "$HOME/Library/Application Support/SonexisRuntime/dev" ]; then
    echo "  $ROOT_DIR/Scripts/runtime-dev.sh start"
else
    echo "  SONEXIS_DEV_PREFIX='$PREFIX' $ROOT_DIR/Scripts/runtime-dev.sh start"
fi
echo "  '$PREFIX/bin/sonexisctl' sources"
echo
echo "macOS will request Screen & System Audio Recording permission on first capture."
