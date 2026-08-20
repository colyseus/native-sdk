#!/bin/bash
# Fuse the iOS slices into an xcframework.
#
#   ./make-xcframework.sh <libs-dir>
#
# Reads <libs-dir>/ios/{device-arm64,simulator-arm64,simulator-x64} and writes
# <libs-dir>/ios/colyseus_flutter.xcframework.
#
# Device arm64 and simulator arm64 are both arm64, and lipo refuses to put two
# slices of one architecture in a single archive. So only the two simulator
# slices fuse; keeping the device slice apart from them is what an xcframework
# is for.
set -euo pipefail

LIBS="${1:?usage: make-xcframework.sh <libs-dir>}"
LIBS="$(cd "$LIBS" && pwd)"

IOS="$LIBS/ios"
LIB=libcolyseus_flutter.a
OUT="$IOS/colyseus_flutter.xcframework"

for slice in device-arm64 simulator-arm64 simulator-x64; do
  if [ ! -f "$IOS/$slice/$LIB" ]; then
    echo "error: missing $IOS/$slice/$LIB" >&2
    exit 1
  fi
done

SIM_DIR="$(mktemp -d)"
lipo -create "$IOS/simulator-arm64/$LIB" "$IOS/simulator-x64/$LIB" -output "$SIM_DIR/$LIB"

# xcodebuild refuses to write over an existing bundle, and a stale one would
# quietly keep its old slices. Replace only a path this script produces.
case "$OUT" in
  *.xcframework)
    if [ -d "$OUT" ]; then
      rm -rf "${OUT:?output path unset}"
    fi
    ;;
  *)
    echo "error: refusing to replace $OUT" >&2
    exit 1
    ;;
esac

xcodebuild -create-xcframework \
  -library "$IOS/device-arm64/$LIB" \
  -library "$SIM_DIR/$LIB" \
  -output "$OUT" >/dev/null

echo "Built $OUT"
for slice in "$OUT"/*/; do
  printf '  %s: %s\n' "$(basename "$slice")" "$(lipo -archs "$slice/$LIB")"
done
