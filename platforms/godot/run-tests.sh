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
