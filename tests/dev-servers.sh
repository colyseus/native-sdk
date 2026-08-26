# Bring up the servers the engine suites drive, when they aren't up already.
# Sourced by platforms/*/run-tests.sh, and so by the pre-push hook.
#
# Only a server started HERE is stopped again: one that was already running
# survives, so a test run can't kill the session you are debugging against.

_colyseus_spawned_ports=()

servers_up() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1"; }

# Does the server on <port> define <room>? An undefined room answers 520; a
# defined one answers 521 (no instance yet) or a seat reservation.
servers_defines_room() {
    local body
    body=$(curl -s --max-time 5 -X POST "http://127.0.0.1:$1/matchmake/join/$2" \
        -H 'Content-Type: application/json' -d '{}') || return 1
    [[ -n "$body" && "$body" != *'"code":520'* ]]
}

# ...and all of <rooms>? Name every room the suites need, not just one: another
# Colyseus project can define a room of the same name (sdks-test-server answers
# for my_room but knows nothing of view_test_room).
servers_defines_rooms() {
    local port="$1" room
    shift
    for room in "$@"; do
        servers_defines_room "$port" "$room" || return 1
    done
}

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

# servers_ensure [--room <name>]... <label> <port> <dir> <cmd...>; non-zero if
# it never answered, or if --room says the port belongs to someone else
servers_ensure() {
    local rooms=()
    while [[ "${1:-}" == "--room" ]]; do rooms+=("$2"); shift 2; done
    local label="$1" port="$2" dir="$3"
    shift 3
    if servers_up "$port"; then
        # another project's dev server can hold the port (air-hockey binds
        # :5173, sdks-test-server binds :2567) — testing against one of those
        # fails whole suites for the wrong reason
        if ! servers_defines_rooms "$port" ${rooms[@]+"${rooms[@]}"}; then
            echo "[servers] :$port is held by a server missing the $label's rooms (${rooms[*]})"
            return 1
        fi
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
    until servers_up "$port" && servers_defines_rooms "$port" ${rooms[@]+"${rooms[@]}"}; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge 90 ]]; then
            echo "[servers] $label never answered on :$port, see $logfile"
            return 1
        fi
    done
    echo "[servers] $label ready on :$port"
}
