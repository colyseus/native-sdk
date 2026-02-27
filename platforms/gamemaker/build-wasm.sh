#!/bin/bash
# Build Colyseus GameMaker Extension for HTML5 (WASM)
# Produces a single JS file with embedded WASM for use as a GM HTML5 extension.
#
# Requirements:
#   - Zig compiler (for building C/Zig SDK sources for wasm32-emscripten)
#   - Emscripten SDK (emcc) for final linking
#
# Usage: ./build-wasm.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Check prerequisites
if ! command -v zig &> /dev/null; then
    echo "Error: zig not found. Install from https://ziglang.org/download/"
    exit 1
fi

if ! command -v emcc &> /dev/null; then
    echo "Error: emcc not found. Install Emscripten SDK first."
    echo "  https://emscripten.org/docs/getting_started/downloads.html"
    exit 1
fi

OPTIMIZE="${1:-ReleaseSmall}"

echo "=== Stage 1: Building SDK libraries with Zig (wasm32-emscripten) ==="
cd "$ROOT_DIR"

# Detect Emscripten sysroot for C header resolution
EMSDK_SYSROOT=""
if command -v em-config &> /dev/null; then
    EM_CACHE=$(em-config CACHE 2>/dev/null || true)
    if [ -n "$EM_CACHE" ] && [ -d "$EM_CACHE/sysroot/include" ]; then
        EMSDK_SYSROOT="$EM_CACHE/sysroot/include"
    fi
fi

ZIG_ARGS="-Dtarget=wasm32-emscripten -Doptimize=$OPTIMIZE"
if [ -n "$EMSDK_SYSROOT" ]; then
    ZIG_ARGS="$ZIG_ARGS -Demsdk-sysroot=$EMSDK_SYSROOT"
    echo "Using Emscripten sysroot: $EMSDK_SYSROOT"
fi

zig build $ZIG_ARGS

echo ""
echo "=== Stage 2: Linking GameMaker WASM module with emcc ==="

OUTPUT_DIR="$SCRIPT_DIR/wasm-out"
mkdir -p "$OUTPUT_DIR"

# Collect all .a files produced by zig build
LIBS=$(find "$ROOT_DIR/zig-out/lib" -name '*.a' | tr '\n' ' ')

echo "Linking libraries: $LIBS"

emcc \
    -O2 \
    -DPLATFORM_WEB \
    -I "$ROOT_DIR/include" \
    -I "$ROOT_DIR/src" \
    -I "$ROOT_DIR/third_party/uthash/src" \
    -I "$ROOT_DIR/third_party/sds" \
    -I "$ROOT_DIR/third_party/cJSON" \
    "$SCRIPT_DIR/src/gamemaker_export.c" \
    $LIBS \
    -sSINGLE_FILE=1 \
    -sFETCH=1 \
    -lwebsocket.js \
    -sALLOW_MEMORY_GROWTH=1 \
    -sEXPORTED_RUNTIME_METHODS='["ccall","UTF8ToString"]' \
    -sEXPORTED_FUNCTIONS='["_malloc","_free"]' \
    -sINITIAL_MEMORY=16777216 \
    -sSTACK_SIZE=262144 \
    -sENVIRONMENT='web' \
    -sNO_EXIT_RUNTIME=1 \
    -sMODULARIZE=1 \
    -sEXPORT_NAME='ColyseusModule' \
    -o "$OUTPUT_DIR/colyseus_module.js"

# Concatenate WASM module + shim into final single file
cat "$OUTPUT_DIR/colyseus_module.js" "$SCRIPT_DIR/src/gamemaker_wasm_shim.js" > "$OUTPUT_DIR/colyseus_wasm.js"
rm "$OUTPUT_DIR/colyseus_module.js"

echo ""
echo "=== Build complete ==="
echo "Output: $OUTPUT_DIR/colyseus_wasm.js"
echo ""
echo "Copy this file into your GameMaker project's extension directory."
cp "$OUTPUT_DIR/colyseus_wasm.js" "$SCRIPT_DIR/example/BlankProject/extensions/Colyseus_SDK/" 2>/dev/null || true
