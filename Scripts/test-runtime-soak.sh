#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Deterministic hours-equivalent lifecycle/PCM churn. Override any count for a
# scheduled 30-minute or overnight run without changing the test binary.
: "${SONEXIS_STRESS_CAPTURE_CYCLES:=10000}"
: "${SONEXIS_STRESS_OUTPUT_CYCLES:=10000}"
: "${SONEXIS_STRESS_CONNECTION_CYCLES:=2000}"
: "${SONEXIS_STRESS_PCM_BURST_CYCLES:=2000}"
export SONEXIS_STRESS_CAPTURE_CYCLES SONEXIS_STRESS_OUTPUT_CYCLES
export SONEXIS_STRESS_CONNECTION_CYCLES SONEXIS_STRESS_PCM_BURST_CYCLES

exec "$ROOT_DIR/Scripts/test-runtime-stress.sh"
