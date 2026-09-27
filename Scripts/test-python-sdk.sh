#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHONPATH="$ROOT_DIR/SDKs/python/src" /usr/bin/python3 -m unittest discover \
    -s "$ROOT_DIR/SDKs/python/tests" -v
