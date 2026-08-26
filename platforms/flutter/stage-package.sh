#!/bin/bash
# Assemble the publishable `colyseus` package: the committed package tree plus
# the prebuilt native libraries.
#
#   ./stage-package.sh <libs-dir> <staging-dir>
#
# <libs-dir> is a zig-out/lib-shaped tree (macos/arm64, ios/arm64, android/…),
# merged from every build job. <staging-dir> is created fresh.
#
# The staging dir lives outside the repo on purpose: pub drops any file that a
# .gitignore matches, even a checked-in one, so the libraries can only ship
# from a directory that git does not track.
set -euo pipefail

LIBS="${1:?usage: stage-package.sh <libs-dir> <staging-dir>}"
STAGE="${2:?usage: stage-package.sh <libs-dir> <staging-dir>}"

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
PKG_PATH="platforms/flutter/colyseus"
# What gets published is the tagged commit, not the working tree. Override to
# stage an unreleased revision or a bare tree object.
PACKAGE_REF="${PACKAGE_REF:-HEAD}"

LIBS="$(cd "$LIBS" && pwd)"

# Reuse the staging dir only when it is recognisably a previous run of this
# script. Anything else is someone's real directory, and the caller controls
# this path.
if [ -e "$STAGE" ] && [ -n "$(ls -A "$STAGE" 2>/dev/null)" ]; then
  if grep -qx 'name: colyseus' "$STAGE/pubspec.yaml" 2>/dev/null; then
    rm -rf "${STAGE:?staging dir unset}"
  else
    echo "error: $STAGE is not empty and was not staged by this script; remove it yourself" >&2
    exit 1
  fi
fi
mkdir -p "$STAGE"
STAGE="$(cd "$STAGE" && pwd)"

# Exactly the committed tree — no local build droppings, no .dart_tool.
git -C "$REPO_ROOT" archive "$PACKAGE_REF:$PKG_PATH" | tar -x -C "$STAGE"

missing=0
place() { # place <src> <dest-dir> <dest-name>
  # -e, not -f: the iOS artifact is an xcframework bundle, not a file.
  if [ ! -e "$1" ]; then
    echo "  MISSING $1"
    missing=1
    return
  fi
  mkdir -p "$2"
  cp -R "$1" "$2/$3"
  echo "  $(du -sh "$2/$3" | cut -f1)	${2#$STAGE/}/$3"
}

echo "Staging native libraries:"
place "$LIBS/macos/universal/libcolyseus_flutter.dylib" "$STAGE/macos/Libraries" libcolyseus_flutter.dylib
place "$LIBS/ios/colyseus_flutter.xcframework"          "$STAGE/ios/Frameworks"  colyseus_flutter.xcframework
place "$LIBS/linux/x64/libcolyseus_flutter.so"          "$STAGE/linux/Libraries" libcolyseus_flutter.so
place "$LIBS/windows/x64/colyseus_flutter.dll"          "$STAGE/windows/Libraries" colyseus_flutter.dll
for abi in arm64-v8a armeabi-v7a x86_64; do
  place "$LIBS/android/$abi/libcolyseus_flutter.so" "$STAGE/android/src/main/jniLibs/$abi" libcolyseus_flutter.so
done

if [ "$missing" -ne 0 ]; then
  echo "error: a platform library is missing; publishing would ship a package that cannot build there." >&2
  exit 1
fi

echo "Staged $PKG_PATH -> $STAGE"
