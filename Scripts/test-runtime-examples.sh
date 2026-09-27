#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON=${PYTHON:-/usr/bin/python3}
if [ "${SONEXIS_EXAMPLES_USE_INSTALLED:-0}" = "1" ]; then
    unset PYTHONPATH
else
    export PYTHONPATH="$ROOT_DIR/SDKs/python/src"
fi

for example in \
    capture-one-source.py \
    capture-multiple-sources.py \
    playback.py \
    duplex.py \
    python-runtime-client.py \
    python-runtime-monitor.py \
    multi-source-runtime.py \
    multi-source-agent.py \
    provider-output.py
do
    "$PYTHON" -m py_compile "$ROOT_DIR/Examples/$example"
    "$PYTHON" "$ROOT_DIR/Examples/$example" --help >/dev/null
done

"$PYTHON" -m py_compile "$ROOT_DIR/Examples/audio-agent/audio_agent.py"
"$PYTHON" "$ROOT_DIR/Examples/audio-agent/audio_agent.py" --help >/dev/null
"$PYTHON" -m sonexis.mcp_server --help >/dev/null

echo "Runtime public example syntax/import/help smoke passed"
