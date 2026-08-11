@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpAll(() => requireServer(exampleServer));

  test('ping measures the live round trip', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final rtt = await room.ping().timeout(const Duration(seconds: 5));
      expect(rtt, greaterThanOrEqualTo(0));
      expect(rtt, lessThan(1000), reason: 'localhost should be fast');
    });
  });

  test('ping reflects injected latency', () async {
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);

      final baseline = await room.ping().timeout(const Duration(seconds: 5));

      room.setLatency(delayMs: 150);
      try {
        final delayed = await room.ping().timeout(const Duration(seconds: 10));
        // 150 ms each way.
        expect(delayed, greaterThan(baseline + 200),
            reason: 'baseline ${baseline}ms vs delayed ${delayed}ms');
      } finally {
        room.setLatency();
      }
    });
  });

  group('selectByLatency', () {
    test('picks a reachable endpoint', () async {
      final result = await Colyseus.selectByLatency(
        [exampleServer],
        timeoutMs: 3000,
      ).timeout(const Duration(seconds: 10));

      expect(result, isNotNull, reason: 'the example server is up');
      expect(result!.endpoint, exampleServer);
      expect(result.latencyMs, greaterThanOrEqualTo(0));
    });

    test('prefers the reachable one out of a mixed list', () async {
      final result = await Colyseus.selectByLatency(
        ['ws://127.0.0.1:1', exampleServer],
        timeoutMs: 3000,
      ).timeout(const Duration(seconds: 15));

      expect(result, isNotNull);
      expect(result!.endpoint, exampleServer,
          reason: 'a closed port should never win');
    });

    test('returns null when every endpoint fails', () async {
      final result = await Colyseus.selectByLatency(
        ['ws://127.0.0.1:1', 'ws://127.0.0.1:2'],
        timeoutMs: 1500,
      ).timeout(const Duration(seconds: 15));

      expect(result, isNull);
    });

    test('an empty list resolves to null', () async {
      expect(await Colyseus.selectByLatency([]), isNull);
    });
  });
}
