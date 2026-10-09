@Tags(['integration'])
library;

import 'package:colyseus/colyseus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// `consumeSeatReservation` against example-server, whose
/// `POST /reserve_seat` returns what `matchMaker.joinOrCreate()` reserved.
void main() {
  setUpAll(() => requireServer(exampleServer));

  test('joins the seat a server route reserved', () async {
    final client = ColyseusClient(exampleServer);
    try {
      final response = await client.http.post('/reserve_seat', body: {
        'roomName': 'my_room',
        'options': {'private': true},
      });
      final seat = SeatReservation.fromJson(response.json);

      final room = await client.consumeSeatReservation(seat);
      expect(room.sessionId, seat.sessionId);
      expect(room.id, seat.roomId);
      expect(room.name, 'my_room');
      expect(room.isConnected, isTrue);
      expect(await waitForOwnEntry(room), isNotNull);
      await closeRoom(room);
    } finally {
      client.dispose();
    }
  });

  test('connects to the reservation\'s publicAddress', () async {
    final client = ColyseusClient(exampleServer);
    // nothing listens on this client's own endpoint
    final deadClient = ColyseusClient('ws://127.0.0.1:1');
    try {
      final response = await client.http.post('/reserve_seat', body: {
        'roomName': 'my_room',
        'options': {'private': true},
      });
      final seat = SeatReservation.fromJson({
        ...response.json as Map,
        'publicAddress': '127.0.0.1:2567',
      });

      final room = await deadClient.consumeSeatReservation(seat);
      expect(room.sessionId, seat.sessionId);
      expect(room.isConnected, isTrue);
      await closeRoom(room);
    } finally {
      deadClient.dispose();
      client.dispose();
    }
  });
}
