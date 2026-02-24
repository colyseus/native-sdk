#!/bin/bash
# Build colyseus WASM library
# Requires: emcc (emscripten) to be installed and in PATH
# Usage: ./build-wasm.sh

set -e

if ! command -v emcc &> /dev/null; then
    echo "Error: emcc not found. Please install Emscripten SDK first."
    echo "  https://emscripten.org/docs/getting_started/downloads.html"
    exit 1
fi

mkdir -p build

CFLAGS="-O2 -DPLATFORM_WEB -I include -I src -I third_party/uthash/src -I third_party/sds -I third_party/cJSON"

echo "Compiling C sources to WASM objects..."

emcc -c $CFLAGS src/common/settings.c -o build/settings.o
emcc -c $CFLAGS src/client.c -o build/client.o
emcc -c $CFLAGS src/room.c -o build/room.o
emcc -c $CFLAGS src/network/websocket_transport_web.c -o build/websocket_transport_web.o
emcc -c $CFLAGS src/network/http_web.c -o build/http_web.o
emcc -c $CFLAGS src/schema/decode.c -o build/decode.o
emcc -c $CFLAGS src/schema/ref_tracker.c -o build/ref_tracker.o
emcc -c $CFLAGS src/schema/collections.c -o build/collections.o
emcc -c $CFLAGS src/schema/decoder.c -o build/decoder.o
emcc -c $CFLAGS src/schema/serializer.c -o build/serializer.o
emcc -c $CFLAGS src/schema/callbacks.c -o build/callbacks.o
emcc -c $CFLAGS src/schema/dynamic_schema.c -o build/dynamic_schema.o
emcc -c $CFLAGS src/utils/strUtil.c -o build/strUtil.o
emcc -c $CFLAGS src/utils/sha1_c.c -o build/sha1_c.o
emcc -c $CFLAGS src/auth/auth.c -o build/auth.o
emcc -c $CFLAGS src/auth/secure_storage.c -o build/secure_storage.o
emcc -c $CFLAGS third_party/sds/sds.c -o build/sds.o
emcc -c $CFLAGS third_party/cJSON/cJSON.c -o build/cJSON.o

echo "Creating static library..."
emar rcs build/libcolyseus.a build/*.o

echo "Done! WASM library built at: build/libcolyseus.a"
