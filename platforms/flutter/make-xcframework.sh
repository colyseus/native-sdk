#!/bin/bash
# Build the iOS xcframework the podspec vendors.
#
#   ./make-xcframework.sh <libs-dir>
#
# Reads <libs-dir>/ios/{device-arm64,simulator-arm64,simulator-x64} and writes
# <libs-dir>/ios/colyseus_flutter.xcframework.
#
# Each static archive is linked into a dynamic colyseus_flutter.framework,
# which the app embeds and Dart opens by name. Linked statically into the app,
# nothing references the library at link time, so it needs -force_load to be
# pulled in at all, and then dead stripping and the strip step of an archive
# build remove every symbol Dart looks up (issue #35).
#
# Device arm64 and simulator arm64 are both arm64, and lipo refuses to put two
# slices of one architecture in a single binary. So only the two simulator
# slices fuse; keeping the device slice apart from them is what an xcframework
# is for.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBS="${1:?usage: make-xcframework.sh <libs-dir>}"
LIBS="$(cd "$LIBS" && pwd)"

IOS="$LIBS/ios"
LIB=libcolyseus_flutter.a
NAME=colyseus_flutter
OUT="$IOS/$NAME.xcframework"
MIN_IOS=13.0 # keep in step with ios_min in build.zig and the podspec
VERSION="$(awk '/^version:/ { print $2; exit }' "$SCRIPT_DIR/colyseus/pubspec.yaml")"

for slice in device-arm64 simulator-arm64 simulator-x64; do
  if [ ! -f "$IOS/$slice/$LIB" ]; then
    echo "error: missing $IOS/$slice/$LIB" >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# framework <sdk> <platform> <target-suffix> <arch>:<slice>...
framework() {
  local sdk="$1" platform="$2" suffix="$3"; shift 3
  local dir="$WORK/$sdk/$NAME.framework" bins=() arch slice
  mkdir -p "$dir"
  for pair in "$@"; do
    arch="${pair%%:*}" slice="${pair#*:}"
    xcrun -sdk "$sdk" clang -target "$arch-apple-ios$MIN_IOS$suffix" -dynamiclib \
      -Wl,-force_load,"$IOS/$slice/$LIB" \
      -framework CoreFoundation -framework Security \
      -install_name "@rpath/$NAME.framework/$NAME" \
      -o "$WORK/$sdk/$NAME.$arch"
    bins+=("$WORK/$sdk/$NAME.$arch")
  done
  lipo -create "${bins[@]}" -output "$dir/$NAME"
  # stat/fstat (mbedtls, Zig's file reads) and mach_absolute_time are APIs
  # App Store Connect wants a reason for, read from the framework's own manifest.
  cp "$SCRIPT_DIR/PrivacyInfo.xcprivacy" "$dir/"
  cat > "$dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>io.colyseus.flutter</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platform</string>
	</array>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>MinimumOSVersion</key>
	<string>$MIN_IOS</string>
</dict>
</plist>
EOF
}

framework iphoneos iPhoneOS "" arm64:device-arm64
framework iphonesimulator iPhoneSimulator -simulator arm64:simulator-arm64 x86_64:simulator-x64

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
  -framework "$WORK/iphoneos/$NAME.framework" \
  -framework "$WORK/iphonesimulator/$NAME.framework" \
  -output "$OUT" >/dev/null

echo "Built $OUT"
for slice in "$OUT"/*/; do
  printf '  %s: %s\n' "$(basename "$slice")" "$(lipo -archs "$slice/$NAME.framework/$NAME")"
done
