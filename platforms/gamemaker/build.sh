#!/bin/bash

# Build script for Colyseus Game Maker Extension
# This script builds the Colyseus SDK for all Game Maker supported platforms
# and configures the extension .yy for the current platform.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building Colyseus Native SDK for Game Maker..."
echo ""

# Check if Zig is installed
if ! command -v zig &> /dev/null; then
    echo "Error: Zig is not installed. Please install Zig from https://ziglang.org/download/"
    exit 1
fi

# Parse arguments
BUILD_ALL=false
OPTIMIZE="ReleaseFast"

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            BUILD_ALL=true
            shift
            ;;
        --optimize=*)
            OPTIMIZE="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all              Build for all Game Maker platforms (Windows, macOS, Linux)"
            echo "  --optimize=MODE    Set optimization mode (Debug, ReleaseFast, ReleaseSmall, ReleaseSafe)"
            echo "  --help             Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help to see available options"
            exit 1
            ;;
    esac
done

# Build command
BUILD_CMD="zig build -Doptimize=$OPTIMIZE"

if [ "$BUILD_ALL" = true ]; then
    BUILD_CMD="$BUILD_CMD -Dall=true"
    echo "Building for all platforms..."
else
    echo "Building for native platform..."
fi

echo "Command: $BUILD_CMD"
echo ""

# Execute build
$BUILD_CMD

echo ""
echo "Build completed successfully!"
echo ""
echo "Output libraries are in: zig-out/lib/"
echo ""

# List built files
if command -v tree &> /dev/null; then
    tree zig-out/lib/
else
    find zig-out/lib/ -type f
fi

# =========================================================================
# Configure extension .yy for the current platform
# =========================================================================
# GameMaker only loads the FIRST kind:1 (native) file entry, ignoring
# copyToTargets. We must set the correct native binary as the first entry
# so GameMaker loads the right library for the current OS.

EXT_YY="$SCRIPT_DIR/example/BlankProject/extensions/Colyseus_SDK/Colyseus_SDK.yy"

if [ ! -f "$EXT_YY" ]; then
    echo ""
    echo "Warning: Extension .yy not found at $EXT_YY — skipping platform configuration."
    exit 0
fi

# Detect current platform
case "$(uname -s)" in
    Darwin*)  NATIVE_FILE="libcolyseus.dylib" ;;
    Linux*)   NATIVE_FILE="libcolyseus.so" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) NATIVE_FILE="colyseus.dll" ;;
    *)        echo "Warning: Unknown OS — skipping extension .yy configuration."; exit 0 ;;
esac

# GameMaker .yy files use trailing commas (not valid JSON).
fix_trailing_commas() {
    perl -0777 -pe '1 while s/,(\s*[\]\}])/$1/g' "$1"
}

echo ""
echo "=== Configuring extension .yy for $NATIVE_FILE ==="

# Extract functions from the first file entry (source of truth)
FUNCTIONS=$(fix_trailing_commas "$EXT_YY" | jq '.files[0].functions')

# Update the .yy: set the native filename and add functions to WASM entry
fix_trailing_commas "$EXT_YY" | jq \
  --arg native "$NATIVE_FILE" \
  --argjson funcs "$FUNCTIONS" '
  # Set native entry to current platform binary
  .files[0].filename = $native |
  .files[0].copyToTargets = -1 |
  .files[0].ProxyFiles = [] |

  # Add functions to WASM entry if it has none
  (if (.files[1].functions | length) == 0 then .files[1].functions = $funcs else . end)
' > "${EXT_YY}.tmp" && mv "${EXT_YY}.tmp" "$EXT_YY"

echo "Set native file entry to: $NATIVE_FILE"
echo "Done."
