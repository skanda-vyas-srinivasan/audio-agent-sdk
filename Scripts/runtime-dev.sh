#!/bin/sh
set -eu

PREFIX=${SONEXIS_DEV_PREFIX:-"$HOME/Library/Application Support/SonexisRuntime/dev"}
STATE_DIR=${SONEXIS_RUNTIME_STATE_DIR:-"$HOME/Library/Application Support/SonexisRuntime/state"}
USER_TEMP_DIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
if [ -z "$USER_TEMP_DIR" ]; then
    USER_TEMP_DIR=${TMPDIR:-/tmp}
fi
RUNTIME_DIR=${SONEXIS_RUNTIME_DIR:-"${USER_TEMP_DIR%/}/sx-$(id -u)"}
if [ -d "$PREFIX" ] && [ ! -L "$PREFIX" ]; then
    PREFIX=$(CDPATH= cd -- "$PREFIX" && pwd -P)
fi
RUNTIME_BIN="$PREFIX/bin/sonexis-runtime"
CTL_BIN="$PREFIX/bin/sonexisctl"
PID_FILE="$STATE_DIR/runtime.pid"
LOG_FILE="$STATE_DIR/runtime.log"
CONTROL_SOCKET="$RUNTIME_DIR/control.sock"

usage() {
    echo "Usage: $0 {start|status|stop|foreground|logs}" >&2
}

validate_state_directory() {
    if [ -e "$STATE_DIR" ]; then
        [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || {
            echo "Runtime state path is not a real directory: $STATE_DIR" >&2
            exit 1
        }
        [ "$(stat -f %u "$STATE_DIR")" = "$(id -u)" ] || {
            echo "Runtime state directory belongs to another user: $STATE_DIR" >&2
            exit 1
        }
    fi
    [ ! -L "$PID_FILE" ] || {
        echo "Refusing symbolic-link PID file: $PID_FILE" >&2
        exit 1
    }
    [ ! -L "$LOG_FILE" ] || {
        echo "Refusing symbolic-link log file: $LOG_FILE" >&2
        exit 1
    }
}

require_install() {
    [ -x "$RUNTIME_BIN" ] && [ ! -L "$RUNTIME_BIN" ] || {
        echo "Sonexis Runtime is not installed at $PREFIX" >&2
        echo "Run Scripts/install-runtime-dev.sh first." >&2
        exit 1
    }
    [ -x "$CTL_BIN" ] && [ ! -L "$CTL_BIN" ] || {
        echo "sonexisctl is not installed at $PREFIX" >&2
        exit 1
    }
}

runtime_status() {
    "$CTL_BIN" status --json --socket "$CONTROL_SOCKET" 2>/dev/null
}

read_pid() {
    [ -f "$PID_FILE" ] && [ ! -L "$PID_FILE" ] || return 1
    MANAGED_PID=$(sed -n '1p' "$PID_FILE")
    case "$MANAGED_PID" in
        ''|*[!0-9]*) return 1 ;;
    esac
    MANAGED_INSTANCE=$(sed -n '2p' "$PID_FILE")
    [ -n "$MANAGED_INSTANCE" ] || return 1
    return 0
}

status_instance() {
    printf '%s' "$1" | plutil -extract runtime_instance_id raw -o - - 2>/dev/null
}

pid_is_managed_runtime() {
    kill -0 "$MANAGED_PID" 2>/dev/null || return 1
    EXECUTABLE=$(/usr/sbin/lsof -a -p "$MANAGED_PID" -d txt -Fn 2>/dev/null \
        | sed -n 's/^n//p' | head -n 1)
    [ "$EXECUTABLE" = "$RUNTIME_BIN" ]
}

