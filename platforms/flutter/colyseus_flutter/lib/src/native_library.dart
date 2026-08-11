import 'dart:ffi';
import 'dart:io';

/// Loads the native colyseus_flutter library for the current platform.
DynamicLibrary loadColyseusLibrary() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libcolyseus_flutter.so');
  } else if (Platform.isLinux) {
    return DynamicLibrary.open('libcolyseus_flutter.so');
  } else if (Platform.isIOS) {
    // iOS uses static linking; symbols are in the main executable.
    return DynamicLibrary.process();
  } else if (Platform.isMacOS) {
    return DynamicLibrary.open('libcolyseus_flutter.dylib');
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('colyseus_flutter.dll');
  } else {
    throw UnsupportedError(
      'Colyseus Flutter is not supported on ${Platform.operatingSystem}',
    );
  }
}
