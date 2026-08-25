@Tags(['integration'])
library;

import 'package:colyseus/colyseus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

// Hand-written copies of what `schema-codegen --dart` emits for the
// example-server's TestRoom schema. They double as the reference shape for
// the generator's output.

final class Item extends SchemaRef {
  Item(super.handle);
  String get name => view.getString('name') ?? '';
  double get value => view['value'];
}

final class Player extends SchemaRef {
  Player(super.handle);
  double get x => view['x'];
  double get y => view['y'];
  bool get isBot => view.getBool('isBot');
  ArraySchema<Item> get items => arrayOf('items', Item.new);
}

final class TestRoomState extends SchemaRef {
  TestRoomState(super.handle);
  MapSchema<Player> get players => mapOf('players', Player.new);
  Player? get host => refOf('host', Player.new);
  String get currentTurn => view.getString('currentTurn') ?? '';
}

void main() {
  setUpAll(() => requireServer(exampleServer));

  test('onAddByName fires for existing and future collection items', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);
      final callbacks = Callbacks.get(room);

      final added = <String, dynamic>{};
      final sub = callbacks.onAddByName(
          room.state!, 'players', (key, value) => added[key] = value);

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

  test('onRemoveByName fires when the server deletes an entry', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);
      final callbacks = Callbacks.get(room);

      final removed = <String>[];
      final sub = callbacks.onRemoveByName(
          room.state!, 'players', (key, value) => removed.add(key));

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
      final callbacks = Callbacks.get(room);

      final seen = <(dynamic, dynamic)>[];
      final sub = callbacks.listen(
        me!,
        'x',
        (value, previous) => seen.add((value, previous)),
        immediate: false,
      );

      room.send('move', {'x': 42.0, 'y': 0.0});

      expect(await waitFor(() => seen.isNotEmpty), isTrue,
          reason: 'listen never fired');
      expect(seen.last.$1, 42.0);
      expect(seen.last.$1, isA<double>());

      await sub.cancel();
    });
  });

  test('listen replays the current value on registration by default',
      () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      final me = await waitForOwnEntry(room);
      final callbacks = Callbacks.get(room);

      room.send('move', {'x': 7.0, 'y': 0.0});
      expect(
          await waitFor(
              () => (SchemaView(me!.handle)['x'] - 7.0).abs() < 1e-9),
          isTrue);

      final seen = <dynamic>[];
      final sub =
          callbacks.listen(me!, 'x', (value, previous) => seen.add(value));

      expect(await waitFor(() => seen.isNotEmpty), isTrue,
          reason: 'immediate listen never replayed the current value');
      expect(seen.first, 7.0);

      await sub.cancel();
    });
  });

  test('onChange fires after any property change on an instance', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      final me = await waitForOwnEntry(room);
      final callbacks = Callbacks.get(room);

      var changes = 0;
      final sub = callbacks.onChange(me!, () => changes++);

      room.send('move', {'x': 10.0, 'y': 20.0});
      expect(await waitFor(() => changes > 0), isTrue,
          reason: 'onChange never fired');

      await sub.cancel();
      final afterCancel = changes;
      room.send('move', {'x': 30.0, 'y': 40.0});
      await settle(const Duration(milliseconds: 400));
      expect(changes, afterCancel, reason: 'onChange fired after cancel');
    });
  });

  // The leak this fixes: cancelling used to drop the Dart stream while the
  // native callback stayed registered and kept firing.
  test('cancelling a subscription stops native delivery', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);
      final callbacks = Callbacks.get(room);

      var count = 0;
      final sub = callbacks.onAddByName(
          room.state!, 'players', (key, value) => count++);
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
      final callbacks = Callbacks.get(room);

      final hits = List<int>.filled(12, 0);
      final subs = [
        for (var i = 0; i < 12; i++)
          callbacks.onAddByName(
              room.state!, 'players', (key, value) => hits[i]++),
      ];

      expect(await waitFor(() => hits.every((h) => h > 0)), isTrue,
          reason: 'not every subscription received the replay: $hits');

      for (final sub in subs) {
        await sub.cancel();
      }
    });
  });

  test('typed state access reads through generated façades', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final state = room.stateAs(TestRoomState.new)!;
      final me = state.players[room.sessionId];
      expect(me, isNotNull);
      expect(me!.isBot, isFalse);

      // Each join seeds one "sword" item; the array getter is typed.
      expect(await waitFor(() => me.items.isNotEmpty), isTrue);
      expect(me.items[0]!.name, 'sword');

      // First joiner becomes host, a typed ref.
      expect(state.host, isNotNull);
      expect(state.currentTurn, room.sessionId);

      room.send('move', {'x': 5.0, 'y': 6.0});
      expect(await waitFor(() => me.x == 5.0 && me.y == 6.0), isTrue,
          reason: 'typed getters never saw the move');
    });
  });

  test('the schema cache hands back identical wrappers per handle', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final state = room.stateAs(TestRoomState.new)!;
      expect(identical(state, room.stateAs(TestRoomState.new)), isTrue);
      expect(
        identical(state.players[room.sessionId], state.players[room.sessionId]),
        isTrue,
        reason: 'map lookups should reuse the cached wrapper',
      );
    });
  });

  test('typed callbacks take the field to observe, C#-style', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);
      final callbacks = Callbacks.get(room);
      final state = room.stateAs(TestRoomState.new)!;

      // onAdd(state.players, ...) — key and value both statically typed.
      final added = <String, Player>{};
      final addSub =
          callbacks.onAdd(state.players, (key, player) => added[key] = player);
      expect(await waitFor(() => added.containsKey(room.sessionId)), isTrue,
          reason: 'typed onAdd never replayed the existing entry');
      expect(added[room.sessionId], isA<Player>());
      expect(
        identical(added[room.sessionId], state.players[room.sessionId]),
        isTrue,
        reason: 'typed onAdd should deliver the cached wrapper',
      );

      final me = state.players[room.sessionId]!;

      // Typed onAdd on a nested array field, keyed by int index.
      final items = <int, Item>{};
      final itemSub =
          callbacks.onAdd(me.items, (index, item) => items[index] = item);
      expect(await waitFor(() => items.isNotEmpty), isTrue,
          reason: 'typed array onAdd never replayed the seeded item');
      expect(items[0]?.name, 'sword');

      // listen with a typed handler.
      final xs = <double>[];
      final xSub = callbacks.listen(me, 'x',
          (double value, double? previous) => xs.add(value),
          immediate: false);
      room.send('move', {'x': 99.0, 'y': 0.0});
      expect(await waitFor(() => xs.contains(99.0)), isTrue,
          reason: 'typed listen never saw the move');

      // listenRef wraps the child instance in its generated class.
      Player? host;
      final hostSub = callbacks.listenRef(
          state, 'host', Player.new, (value) => host = value);
      expect(await waitFor(() => host != null), isTrue,
          reason: 'listenRef never replayed the host');
      expect(host, isA<Player>());

      await addSub.cancel();
      await itemSub.cancel();
      await xSub.cancel();
      await hostSub.cancel();
    });
  });

  test('typed rooms: stateType joins type state and onStateChange', () async {
    final client = ColyseusClient(exampleServer);
    final room = await client.joinOrCreate('my_room',
        stateType: TestRoomState.new);
    try {
      expect(await waitFor(() => room.state != null), isTrue,
          reason: 'state never decoded');
      final TestRoomState state = room.state!;
      expect(identical(room.state, state), isTrue,
          reason: 'room.state should hand back the same wrapper');

      // The state-change stream carries the typed state.
      final next = room.onStateChange.first;
      room.send('add_bot');
      final TestRoomState changed =
          await next.timeout(const Duration(seconds: 5));
      expect(identical(changed, state), isTrue);
      expect(await waitFor(() => state.players.length > 1), isTrue);

      // Children resolved through the typed root share the room's cache.
      final me = state.players[room.sessionId]!;
      expect(identical(me, room.stateAs(TestRoomState.new)!.players[room.sessionId]),
          isTrue);

      room.send('remove_bot', {'name': 'any'});
    } finally {
      await closeRoom(room);
      client.dispose();
    }
  });

  test('onRemove(state.players, ...) fires typed', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);
      final callbacks = Callbacks.get(room);
      final state = room.stateAs(TestRoomState.new)!;

      final removed = <String>[];
      final sub =
          callbacks.onRemove(state.players, (key, player) => removed.add(key));

      room.send('add_bot');
      expect(await waitFor(() => state.players.length > 1), isTrue);

      room.send('remove_bot', {'name': 'any'});
      expect(await waitFor(() => removed.isNotEmpty), isTrue,
          reason: 'typed onRemove never fired');

      await sub.cancel();
    });
  });
}
