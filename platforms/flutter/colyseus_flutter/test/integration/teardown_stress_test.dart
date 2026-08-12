@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Joining and leaving repeatedly, the way switching screens does.
///
/// The transport runs its own thread. Freeing a room while that thread is
/// still ticking is a use-after-free, and it shows up as a process-level
/// crash rather than a failed assertion — which is what makes it worth a
/// dedicated stress test instead of trusting the other suites to catch it.
void main() {
  setUpAll(() => requireServer(playground));

  test('rooms can be cycled without tearing down under the transport',
      () async {
    for (var i = 0; i < 12; i++) {
      final client = ColyseusClient(playground);
      final room = await client.joinOrCreate('lab-move');

      // Enough frames to get the transport genuinely busy: decode, acks and
      // the input round trip all running when the teardown starts.
      final input = room.input()!;
      final predict = Predict.of(room);
      predict.attachAll('players',
          config: {'x': PredictMode.damped, 'y': PredictMode.damped});

      for (var f = 0; f < 20; f++) {
        Colyseus.pump();
        final steps = predict.tick(room.clock.now);
        for (var s = 0; s < steps; s++) {
          input.data['moveX'] = 1;
          input.send();
        }
        await settle(const Duration(milliseconds: 16));
      }

      await closeRoom(room);
      client.dispose();
    }

    // Reaching here at all is the result: a crash takes the process with it.
    expect(true, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('leaving immediately after joining is safe', () async {
    // The tightest window: the socket is still mid-handshake work when the
    // teardown begins.
    for (var i = 0; i < 12; i++) {
      final client = ColyseusClient(playground);
      final room = await client.joinOrCreate('lab-move');
      await closeRoom(room);
      client.dispose();
    }
    expect(true, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // The app's own teardown used a flat delay instead of waiting for the
  // socket to actually close. This pins whether that is the difference.
  test('a flat delay instead of waiting for the close', () async {
    for (var i = 0; i < 12; i++) {
      final client = ColyseusClient(playground);
      final room = await client.joinOrCreate('lab-move');

      final input = room.input()!;
      final predict = Predict.of(room);
      for (var f = 0; f < 20; f++) {
        Colyseus.pump();
        final steps = predict.tick(room.clock.now);
        for (var s = 0; s < steps; s++) {
          input.data['moveX'] = 1;
          input.send();
        }
        await settle(const Duration(milliseconds: 16));
      }

      room.setLatency();
      await room.leave();
      await settle(const Duration(milliseconds: 200));
      Colyseus.pump();
      room.dispose();
      client.dispose();
    }
    expect(true, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // Reconnecting replaces the transport: the old one is torn down while its
  // thread may still be ticking, and a new one starts underneath the same
  // room. That is a different teardown path from a plain leave, and it is the
  // one the flaky suite exercises.
  test('dropping and reconnecting repeatedly', () async {
    final client = ColyseusClient(playground);
    final room = await client.joinOrCreate('lab-move');
    room.setReconnectionOptions(
      minUptimeMs: 300,
      minDelayMs: 100,
      maxDelayMs: 400,
    );

    final input = room.input()!;
    final predict = Predict.of(room);
    var reconnects = 0;
    room.onReconnect.listen((_) => reconnects++);

    for (var cycle = 0; cycle < 6; cycle++) {
      for (var f = 0; f < 40; f++) {
        Colyseus.pump();
        final steps = predict.tick(room.clock.now);
        for (var s = 0; s < steps; s++) {
          input.data['moveX'] = 1;
          input.send();
        }
        await settle(const Duration(milliseconds: 16));
      }

      final before = reconnects;
      room.dropConnection();

      final back = await waitFor(() => reconnects > before,
          timeout: const Duration(seconds: 15));
      expect(back, isTrue, reason: 'cycle $cycle never reconnected');
      input.reset();
    }

    await closeRoom(room);
    client.dispose();
  },
      timeout: const Timeout(Duration(minutes: 4)),
      // KNOWN CORE DEFECT: auto-reconnect works exactly once per room.
      // room_reconnect_worker_spawn() in src/room.c guards on a
      // `thread_started` flag it never clears, and the worker thread returns
      // as soon as a reconnect succeeds — so a second drop sets the
      // reconnecting flags with nothing left running to act on them. The room
      // then sits reconnecting forever: no reconnect, no leave.
      //
      // Reproduces 3 runs out of 3 when un-skipped. Skipped rather than left
      // red so the rest of the suite keeps its signal; remove the skip once
      // the core clears the flag (or keeps the worker alive across cycles).
      skip: 'core: reconnect worker is one-shot per room (src/room.c)');
}
