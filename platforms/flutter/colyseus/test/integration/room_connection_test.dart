@Tags(['integration'])
library;

import 'package:colyseus/colyseus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpAll(() => requireServer(exampleServer));

  test('joinOrCreate resolves with room identity', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      expect(room.id, isNotEmpty);
      expect(room.sessionId, isNotEmpty);
      expect(room.name, 'my_room');
      expect(room.isConnected, isTrue);
      expect(room.isReconnecting, isFalse);
      expect(room.reconnectionToken, isNotEmpty);
    });
  });

  test('joining an undefined room reports an error', () async {
    final client = ColyseusClient(exampleServer);
    try {
      await expectLater(
        client.joinOrCreate('room_that_does_not_exist'),
        throwsA(isA<ColyseusError>()),
      );
    } finally {
      client.dispose();
    }
  });

  test('state decodes and onStateChange fires', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      var changes = 0;
      final sub = room.onStateChange.listen((_) => changes++);

      final me = await waitForOwnEntry(room);
      expect(me, isNotNull, reason: 'own player entry never decoded');
      expect(room.state!.getMap('players')!.containsKey(room.sessionId), isTrue);

      await settle();
      expect(changes, greaterThan(0));
      await sub.cancel();
    });
  });

  test('send round-trips through onMessage', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      final me = await waitForOwnEntry(room);
      final startX = me!['x'] as double;

      room.send('move', {'x': 7.0, 'y': 0.0});

      final moved = await waitFor(() {
        final fresh = room.state?.getMap('players')?[room.sessionId];
        return fresh is SchemaInstance && (fresh['x'] as double) != startX;
      });
      expect(moved, isTrue, reason: 'server never applied the move');
    });
  });

  test('reconnect with the room\'s token resumes the session', () async {
    final client = ColyseusClient(exampleServer);
    final room = await client.joinOrCreate('my_room');
    final token = room.reconnectionToken;
    final sessionId = room.sessionId;
    expect(token, contains(':'), reason: 'reconnect() parses roomId:token');
    // The server only holds a seat for a client whose JOIN ack it has seen;
    // a drop before that is "not joined". The first state patch proves it.
    await waitForOwnEntry(room);

    // Take the automatic path out of the picture: the drop ends in onLeave.
    room.setReconnectionOptions(enabled: false);
    var left = false;
    final sub = room.onLeave.listen((_) => left = true);
    room.dropConnection();
    expect(await waitFor(() => left), isTrue, reason: 'onLeave never fired');
    await sub.cancel();
    room.dispose();

    // The server holds the seat for 10 s (allowReconnection).
    final again = await client.reconnect(token);
    expect(again.sessionId, sessionId);
    expect(again.isConnected, isTrue);

    await closeRoom(again);
    client.dispose();
  });

  test('leave closes the connection', () async {
    final client = ColyseusClient(exampleServer);
    final room = await client.joinOrCreate('my_room');
    var leaveCode = -1;
    room.onLeave.listen((code) => leaveCode = code);

    await room.leave();
    expect(await waitFor(() => !room.isConnected), isTrue);
    expect(await waitFor(() => leaveCode >= 0), isTrue);

    room.dispose();
    client.dispose();
  });
}
