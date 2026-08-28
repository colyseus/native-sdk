#!/bin/bash
# Build the colyseus WASM library into build/, where platforms/raylib and the
# release workflow expect it.
#
# The source list lives in build.zig and nowhere else: this script used to keep
# its own copy of it, drifted 13 files behind, and produced an archive that
# compiled but could not link (no room_clock, input_handle, predict, quantize).
#
# Requires: zig, and emcc (emscripten) on PATH — build.zig finds the sysroot
# via em-config.
# Usage: ./build-wasm.sh [optimize]      # default ReleaseFast

set -e

if ! command -v zig &> /dev/null; then
    echo "Error: zig not found. Install from https://ziglang.org/download/"
    exit 1
fi

if ! command -v emcc &> /dev/null; then
    echo "Error: emcc not found. Please install Emscripten SDK first."
    echo "  https://emscripten.org/docs/getting_started/downloads.html"
    exit 1
fi

OPTIMIZE="${1:-ReleaseFast}"

echo "Building WASM library (-Doptimize=$OPTIMIZE)..."
zig build -Dtarget=wasm32-emscripten -Doptimize="$OPTIMIZE"

mkdir -p build

# Everything zig build installed: libcolyseus.a plus the archives it links
# against. A static lib does not absorb what it links against, so emcc needs
# them all at the final link. Globbing keeps this from becoming a second list.
cp zig-out/lib/*.a build/

echo "Done! WASM library built at: build/libcolyseus.a"
