#!/bin/sh
# Exercise the native speech detector with offline macOS synthesized words.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_PYTHON="$ROOT_DIR/.venv/bin/python"
if [ ! -x "$TASK_PYTHON" ]; then
    TASK_PYTHON=python3
fi
"$TASK_PYTHON" -c 'import webrtcvad' || {
    printf '%s\n' 'Install the Gemini extra or webrtcvad-wheels in your Python environment.' >&2
    exit 1
}
TASK_FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/audioplane-vad.XXXXXX")
trap 'rm -f "$TASK_FIXTURE_DIR/speech.aiff" "$TASK_FIXTURE_DIR/speech.wav"; rmdir "$TASK_FIXTURE_DIR"' EXIT HUP INT TERM
/usr/bin/say -o "$TASK_FIXTURE_DIR/speech.aiff" \
    'Hello Gemini. Can you hear me? Tell me a very short story.'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 \
    "$TASK_FIXTURE_DIR/speech.aiff" "$TASK_FIXTURE_DIR/speech.wav"
AUDIOPLANE_VAD_SPEECH_FIXTURE="$TASK_FIXTURE_DIR/speech.wav" \
PYTHONPATH="$ROOT_DIR/SDKs/python/src" \
    "$TASK_PYTHON" -m unittest discover -s "$ROOT_DIR/SDKs/python/tests" \
    -p test_speech_vad.py -v
