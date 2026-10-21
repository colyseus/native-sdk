#!/bin/bash
# Build a fresh Flutter iOS app against the package, the way a consumer would,
# and check that every native symbol the Dart bindings look up is there.
#
#   ./check-ios-link.sh <package-dir> [work-dir]
#
# Dart resolves the library by name at runtime, so a missing symbol never fails
# the build; it fails the first connection. Each lane builds once, from an
# empty build folder, as CI, `flutter clean` and every archive do. A build that
# only passes on retry counts as a failure (issue #35).
#
# SIMULATOR=<udid> picks the simulator for the runtime lane; otherwise the
# first available iPhone is used.
set -euo pipefail

PKG="$(cd "${1:?usage: check-ios-link.sh <package-dir> [work-dir]}" && pwd)"
WORK="${2:-$(mktemp -d)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
APP="$WORK/ios_link_check"

# Every name the bindings pass to a lookup.
SYMBOLS="$WORK/symbols.txt"
grep -rhoE "'colyseus_[A-Za-z0-9_]+'" "$PKG/lib" | tr -d "'" | sort -u > "$SYMBOLS"
[ -s "$SYMBOLS" ] || { echo "error: no colyseus_* lookups found under $PKG/lib" >&2; exit 1; }
echo "Expecting $(wc -l < "$SYMBOLS" | tr -d ' ') symbols"

rm -rf "$APP"
flutter create --platforms ios --project-name ios_link_check --org io.colyseus "$APP" >/dev/null
cd "$APP"
flutter pub add "colyseus:{\"path\":\"$PKG\"}" 'dev:integration_test:{"sdk":"flutter"}' >/dev/null

failed=0

# check <label> <app-bundle>: the exports of the image Dart opens, and the
# privacy manifest App Store Connect reads from beside it.
check() {
  local label="$1" fw="$2/Frameworks/colyseus_flutter.framework" missing
  if [ ! -f "$fw/colyseus_flutter" ]; then
    echo "FAIL  $label: colyseus_flutter.framework is not embedded in $2"
    failed=1
    return
  fi
  if [ ! -f "$fw/PrivacyInfo.xcprivacy" ]; then
    echo "FAIL  $label: the embedded framework has no PrivacyInfo.xcprivacy"
    failed=1
    return
  fi
  missing="$(xcrun dyld_info -exports "$fw/colyseus_flutter" | awk '$2 ~ /^_colyseus_/ { print substr($2, 2) }' \
    | sort -u | comm -23 "$SYMBOLS" -)"
  if [ -z "$missing" ]; then
    echo "PASS  $label"
  else
    echo "FAIL  $label: $(echo "$missing" | wc -l | tr -d ' ') symbols not exported, e.g.:"
    echo "$missing" | head -5 | sed 's/^/        /'
    failed=1
  fi
}

# build <label> <flutter build args...>
build() {
  local label="$1"; shift
  flutter clean >/dev/null
  if flutter build "$@" > "$WORK/$label.log" 2>&1; then
    return 0
  fi
  echo "FAIL  $label: first build from a clean folder failed (log: $WORK/$label.log)"
  grep -E '^(Error|error)' "$WORK/$label.log" | head -5 | sed 's/^/        /'
  failed=1
  return 1
}

if build release ios --release --no-codesign; then
  check release build/ios/iphoneos/Runner.app
fi

# Archiving strips the app, which a plain release build does not.
if build archive ipa --no-codesign; then
  check archive build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
fi

# Debug on a simulator is the one lane that runs without a device, so it is
# where the loader itself gets exercised: every lookup, from Dart.
mkdir -p integration_test
{
  echo "import 'package:colyseus/src/native_library.dart';"
  echo "import 'package:flutter_test/flutter_test.dart';"
  echo "import 'package:integration_test/integration_test.dart';"
  echo
  echo "const symbols = <String>["
  sed "s/.*/  '&',/" "$SYMBOLS"
  echo "];"
  echo
  echo "void main() {"
  echo "  IntegrationTestWidgetsFlutterBinding.ensureInitialized();"
  echo "  test('every symbol the bindings look up resolves', () {"
  echo "    final lib = loadColyseusLibrary();"
  echo "    expect(symbols.where((s) => !lib.providesSymbol(s)).toList(), isEmpty);"
  echo "  });"
  echo "}"
} > integration_test/link_test.dart

sim="${SIMULATOR:-$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^(]*\([0-9A-F-]{36}\)' | grep -oE '[0-9A-F-]{36}' || true)}"
if [ -z "$sim" ]; then
  echo "FAIL  runtime: no iPhone simulator available"
  failed=1
else
  xcrun simctl bootstatus "$sim" -b >/dev/null
  flutter clean >/dev/null
  if flutter test integration_test/link_test.dart -d "$sim" > "$WORK/runtime.log" 2>&1; then
    echo "PASS  runtime"
  else
    echo "FAIL  runtime: the simulator build or its lookups failed (log: $WORK/runtime.log)"
    grep -E '^Error|Expected|Actual' "$WORK/runtime.log" | head -5 | sed 's/^/        /'
    failed=1
  fi
fi

exit "$failed"
