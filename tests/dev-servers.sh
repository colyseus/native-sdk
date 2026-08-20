# Bring up the servers the engine suites drive, when they aren't up already.
# Sourced by platforms/*/run-tests.sh, and so by the pre-push hook.
#
# Only a server started HERE is stopped again: one that was already running
# survives, so a test run can't kill the session you are debugging against.

_colyseus_spawned_ports=()

servers_up() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1"; }

servers_stop() {
    if [[ ${#_colyseus_spawned_ports[@]} -eq 0 ]]; then return 0; fi
    local port pid
    for port in "${_colyseus_spawned_ports[@]}"; do
        # kill the listener, not the launcher: npx/pnpm leave the real server
        # in a grandchild the launcher's pid never reaches
        for pid in $(lsof -ti "tcp:$port" 2>/dev/null || true); do
            kill "$pid" 2>/dev/null || true
        done
    done
    _colyseus_spawned_ports=()
}

# servers_ensure <label> <port> <dir> <cmd...>; non-zero if it never answered
servers_ensure() {
    local label="$1" port="$2" dir="$3"
    shift 3
    if servers_up "$port"; then
        echo "[servers] $label already up on :$port"
        return 0
    fi
    if [[ ! -d "$dir" ]]; then
        echo "[servers] no $label checkout at $dir"
        return 1
    fi
    local logfile="/tmp/colyseus_${label}.log"
    echo "[servers] starting $label on :$port ($logfile)"
    ( cd "$dir" && exec "$@" ) > "$logfile" 2>&1 &
    _colyseus_spawned_ports+=("$port")

    local waited=0
    until servers_up "$port"; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge 90 ]]; then
            echo "[servers] $label never answered on :$port, see $logfile"
            return 1
        fi
    done
    echo "[servers] $label ready on :$port"
}
