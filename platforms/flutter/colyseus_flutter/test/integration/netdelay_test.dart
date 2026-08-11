@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpAll(() => requireServer(exampleServer));

  tearDown(() {
    // Latency is global across rooms; leaving it armed would skew later tests.
    Colyseus.autoPoll = true;
  });

  /// Round-trip time for a `move` to come back in the decoded state.
  Future<int> measureEcho(ColyseusRoom room, double x) async {
    final started = DateTime.now();
    room.send('move', {'x': x, 'y': 0.0});
    final applied = await waitFor(
      () => (room.state?.getMap('players')?[room.sessionId]
              as SchemaInstance?)?['x'] ==
          x,
      timeout: const Duration(seconds: 10),
    );
    expect(applied, isTrue, reason: 'server never echoed x=$x');
    return DateTime.now().difference(started).inMilliseconds;
  }

  test('injected delay shows up in the round trip', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final baseline = await measureEcho(room, 11.0);

      room.setLatency(delayMs: 200);
      try {
        final delayed = await measureEcho(room, 12.0);
        // 200 ms each way; allow generous headroom for patch cadence.
        expect(delayed - baseline, greaterThan(250),
            reason: 'baseline ${baseline}ms vs delayed ${delayed}ms');
      } finally {
        room.setLatency();
      }

      final restored = await measureEcho(room, 13.0);
      expect(restored, lessThan(baseline + 250));
    });
  });

  test('packetsInFlight is non-zero while packets are held', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      room.setLatency(delayMs: 400);
      try {
        room.send('move', {'x': 21.0, 'y': 0.0});
        expect(await waitFor(() => Colyseus.packetsInFlight > 0), isTrue,
            reason: 'injector never held a packet');
        expect(await waitFor(() => Colyseus.packetsInFlight == 0,
            timeout: const Duration(seconds: 5)), isTrue,
            reason: 'queue never drained');
      } finally {
        room.setLatency();
      }
    });
  });

  test('jitter never reorders packets', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      room.setLatency(delayMs: 60, jitterMs: 50);
      try {
        for (var i = 1; i <= 6; i++) {
          room.send('move', {'x': 30.0 + i, 'y': 0.0});
        }
        // Last write wins only if delivery stayed in order.
        final settled = await waitFor(
          () => (room.state?.getMap('players')?[room.sessionId]
                  as SchemaInstance?)?['x'] ==
              36.0,
          timeout: const Duration(seconds: 10),
        );
        expect(settled, isTrue, reason: 'final position was not the last send');
      } finally {
        room.setLatency();
      }
    });
  });

  group('manual pump', () {
    test('joins resolve and events arrive without the poll timer', () async {
      Colyseus.autoPoll = false;

      final client = ColyseusClient(exampleServer);
      ColyseusRoom? room;
      try {
        // Nothing dispatches until something pumps, so drive it while waiting.
        final joining = client.joinOrCreate('my_room');
        final ticker = Stream<void>.periodic(
          const Duration(milliseconds: 16),
        ).listen((_) => Colyseus.pump());

        room = await joining.timeout(const Duration(seconds: 10));
        expect(room.sessionId, isNotEmpty);

        final me = await waitForOwnEntry(room);
        expect(me, isNotNull, reason: 'state never decoded under manual pump');

        await ticker.cancel();
      } finally {
        if (room != null) {
          await room.leave();
          Colyseus.pump();
          room.dispose();
        }
        client.dispose();
      }
    });

    test('nothing is delivered until pump is called', () async {
      await withRoom(exampleServer, 'my_room', (client, room) async {
        await waitForOwnEntry(room);
        Colyseus.autoPoll = false;

        var messages = 0;
        final sub = room.onMessageAny.listen((_) => messages++);
        await settle(const Duration(milliseconds: 100));
        final quiet = messages;

        room.send('move', {'x': 44.0, 'y': 0.0});
        await settle(const Duration(milliseconds: 400));
        expect(messages, quiet, reason: 'events arrived without a pump');

        Colyseus.autoPoll = true;
        await sub.cancel();
      });
    });
  });

  test('dropConnection triggers drop then automatic reconnect', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      // Defaults require 5 s of uptime before retrying, which a test that
      // drops immediately would never clear.
      room.setReconnectionOptions(
        minUptimeMs: 500,
        minDelayMs: 100,
        maxDelayMs: 500,
      );
      await settle(const Duration(milliseconds: 600));

      var dropped = 0;
      var reconnected = 0;
      final dropSub = room.onDrop.listen((_) => dropped++);
      final reconnectSub = room.onReconnect.listen((_) => reconnected++);

      room.dropConnection();

      expect(await waitFor(() => dropped > 0), isTrue,
          reason: 'onDrop never fired');
      expect(
        await waitFor(() => reconnected > 0,
            timeout: const Duration(seconds: 15)),
        isTrue,
        reason: 'onReconnect never fired',
      );
      expect(room.isConnected, isTrue);

      // The wrap is re-armed on the new transport, so state still flows.
      final me = await waitForOwnEntry(room);
      expect(me, isNotNull, reason: 'state stopped decoding after reconnect');

      await dropSub.cancel();
      await reconnectSub.cancel();
    });
  });
}
