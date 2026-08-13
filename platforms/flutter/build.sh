#!/bin/bash
# Build every platform's native library and stage it into the plugin folders,
# the same way CI does before publishing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIG_OUT="$SCRIPT_DIR/zig-out"
PLUGIN_DIR="$SCRIPT_DIR/colyseus"
LIB=libcolyseus_flutter

cd "$SCRIPT_DIR"

# One invocation per target. `-Dall` resolves the native_sdk dependency once,
# against the host, so its cross-target outputs do not link.
TARGETS=(
  aarch64-macos
  x86_64-macos
  aarch64-ios
  aarch64-ios-simulator
  x86_64-ios-simulator
  x86_64-linux-gnu
  x86_64-windows-gnu
)

if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  TARGETS+=(aarch64-linux-android arm-linux-androideabi x86_64-linux-android)
else
  echo "ANDROID_NDK_HOME unset: skipping the Android targets"
fi

for t in "${TARGETS[@]}"; do
  echo "==> $t"
  zig build -Dtarget="$t" -Doptimize=ReleaseFast -Dstrip=true
done

echo "==> xcframework"
"$SCRIPT_DIR/make-xcframework.sh" "$ZIG_OUT/lib"

echo "Staging into $PLUGIN_DIR"

stage() { # stage <src> <dest-dir> <dest-name>
  [ -e "$1" ] || return 0
  mkdir -p "$2"
  cp -R "$1" "$2/$3"
  echo "  ${2#$PLUGIN_DIR/}/$3"
}

# Both macOS slices share one destination filename, so they are fused rather
# than letting the second copy win.
if [ -f "$ZIG_OUT/lib/macos/arm64/$LIB.dylib" ] && [ -f "$ZIG_OUT/lib/macos/x64/$LIB.dylib" ]; then
  mkdir -p "$PLUGIN_DIR/macos/Libraries"
  lipo -create \
    "$ZIG_OUT/lib/macos/arm64/$LIB.dylib" \
    "$ZIG_OUT/lib/macos/x64/$LIB.dylib" \
    -output "$PLUGIN_DIR/macos/Libraries/$LIB.dylib"
  echo "  macos/Libraries/$LIB.dylib (universal)"
fi

stage "$ZIG_OUT/lib/ios/colyseus_flutter.xcframework" "$PLUGIN_DIR/ios/Frameworks" colyseus_flutter.xcframework
stage "$ZIG_OUT/lib/linux/x64/$LIB.so"                "$PLUGIN_DIR/linux/Libraries" "$LIB.so"
stage "$ZIG_OUT/lib/windows/x64/colyseus_flutter.dll" "$PLUGIN_DIR/windows/Libraries" colyseus_flutter.dll

for abi in arm64-v8a armeabi-v7a x86_64; do
  stage "$ZIG_OUT/lib/android/$abi/$LIB.so" "$PLUGIN_DIR/android/src/main/jniLibs/$abi" "$LIB.so"
done

echo "Done!"
