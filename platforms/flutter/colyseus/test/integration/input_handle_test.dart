@Tags(['integration'])
library;

import 'dart:ffi';

import 'package:colyseus/colyseus.dart';
import 'package:colyseus/src/colyseus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpAll(() => requireServer(playground));

  test('no input channel when the room declares none', () async {
    if (!await serverReachable(exampleServer)) {
      markTestSkipped('example-server is not running');
      return;
    }
    await withRoom(exampleServer, 'my_room', (client, room) async {
      await waitForOwnEntry(room);
      expect(room.input(), isNull,
          reason: 'example-server has no defineInput()');
    });
  });

  test('input handle exposes the reflected schema', () async {
    await withRoom(playground, 'lab-move', (client, room) async {
      await waitForOwnEntry(room);

      final input = room.input();
      expect(input, isNotNull, reason: 'lab-move declares MoveInput');
      expect(input!.data.fieldNames, containsAll(['moveX', 'moveY']));
      expect(input.data.typeOf('moveX'), SchemaFieldType.int8);
    });
  });

  test('send returns 1-based sequences and tracks pending', () async {
    await withRoom(playground, 'lab-move', (client, room) async {
      await waitForOwnEntry(room);
      final input = room.input()!;

      expect(input.sentCount, 0);
      expect(input.pendingCount, 0);

      input.data['moveX'] = 1;
      expect(input.send(), 1);
      input.data['moveX'] = -1;
      expect(input.send(), 2);

      expect(input.sentCount, 2);
      expect(input.pendingCount, greaterThan(0));
    });
  });

  test('the server acks inputs and advances lastProcessed', () async {
    await withRoom(playground, 'lab-move', (client, room) async {
      await waitForOwnEntry(room);
      final input = room.input()!;

      for (var i = 0; i < 10; i++) {
        input.data['moveX'] = 1;
        input.send();
        await settle(const Duration(milliseconds: 50));
      }

      expect(await waitFor(() => input.lastProcessed > 0), isTrue,
          reason: 'server never acked an input');
      expect(input.lastProcessed, lessThanOrEqualTo(input.sentCount));
      expect(await waitFor(() => input.pendingCount < input.sentCount), isTrue);
    });
  });

  test('inputs drive the room clock', () async {
    await withRoom(playground, 'lab-move', (client, room) async {
      await waitForOwnEntry(room);
      final input = room.input()!;

      for (var i = 0; i < 15; i++) {
        input.data['moveX'] = 1;
        input.send();
        await settle(const Duration(milliseconds: 50));
      }

      final clock = room.clock;
      expect(await waitFor(() => clock.serverNow > 0), isTrue,
          reason: 'clock never received a TIMED sample');
      expect(clock.rtt, greaterThan(0));
      expect(clock.smoothedRtt, greaterThan(0));
      expect(clock.lastServerTime, greaterThan(0));
      expect(clock.renderNow, greaterThan(0));
      // The render axis trails the estimate; it must not run ahead of it.
      expect(clock.renderNow, lessThanOrEqualTo(clock.serverNow + 500));
    });
  });

  test('reset bumps the epoch', () async {
    await withRoom(playground, 'lab-move', (client, room) async {
      await waitForOwnEntry(room);
      final input = room.input()!;

      input.data['moveX'] = 1;
      input.send();
      final before = input.epoch;

      input.reset();
      expect(input.epoch, greaterThan(before));
      expect(input.pendingCount, 0);
      expect(input.send(), 1, reason: 'sequences restart after a reset');
    });
  });

  test('server rates come through the handshake', () async {
    await withRoom(playground, 'lab-move', (client, room) async {
      await waitForOwnEntry(room);
      final input = room.input()!;

      expect(input.tickRate, 20, reason: 'lab-move runs at TICK_HZ = 20');
      expect(input.subSteps, greaterThanOrEqualTo(1));
    });
  });

  // The load-bearing assumption for the whole predict layer: the core invokes
  // Dart callbacks synchronously from inside calls Dart itself made, so step
  // functions can be plain Dart closures instead of a manual pump loop.
  group('synchronous native callbacks', () {
    test('allowRewind is consulted during send, on the calling thread',
        () async {
      await withRoom(playground, 'lab-range', (client, room) async {
        await waitForOwnEntry(room);

        var calls = 0;
        var sawFire = false;
        var reentrantRead = -1.0;

        final input = room.input(InputOptions(
          allowRewind: (data) {
            calls++;
            final fire = data.getBool('fire');
            if (fire) sawFire = true;
            // Re-enter the FFI from inside the callback: if this is unsafe,
            // it fails loudly here rather than subtly inside a replay.
            reentrantRead = data['aimX'];
            return fire;
          },
        ));
        expect(input, isNotNull);

        final before = calls;
        input!.data['aimX'] = 0.5;
        input.data.setBool('fire', true);
        input.send();

        // Synchronous means the count moved before send() returned — no
        // awaiting, no pumping.
        expect(calls, greaterThan(before),
            reason: 'allowRewind did not run inside send()');
        expect(sawFire, isTrue);
        expect(reentrantRead, closeTo(0.5, 1e-6),
            reason: 'nested FFI read from inside the callback failed');
      });
    });

    test('an input on_send listener fires inside send', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        await waitForOwnEntry(room);
        final input = room.input()!;

        final seen = <int>[];
        final listener =
            NativeCallable<Void Function(Int, Pointer<Void>)>.isolateLocal(
          (int seq, Pointer<Void> _) => seen.add(seq),
        );
        final sub = core.colyseus_input_handle_on_send(
          input.handle,
          listener.nativeFunction,
          nullptr,
        );
        expect(sub, greaterThanOrEqualTo(0));

        input.data['moveX'] = 1;
        final seq = input.send();

        expect(seen, [seq], reason: 'listener did not fire inside send()');

        core.colyseus_input_handle_off_send(input.handle, sub);
        input.data['moveX'] = 0;
        input.send();
        expect(seen, [seq], reason: 'listener fired after unsubscribing');

        listener.close();
      });
    });
  });
}
