#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TRANSITIONS=${AUDIOPLANE_TORTURE_TRANSITIONS:-1000000}
TURNS=${AUDIOPLANE_TORTURE_TURNS:-1000}
INTERRUPTIONS=${AUDIOPLANE_TORTURE_INTERRUPTS:-1000}

PYTHONPATH="$ROOT_DIR/SDKs/python/src" \
python3 "$ROOT_DIR/SDKs/python/tests/agent_torture.py" \
    --transitions "$TRANSITIONS" \
    --turns "$TURNS" \
    --interruptions "$INTERRUPTIONS"
