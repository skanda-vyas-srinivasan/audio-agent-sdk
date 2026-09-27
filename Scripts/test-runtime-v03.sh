#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR/SDKs/python/tests"
PYTHONPATH="$ROOT_DIR/SDKs/python/src" /usr/bin/python3 -m unittest -v \
    test_sdk test_v03 test_v03_soak
