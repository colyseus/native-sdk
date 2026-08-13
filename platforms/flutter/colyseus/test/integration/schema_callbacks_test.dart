@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpAll(() => requireServer(exampleServer));

  test('onAdd fires for existing and future collection items', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final added = <String, dynamic>{};
      final sub = room.onAdd('players', (value, key) => added[key] = value);

      // Registration is immediate, so entries decoded before now replay.
      expect(await waitFor(() => added.containsKey(room.sessionId)), isTrue,
          reason: 'existing entry never replayed to onAdd');
      expect(added[room.sessionId], isA<SchemaInstance>());

      final before = added.length;
      room.send('add_bot');
      expect(await waitFor(() => added.length > before), isTrue,
          reason: 'new entry never reached onAdd');

      await sub.cancel();
      room.send('remove_bot', {'name': 'any'});
    });
  });

  test('onRemove fires when the server deletes an entry', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final removed = <String>[];
      final sub = room.onRemove('players', (value, key) => removed.add(key));

      room.send('add_bot');
      expect(
        await waitFor(
          () => (room.state?.getMap('players')?.length ?? 0) > 1,
        ),
        isTrue,
      );

      room.send('remove_bot', {'name': 'any'});
      expect(await waitFor(() => removed.isNotEmpty), isTrue,
          reason: 'onRemove never fired');

      await sub.cancel();
    });
  });

  test('listen reports scalar changes with previous values', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      final me = await waitForOwnEntry(room);

      final seen = <(dynamic, dynamic)>[];
      final sub = room.listen(
        'x',
        (value, previous) => seen.add((value, previous)),
        instanceHandle: me!.handle,
      );

      room.send('move', {'x': 42.0, 'y': 0.0});

      expect(await waitFor(() => seen.isNotEmpty), isTrue,
          reason: 'listen never fired');
      expect(seen.last.$1, 42.0);
      expect(seen.last.$1, isA<double>());

      await sub.cancel();
    });
  });

  // The leak this fixes: cancelling used to drop the Dart stream while the
  // native callback stayed registered and kept firing.
  test('cancelling a subscription stops native delivery', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      var count = 0;
      final sub = room.onAdd('players', (value, key) => count++);
      expect(await waitFor(() => count > 0), isTrue);

      await sub.cancel();
      final afterCancel = count;

      room.send('add_bot');
      await settle(const Duration(milliseconds: 400));
      expect(count, afterCancel, reason: 'callback fired after cancel');

      room.send('remove_bot', {'name': 'any'});
    });
  });

  test('many subscriptions coexist past the old 4-wrapper cap', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final hits = List<int>.filled(12, 0);
      final subs = [
        for (var i = 0; i < 12; i++)
          room.onAdd('players', (value, key) => hits[i]++),
      ];

      expect(await waitFor(() => hits.every((h) => h > 0)), isTrue,
          reason: 'not every subscription received the replay: $hits');

      for (final sub in subs) {
        await sub.cancel();
      }
    });
  });
}