COMMAND=${1:-}
case "$COMMAND" in
    start)
        require_install
        validate_state_directory
        if STATUS=$(runtime_status); then
            if read_pid && pid_is_managed_runtime && \
                [ "$(status_instance "$STATUS")" = "$MANAGED_INSTANCE" ]; then
                echo "Sonexis Runtime is already running at $CONTROL_SOCKET"
            else
                echo "A compatible Runtime is active at $CONTROL_SOCKET, but it is not " \
                    "the confirmed managed process for this lifecycle script."
            fi
            echo "$STATUS"
            exit 0
        fi
        mkdir -p "$STATE_DIR"
        chmod 700 "$STATE_DIR"
        if read_pid && pid_is_managed_runtime; then
            echo "Managed Runtime process $MANAGED_PID exists but is not healthy." >&2
            echo "Inspect $LOG_FILE; refusing to start a second instance." >&2
            exit 1
        fi
        rm -f "$PID_FILE"
        if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 1048576 ]; then
            rm -f "$LOG_FILE.previous"
            mv "$LOG_FILE" "$LOG_FILE.previous"
        fi
        nohup env SONEXIS_RUNTIME_DIR="$RUNTIME_DIR" "$RUNTIME_BIN" >>"$LOG_FILE" 2>&1 &
        MANAGED_PID=$!
        ATTEMPTS=0
        while [ "$ATTEMPTS" -lt 50 ]; do
            if STATUS=$(runtime_status); then
                MANAGED_INSTANCE=$(status_instance "$STATUS")
                PID_TEMP="$STATE_DIR/.runtime.pid.$$"
                printf '%s\n%s\n' "$MANAGED_PID" "$MANAGED_INSTANCE" > "$PID_TEMP"
                chmod 600 "$PID_TEMP"
                mv "$PID_TEMP" "$PID_FILE"
                echo "Started Sonexis Runtime (pid $MANAGED_PID)"
                echo "$STATUS"
                exit 0
            fi
            if ! kill -0 "$MANAGED_PID" 2>/dev/null; then
                break
            fi
            ATTEMPTS=$((ATTEMPTS + 1))
            sleep 0.1
        done
        if pid_is_managed_runtime; then
            kill -TERM "$MANAGED_PID"
        fi
        rm -f "$PID_FILE"
        echo "Sonexis Runtime failed to become ready; inspect $LOG_FILE" >&2
        exit 1
        ;;
    status)
        require_install
        validate_state_directory
        if STATUS=$(runtime_status); then
            if read_pid && pid_is_managed_runtime; then
                echo "Sonexis Runtime is running (managed pid $MANAGED_PID)"
            else
                echo "Sonexis Runtime is running but was not started by this lifecycle script"
            fi
            echo "$STATUS"
            exit 0
        fi
        echo "Sonexis Runtime is not reachable at $CONTROL_SOCKET"
        exit 1
        ;;
    stop)
        require_install
        validate_state_directory
        if ! read_pid; then
            if runtime_status >/dev/null; then
                echo "A Runtime is active but has no trusted managed PID; stop its foreground process directly." >&2
                exit 1
            fi
            echo "Sonexis Runtime is not running"
            exit 0
        fi
        if ! pid_is_managed_runtime; then
            rm -f "$PID_FILE"
            echo "Removed stale Runtime PID metadata; no process was signalled"
            exit 0
        fi
        if ! STATUS=$(runtime_status); then
            echo "Managed Runtime is not responding; refusing to signal it automatically." >&2
            echo "Inspect $LOG_FILE and process $MANAGED_PID." >&2
            exit 1
        fi
        LIVE_INSTANCE=$(status_instance "$STATUS")
        if [ "$LIVE_INSTANCE" != "$MANAGED_INSTANCE" ]; then
            echo "Runtime instance identity changed; refusing to signal process $MANAGED_PID." >&2
            exit 1
        fi
        kill -TERM "$MANAGED_PID"
        ATTEMPTS=0
        while kill -0 "$MANAGED_PID" 2>/dev/null && [ "$ATTEMPTS" -lt 50 ]; do
            ATTEMPTS=$((ATTEMPTS + 1))
            sleep 0.1
        done
        if kill -0 "$MANAGED_PID" 2>/dev/null; then
            echo "Runtime did not stop within five seconds; refusing to force-kill it." >&2
            exit 1
        fi
        rm -f "$PID_FILE"
        echo "Stopped Sonexis Runtime"
        ;;
    foreground)
        require_install
        exec env SONEXIS_RUNTIME_DIR="$RUNTIME_DIR" "$RUNTIME_BIN"
        ;;
    logs)
        validate_state_directory
        [ -f "$LOG_FILE" ] || { echo "No Runtime log at $LOG_FILE"; exit 0; }
        tail -n 100 "$LOG_FILE"
        ;;
    *) usage; exit 2 ;;
esac
