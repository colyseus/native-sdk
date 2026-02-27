#!/bin/bash

# Build script for Colyseus Game Maker Extension
# This script builds the Colyseus SDK for all Game Maker supported platforms

set -e

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

