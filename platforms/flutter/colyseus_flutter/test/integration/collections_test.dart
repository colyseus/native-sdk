@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpAll(() => requireServer(exampleServer));

  group('SchemaMap', () {
    test('exposes length, keys, values and entries', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        await waitForOwnEntry(room);

        final players = room.state!.getMap('players')!;
        expect(players.length, greaterThan(0));
        expect(players.isNotEmpty, isTrue);
        expect(players.keys, contains(room.sessionId));
        expect(players.values.whereType<SchemaInstance>(), isNotEmpty);

        final entries = players.entries;
        expect(entries.length, players.length);
        expect(entries.map((e) => e.key), contains(room.sessionId));
        expect(entries.every((e) => e.value is SchemaInstance), isTrue);
      });
    });

    test('operator[] and containsKey agree with keys', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        await waitForOwnEntry(room);
        final players = room.state!.getMap('players')!;

        expect(players[room.sessionId], isA<SchemaInstance>());
        expect(players.containsKey(room.sessionId), isTrue);
        expect(players['no-such-session'], isNull);
        expect(players.containsKey('no-such-session'), isFalse);
      });
    });

    test('forEach visits every entry once', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        await waitForOwnEntry(room);
        final players = room.state!.getMap('players')!;

        final seen = <String>[];
        players.forEach((key, value) => seen.add(key));

        expect(seen.length, players.length);
        expect(seen.toSet().length, seen.length, reason: 'duplicate keys');
        expect(seen, contains(room.sessionId));
      });
    });

    test('tracks additions made by the server', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        await waitForOwnEntry(room);
        final before = room.state!.getMap('players')!.length;

        room.send('add_bot');

        final grew = await waitFor(
          () => (room.state?.getMap('players')?.length ?? 0) > before,
        );
        expect(grew, isTrue, reason: 'bot never appeared in the map');

        room.send('remove_bot', {'name': 'any'});
      });
    });
  });

  group('SchemaArray', () {
    test('indexes and iterates schema children in index order', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        await waitForOwnEntry(room);

        // reset_items splices the array empty and pushes two known items in
        // one tick — a deterministic fixture that also lands adds at indices
        // the splice just freed.
        room.send('reset_items');

        final filled = await waitFor(() {
          final me = room.state?.getMap('players')?[room.sessionId];
          if (me is! SchemaInstance) return false;
          final items = me.getArray('items');
          return items != null &&
              items.length == 2 &&
              (items[0] as SchemaInstance?)?['name'] == 'reset_a';
        });
        expect(filled, isTrue, reason: 'items never decoded');

        final me =
            room.state!.getMap('players')![room.sessionId] as SchemaInstance;
        final items = me.getArray('items')!;

        expect(items.length, 2);
        expect(items.isNotEmpty, isTrue);
        expect(items[0], isA<SchemaInstance>());
        expect((items[0] as SchemaInstance)['name'], 'reset_a');
        expect((items[0] as SchemaInstance)['value'], 100);
        expect((items[1] as SchemaInstance)['name'], 'reset_b');
        expect(items[999], isNull);

        // Native storage prepends, so this pins the index-order contract.
        final names = <String>[];
        items.forEach((index, value) {
          names.add((value as SchemaInstance)['name'] as String);
        });
        expect(names, ['reset_a', 'reset_b']);

        final valueNames = items.values
            .map((v) => (v as SchemaInstance)['name'] as String)
            .toList();
        expect(valueNames, ['reset_a', 'reset_b']);
      });
    });

    test('add_item appends after the existing tail', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        await waitForOwnEntry(room);

        room.send('reset_items');
        await waitFor(() {
          final me = room.state?.getMap('players')?[room.sessionId];
          return me is SchemaInstance &&
              (me.getArray('items')?.length ?? 0) == 2;
        });

        room.send('add_item', {'name': 'sword'});

        final appended = await waitFor(() {
          final me = room.state?.getMap('players')?[room.sessionId];
          return me is SchemaInstance &&
              (me.getArray('items')?.length ?? 0) == 3;
        });
        expect(appended, isTrue);

        final me =
            room.state!.getMap('players')![room.sessionId] as SchemaInstance;
        final names = me
            .getArray('items')!
            .values
            .map((v) => (v as SchemaInstance)['name'] as String)
            .toList();
        expect(names, ['reset_a', 'reset_b', 'sword']);
      });
    });
  });

  group('SchemaInstance', () {
    test('reads typed scalars and reports field names', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        final me = await waitForOwnEntry(room);

        expect(me!['x'], isA<double>());
        expect(me['y'], isA<double>());
        expect(me.getFieldType('x'), SchemaFieldType.number);
        expect(me.getFieldType('items'), SchemaFieldType.array);
        expect(me.getFieldType('nope'), isNull);
        expect(me.fieldNames, containsAll(['x', 'y', 'items']));
      });
    });

    test('getMap/getArray/getRef return null for mismatched fields', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        final me = await waitForOwnEntry(room);

        expect(me!.getMap('x'), isNull);
        expect(me.getArray('x'), isNull);
        expect(me.getRef('items'), isNull);
        expect(room.state!.getMap('players'), isA<SchemaMap>());
      });
    });
  });
}
