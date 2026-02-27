#!/usr/bin/env bash
# build.sh — Build Colyseus.xcframework for all Apple slices.
#
# Usage:
#   ./build.sh [release|debug]          # default: release
#   ./build.sh release --skip-zip       # skip zip archiving
#
# Outputs:
#   build/Colyseus.xcframework          # xcframework bundle
#   build/Colyseus.xcframework.zip      # distributable archive (for SPM)
#   build/Colyseus.xcframework.zip.sha256  # checksum for Package.swift
#
# Requirements: zig 0.15+, Xcode Command Line Tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
ZIG_OUT="$BUILD_DIR/zig-out"
XCF_DIR="$BUILD_DIR/Colyseus.xcframework"

OPTIMIZE="${1:-release}"
SKIP_ZIP="${2:-}"

case "$OPTIMIZE" in
  release) ZIG_OPT="-Doptimize=ReleaseFast" ;;
  debug)   ZIG_OPT="-Doptimize=Debug" ;;
  *)       echo "Unknown mode: $OPTIMIZE (use release or debug)"; exit 1 ;;
esac

# Slices to build.
# Each entry: "zig-target  sdk-name  slice-dir-name"
SLICES=(
  "aarch64-macos                macosx           macos-arm64"
  "x86_64-macos                 macosx           macos-x86_64"
  "aarch64-ios                  iphoneos         ios-arm64"
  "aarch64-ios-simulator        iphonesimulator  ios-arm64-simulator"
  "x86_64-ios-simulator         iphonesimulator  ios-x86_64-simulator"
  "aarch64-tvos                 appletvos        tvos-arm64"
  "aarch64-tvos-simulator       appletvsimulator tvos-arm64-simulator"
)

rm -rf "$XCF_DIR" "$ZIG_OUT"
mkdir -p "$BUILD_DIR"

echo "=== Building libcolyseus for all slices ==="

XCFRAMEWORK_ARGS=()

build_slice() {
  local ZIG_TARGET="$1"
  local SDK_NAME="$2"
  local SLICE_NAME="$3"

  local SLICE_OUT="$ZIG_OUT/$SLICE_NAME"
  mkdir -p "$SLICE_OUT"

  echo "  Building $ZIG_TARGET ($SDK_NAME) ..."

  local SDK_PATH
  SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path 2>/dev/null || true)"
  local SDK_ARG=""
  if [[ -n "$SDK_PATH" ]]; then
    SDK_ARG="-Dapple-sdk=$SDK_PATH"
  fi

  (
    cd "$SCRIPT_DIR"
    zig build \
      -Dtarget="$ZIG_TARGET" \
      $ZIG_OPT \
      $SDK_ARG \
      --prefix "$SLICE_OUT" \
      2>&1 | sed "s/^/    [$SLICE_NAME] /"
  )

  echo "  Done: $SLICE_OUT/lib/libcolyseus.a"
}

for SLICE_SPEC in "${SLICES[@]}"; do
  read -r ZIG_TARGET SDK_NAME SLICE_NAME <<< "$SLICE_SPEC"
  build_slice "$ZIG_TARGET" "$SDK_NAME" "$SLICE_NAME"
done

echo ""
echo "=== Assembling xcframework ==="

# Group slices by SDK for lipo (fat binary per SDK variant).
# macOS: lipo arm64 + x86_64 -> universal
# iOS device: single arm64
# iOS simulator: lipo arm64-sim + x86_64-sim -> universal
# tvOS device: single arm64
# tvOS simulator: single arm64-sim

lipo_or_copy() {
  local OUT_LIB="$1"; shift
  local INPUTS=("$@")
  if [[ ${#INPUTS[@]} -gt 1 ]]; then
    lipo -create "${INPUTS[@]}" -output "$OUT_LIB"
  else
    cp "${INPUTS[0]}" "$OUT_LIB"
  fi
}

# Copy headers from any slice (they're identical).
# zig-out installs colyseus headers into include/colyseus/; we copy the
# entire include tree plus our umbrella header and module map.
HEADERS_SRC="$ZIG_OUT/macos-arm64/include"
HEADERS_DST="$BUILD_DIR/Headers"
rm -rf "$HEADERS_DST"
cp -R "$HEADERS_SRC" "$HEADERS_DST"
# Umbrella header and module map must live at the top of the Headers dir.
cp "$SCRIPT_DIR/include/colyseus_swift.h" "$HEADERS_DST/"
cp "$SCRIPT_DIR/include/module.modulemap" "$HEADERS_DST/"

build_variant() {
  local VARIANT_NAME="$1"; shift
  local LIB_DIR="$BUILD_DIR/libs/$VARIANT_NAME"
  mkdir -p "$LIB_DIR"
  local OUT_LIB="$LIB_DIR/libcolyseus.a"
  lipo_or_copy "$OUT_LIB" "$@"
  # xcframework needs headers alongside each library.
  local HDR_DIR="$LIB_DIR/Headers"
  cp -R "$HEADERS_DST" "$HDR_DIR"
  XCFRAMEWORK_ARGS+=("-library" "$OUT_LIB" "-headers" "$HDR_DIR")
}

build_variant "macos" \
  "$ZIG_OUT/macos-arm64/lib/libcolyseus.a" \
  "$ZIG_OUT/macos-x86_64/lib/libcolyseus.a"

build_variant "ios" \
  "$ZIG_OUT/ios-arm64/lib/libcolyseus.a"

build_variant "ios-simulator" \
  "$ZIG_OUT/ios-arm64-simulator/lib/libcolyseus.a" \
  "$ZIG_OUT/ios-x86_64-simulator/lib/libcolyseus.a"

build_variant "tvos" \
  "$ZIG_OUT/tvos-arm64/lib/libcolyseus.a"

build_variant "tvos-simulator" \
  "$ZIG_OUT/tvos-arm64-simulator/lib/libcolyseus.a"

xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "$XCF_DIR"

echo ""
echo "=== xcframework built: $XCF_DIR ==="

if [[ "$SKIP_ZIP" != "--skip-zip" ]]; then
  echo ""
  echo "=== Archiving ==="
  ZIP_PATH="$BUILD_DIR/Colyseus.xcframework.zip"
  (cd "$BUILD_DIR" && zip -qr "$(basename "$ZIP_PATH")" Colyseus.xcframework)
  CHECKSUM=$(swift package compute-checksum "$ZIP_PATH" 2>/dev/null || shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
  echo "$CHECKSUM" > "$ZIP_PATH.sha256"
  echo "Archive: $ZIP_PATH"
  echo "Checksum: $CHECKSUM"
  echo ""
  echo "Update Package.swift binaryTarget checksum with: $CHECKSUM"
fi

echo ""
echo "Done."
