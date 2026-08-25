#!/bin/bash
# Build the wasm bundle and run the browser smoke suite against the
# prediction-tools playground server (started here when it isn't up; the
# same COLYSEUS_PLAYGROUND_PORT / _ENDPOINT knobs as run-tests.sh).
#
# Prerequisites: emsdk (emcc), node.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source ../../tests/dev-servers.sh
trap servers_stop EXIT
PLAYGROUND_PORT="${COLYSEUS_PLAYGROUND_PORT:-5173}"
servers_ensure playground "$PLAYGROUND_PORT" ../../../demos/prediction-tools \
    npx vite --port "$PLAYGROUND_PORT" --strictPort --host 0.0.0.0 || exit 2
export COLYSEUS_PLAYGROUND_ENDPOINT="${COLYSEUS_PLAYGROUND_ENDPOINT:-http://127.0.0.1:$PLAYGROUND_PORT}"

./build-wasm.sh
node tests-web/web-tests.mjs
