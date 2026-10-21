import 'dart:ffi';
import 'dart:io';

/// Environment variable pointing at an explicit library path.
///
/// Set this to run against a `zig build` output without the plugin packaging
/// step — the integration test suites rely on it:
///
/// ```sh
/// COLYSEUS_LIBRARY_PATH=../zig-out/lib/macos/arm64/libcolyseus_flutter.dylib \
///   flutter test --tags integration
/// ```
const kLibraryPathEnv = 'COLYSEUS_LIBRARY_PATH';

DynamicLibrary? _cached;

/// Loads the native colyseus_flutter library for the current platform.
///
/// The result is cached: repeated calls return the same handle, so every
/// binding class shares one library instance.
DynamicLibrary loadColyseusLibrary() => _cached ??= _open();

DynamicLibrary _open() {
  final override = Platform.environment[kLibraryPathEnv];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }

  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libcolyseus_flutter.so');
  } else if (Platform.isIOS) {
    // Embedded in the app's Frameworks/, which dyld searches via @rpath.
    return DynamicLibrary.open('colyseus_flutter.framework/colyseus_flutter');
  } else if (Platform.isMacOS) {
    return DynamicLibrary.open('libcolyseus_flutter.dylib');
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('colyseus_flutter.dll');
  }

  throw UnsupportedError(
    'Colyseus Flutter is not supported on ${Platform.operatingSystem}',
  );
}
