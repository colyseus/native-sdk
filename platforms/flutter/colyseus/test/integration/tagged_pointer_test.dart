@Tags(['integration'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:colyseus/colyseus.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

// Android arm64 hands out heap pointers with a non-zero top byte (0xb4…).
// arm64 macOS/Linux ignore that byte on loads too (TBI), so a tagged pointer
// planted in a field behaves like one Android would have produced.
const _androidTag = 0xb4 << 56;

final _tbi = Abi.current() == Abi.macosArm64 ||
    Abi.current() == Abi.linuxArm64 ||
    Abi.current() == Abi.androidArm64;

typedef _GetByName = Pointer<Uint8> Function(IntPtr, Pointer<Utf8>);
typedef _GetByNameDart = Pointer<Uint8> Function(int, Pointer<Utf8>);

void main() {
  setUpAll(() => requireServer(exampleServer));

  // https://github.com/colyseus/native-sdk/issues/32
  test('collection fields keep tagged heap pointers intact', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final lib = DynamicLibrary.open(
          Platform.environment['COLYSEUS_LIBRARY_PATH'] ??
              'libcolyseus_flutter.dylib');
      final getByName = lib.lookupFunction<_GetByName, _GetByNameDart>(
          'colyseus_dynamic_schema_get_by_name');

      final state = room.state!;
      final name = 'players'.toNativeUtf8();
      final value = getByName(state.handle, name);
      malloc.free(name);
      expect(value, isNot(nullptr));

      // colyseus_dynamic_value_t: { int type; union data; } — data at +8.
      final slot = Pointer<IntPtr>.fromAddress(value.address + 8);
      final original = slot.value;
      final tagged = original | _androidTag;

      slot.value = tagged;
      try {
        final players = state['players'] as SchemaMap;
        expect(players.handle, tagged);
        expect(players.length, greaterThan(0));
        expect(players[room.sessionId], isA<SchemaInstance>());
      } finally {
        slot.value = original; // teardown frees through this slot
      }
    });
  }, skip: _tbi ? false : 'needs arm64 Top Byte Ignore');
}
