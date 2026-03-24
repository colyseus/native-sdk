#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT_DIR/example/BlankProject"
YYP="$PROJECT_DIR/BlankProject.yyp"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# ---------------------------------------------------------------------------
# Find Igor (GameMaker CLI build tool)
# ---------------------------------------------------------------------------
igor_bin=""
runtime_dir=""

for base in \
    "/Users/Shared/GameMakerStudio2/Cache/runtimes" \
    "$HOME/Library/Application Support/GameMakerStudio2/Cache/runtimes" \
    "$HOME/.config/gamemaker/runtimes"; do
  if [[ -d "$base" ]]; then
    for rt in "$base"/runtime-*; do
      if [[ -d "$rt" ]]; then runtime_dir="$rt"; fi
    done
  fi
done

if [[ -n "$runtime_dir" ]]; then
  for candidate in \
      "$runtime_dir/bin/igor/osx/arm64/Igor" \
      "$runtime_dir/bin/igor/osx/x86_64/Igor"; do
    if [[ -x "$candidate" ]]; then igor_bin="$candidate"; break; fi
  done
fi

if [[ -z "$igor_bin" ]]; then
  fail "GameMaker Igor not found."
  warn "Open GameMaker IDE and build once to install the runtime, then retry."
  exit 1
fi

log "Using Igor: $igor_bin"
log "Runtime: $runtime_dir"

# ---------------------------------------------------------------------------
# Find user directory (contains licence.plist)
# ---------------------------------------------------------------------------
user_dir=""
for d in "$HOME/Library/Application Support/GameMakerStudio2"/*_*/; do
  if [[ -f "${d}licence.plist" ]]; then user_dir="${d%/}"; break; fi
done

if [[ -z "$user_dir" ]]; then
  fail "GameMaker user/licence folder not found"
  exit 1
fi

# ---------------------------------------------------------------------------
# Build the native library
# ---------------------------------------------------------------------------
log "Building native library..."
if ! (cd "$ROOT_DIR" && zig build); then
  fail "Build failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# Copy latest dylib into extension
# ---------------------------------------------------------------------------
DYLIB_SRC="$ROOT_DIR/zig-out/lib/macos/arm64/libcolyseus.dylib"
DYLIB_DST="$PROJECT_DIR/extensions/Colyseus_SDK/libcolyseus.dylib"

cp "$DYLIB_SRC" "$DYLIB_DST"
log "Copied latest libcolyseus.dylib"

# ---------------------------------------------------------------------------
# Run via Igor (compiles + launches, output goes to stdout)
# ---------------------------------------------------------------------------
CACHE_DIR="$ROOT_DIR/.test-cache"
TEMP_DIR="$ROOT_DIR/.test-temp"
mkdir -p "$CACHE_DIR" "$TEMP_DIR"

log "Building and running tests..."
echo ""

OUTPUT_FILE=$(mktemp /tmp/colyseus_test_XXXXXX.log)
TIMEOUT=90

# Igor "Run" compiles and launches the game, debug output goes to stdout.
# Run in background so we can monitor for test completion.
DOTNET_SYSTEM_NET_DISABLEIPV6=1 "$igor_bin" \
    -j=8 \
    -r=VM \
    --rp="$runtime_dir" \
    --project="$YYP" \
    --uf="$user_dir" \
    --cache="$CACHE_DIR" \
    --temp="$TEMP_DIR" \
    -- Mac Run > "$OUTPUT_FILE" 2>&1 &
IGOR_PID=$!

# Wait for tests to complete, timeout, or Igor to exit
ELAPSED=0
while kill -0 "$IGOR_PID" 2>/dev/null; do
  if grep -q "Tests Finished!" "$OUTPUT_FILE" 2>/dev/null; then
    # Tests done — kill the game process
    sleep 1
    # Kill Igor and its child processes
    pkill -P "$IGOR_PID" 2>/dev/null || true
    kill "$IGOR_PID" 2>/dev/null || true
    wait "$IGOR_PID" 2>/dev/null || true
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    fail "Timeout (${TIMEOUT}s) — killing"
    pkill -P "$IGOR_PID" 2>/dev/null || true
    kill "$IGOR_PID" 2>/dev/null || true
    wait "$IGOR_PID" 2>/dev/null || true
    break
  fi
done

# ---------------------------------------------------------------------------
# Extract and display test output
# ---------------------------------------------------------------------------
echo ""

# Show only the test-relevant lines (from first "──" to "Tests Finished" + summary)
if grep -q "Tests Finished!" "$OUTPUT_FILE"; then
  # Print test results section
  sed -n '/^──/,/^All tests/p' "$OUTPUT_FILE"
  echo ""

  RESULT_LINE=$(grep "^Tests:" "$OUTPUT_FILE" | tail -1)

  if echo "$RESULT_LINE" | grep -q "100% success"; then
    log "All tests passed!"
    EXIT_CODE=0
  else
    fail "$RESULT_LINE"
    EXIT_CODE=1
  fi
else
  # Show last 30 lines for debugging
  echo "--- Last 30 lines of output ---"
  tail -30 "$OUTPUT_FILE"
  echo ""
  fail "Tests did not complete (no 'Tests Finished!' found in output)"
  EXIT_CODE=1
fi

# Cleanup
rm -f "$OUTPUT_FILE"
rm -rf "$TEMP_DIR"

exit $EXIT_CODE
