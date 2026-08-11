#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIG_OUT="$SCRIPT_DIR/zig-out"
PLUGIN_DIR="$SCRIPT_DIR/colyseus_flutter"

echo "Building colyseus_flutter native library..."

# Build for all platforms
cd "$SCRIPT_DIR"
zig build -Dall -Doptimize=ReleaseFast

echo "Copying libraries to Flutter plugin directories..."

# Android
for arch in arm64-v8a armeabi-v7a x86_64; do
    src="$ZIG_OUT/lib/android/$arch"
    dst="$PLUGIN_DIR/android/src/main/jniLibs/$arch"
    if [ -d "$src" ]; then
        mkdir -p "$dst"
        cp "$src"/libcolyseus_flutter.so "$dst/"
        echo "  -> android/$arch"
    fi
done

# iOS (static library)
if [ -d "$ZIG_OUT/lib/ios/arm64" ]; then
    mkdir -p "$PLUGIN_DIR/ios/Libraries"
    cp "$ZIG_OUT/lib/ios/arm64/libcolyseus_flutter.a" "$PLUGIN_DIR/ios/Libraries/"
    echo "  -> ios/arm64"
fi

# macOS
for arch in arm64 x64; do
    src="$ZIG_OUT/lib/macos/$arch"
    if [ -d "$src" ]; then
        mkdir -p "$PLUGIN_DIR/macos/Libraries"
        cp "$src"/libcolyseus_flutter.dylib "$PLUGIN_DIR/macos/Libraries/"
        echo "  -> macos/$arch"
    fi
done

# Linux
if [ -d "$ZIG_OUT/lib/linux/x64" ]; then
    mkdir -p "$PLUGIN_DIR/linux/Libraries"
    cp "$ZIG_OUT/lib/linux/x64/libcolyseus_flutter.so" "$PLUGIN_DIR/linux/Libraries/"
    echo "  -> linux/x64"
fi

# Windows
if [ -d "$ZIG_OUT/lib/windows/x64" ]; then
    mkdir -p "$PLUGIN_DIR/windows/Libraries"
    cp "$ZIG_OUT/lib/windows/x64/colyseus_flutter.dll" "$PLUGIN_DIR/windows/Libraries/"
    echo "  -> windows/x64"
fi

echo "Done!"
