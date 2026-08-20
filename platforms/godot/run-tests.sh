#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$ROOT_DIR/tests"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# ---------------------------------------------------------------------------
# Find Godot binary
# ---------------------------------------------------------------------------
godot_bin=""
if command -v godot &>/dev/null; then
    godot_bin="godot"
elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
    godot_bin="/Applications/Godot.app/Contents/MacOS/Godot"
fi

if [[ -z "$godot_bin" ]]; then
    fail "Godot not found. Install Godot 4.x or set it on your PATH."
    exit 1
fi

log "Using Godot: $godot_bin"

# ---------------------------------------------------------------------------
# Ensure colyseus addon symlink is current
# ---------------------------------------------------------------------------
if [[ ! -L "$TEST_DIR/addons/colyseus" ]]; then
    ln -sf ../../addons/colyseus "$TEST_DIR/addons/colyseus"
    log "Created colyseus addon symlink"
fi

# ---------------------------------------------------------------------------
# Build the native library
# ---------------------------------------------------------------------------
log "Building native library..."
if ! (cd "$ROOT_DIR" && zig build); then
    fail "Build failed"
    exit 1
fi
log "Build complete"

# ---------------------------------------------------------------------------
# TLS fixtures for the wss:// test (test_wss.gd)
#   - generate the self-signed CA/server cert (gitignored)
#   - start a TLS proxy fronting example-server (2567) on wss://localhost:2568
# example-server is started here when it is not already running. Both it and
# the proxy are stopped on exit.
# ---------------------------------------------------------------------------
source "$ROOT_DIR/../../tests/dev-servers.sh"
servers_ensure example-server 2567 "$ROOT_DIR/../../example-server" \
    npx tsx src/index.ts || warn "tests that need :2567 will fail"
# the predict/input suites join the playground's lab rooms, not example-server
servers_ensure playground 5173 "$ROOT_DIR/../../../demos/prediction-tools" \
    npx vite --port 5173 --strictPort --host 0.0.0.0 || warn "predict suites will fail without :5173"

TLS_DIR="$TEST_DIR/tls"
if [[ ! -f "$TLS_DIR/server.pem" ]]; then
    log "Generating TLS test certificates..."
    bash "$ROOT_DIR/../../tests/tls/gen-certs.sh" "$TLS_DIR" >/dev/null
fi

tls_proxy_pid=""
cleanup() {
    [[ -n "$tls_proxy_pid" ]] && kill "$tls_proxy_pid" 2>/dev/null || true
    servers_stop
}
trap cleanup EXIT

if command -v node &>/dev/null; then
    log "Starting TLS proxy on wss://localhost:2568 -> 127.0.0.1:2567..."
    node "$TEST_DIR/tls-proxy.mjs" --port 2568 --target 2567 > /tmp/colyseus_tls_proxy.log 2>&1 &
    tls_proxy_pid=$!
    sleep 1
else
    warn "node not found — skipping TLS proxy; test_wss.gd will fail to connect"
fi

# ---------------------------------------------------------------------------
# Import project (needed on first run to generate .godot/ cache)
# ---------------------------------------------------------------------------
if [[ ! -d "$TEST_DIR/.godot" ]]; then
    log "Importing project (first run)..."
    "$godot_bin" --headless --path "$TEST_DIR" --import 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
log "Running tests..."
echo ""

OUTPUT_FILE=$(mktemp /tmp/godot_test_XXXXXXXX)

"$godot_bin" --headless -s addons/gut/gut_cmdln.gd --path "$TEST_DIR" \
    -gdir=res://test/ \
    > "$OUTPUT_FILE" 2>&1 || true

cat "$OUTPUT_FILE"
echo ""

# Parse results from output — look for "X/X passed" lines
TOTAL_PASSED=0
TOTAL_TESTS=0
while IFS= read -r line; do
    if [[ "$line" =~ ([0-9]+)/([0-9]+)\ passed ]]; then
        TOTAL_PASSED=$((TOTAL_PASSED + ${BASH_REMATCH[1]}))
        TOTAL_TESTS=$((TOTAL_TESTS + ${BASH_REMATCH[2]}))
    fi
done < "$OUTPUT_FILE"

rm -f "$OUTPUT_FILE"

if [[ $TOTAL_TESTS -gt 0 && $TOTAL_PASSED -eq $TOTAL_TESTS ]]; then
    log "All tests passed! ($TOTAL_PASSED/$TOTAL_TESTS)"
    exit 0
elif [[ $TOTAL_TESTS -gt 0 ]]; then
    fail "$TOTAL_PASSED/$TOTAL_TESTS tests passed"
    exit 1
else
    fail "No test results found in output"
    exit 1
fi
