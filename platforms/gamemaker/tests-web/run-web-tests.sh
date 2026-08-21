#!/bin/bash
# Build the wasm bundle and run the browser smoke suite against the
# prediction-tools playground server.
#
# Prerequisites: emsdk (emcc), node, and the playground server running:
#   cd ../../../demos/prediction-tools && pnpm dev --host 0.0.0.0
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

PLAYGROUND_PORT="${COLYSEUS_PLAYGROUND_PORT:-5173}"
if ! curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PLAYGROUND_PORT"; then
    echo "[ERROR] playground server not reachable on :$PLAYGROUND_PORT"
    echo "        cd demos/prediction-tools && pnpm dev --host 0.0.0.0"
    exit 2
fi

./build-wasm.sh
node tests-web/web-tests.mjs
