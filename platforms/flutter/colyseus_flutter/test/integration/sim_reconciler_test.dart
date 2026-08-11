@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'predict_test.dart' show driveFrames, stepEntity;

void main() {
  setUpAll(() => requireServer(playground));

  tearDown(() => Colyseus.autoPoll = true);

  /// lab-hockey: a paddle the client controls and a puck it collides with.
  ///
  /// The puck is what makes this composite — rolling the paddle back has to
  /// roll back what it hit, which two independent reconcilers could not do.
  test('a composite sim steps every bound part', () async {
    await withRoom(playground, 'lab-hockey', (client, room) async {
      final me = await waitForOwnEntry(room);
      final puck = await waitForValue(() => room.state?.getRef('puck'));
      expect(puck, isNotNull, reason: 'lab-hockey never sent a puck');

      final predict = Predict.of(room);
      final input = room.input()!;

      var steps = 0;
      var sawPaddle = false;
      var sawPuck = false;
      var puckWritable = false;

      final sim = predict.sim(
        input: input,
        options: SimOptions(parts: [
          SimPart('paddle', me),
          SimPart('puck', puck),
        ]),
        step: (ctx, world, cmd) {
          steps++;
          final paddle = world.part('paddle');
          final puckPart = world.part('puck');
          if (paddle != null) sawPaddle = true;
          if (puckPart != null) sawPuck = true;
          if (paddle == null || puckPart == null) return;

          stepEntity(paddle, cmd, ctx.dt);

          // The puck starts at rest, so integrating it proves nothing on its
          // own — write a sentinel and read it back to check the mirror is
          // really writable, then restore and integrate for real.
          final before = puckPart['x'];
          puckPart['x'] = before + 1;
          if (puckPart['x'] == before + 1) puckWritable = true;
          puckPart['x'] = before;

          puckPart['x'] = puckPart['x'] + puckPart['vx'] * ctx.dt;
          puckPart['y'] = puckPart['y'] + puckPart['vy'] * ctx.dt;
        },
      );

      await driveFrames(room, predict, input, 90, moveX: 1);

      expect(steps, greaterThan(0), reason: 'the composite step never ran');
      expect(sawPaddle, isTrue, reason: 'the paddle part did not resolve');
      expect(sawPuck, isTrue, reason: 'the puck part did not resolve');
      expect(puckWritable, isTrue, reason: 'writes to the puck part were lost');

      expect(sim.reconcileSeq, greaterThan(0),
          reason: 'server acks never drove a reconcile');
      expect(sim.stepMs, closeTo(50, 1));

      // Bound parts route through predict.value, so drawing code is unchanged.
      expect(predict.value(puck!, 'x').isNaN, isFalse);
      expect(predict.value(me!, 'x').isNaN, isFalse);

      // The low-level pose key remains available for opaque parts.
      expect(sim.value('paddle.x').isNaN, isFalse);
      expect(sim.value('puck.x').isNaN, isFalse);
    });
  });

  test('reset re-seeds a composite world', () async {
    await withRoom(playground, 'lab-hockey', (client, room) async {
      final me = await waitForOwnEntry(room);
      final puck = await waitForValue(() => room.state?.getRef('puck'));

      final predict = Predict.of(room);
      final input = room.input()!;

      final sim = predict.sim(
        input: input,
        options: SimOptions(parts: [
          SimPart('paddle', me),
          SimPart('puck', puck),
        ]),
        step: (ctx, world, cmd) {
          final paddle = world.part('paddle');
          if (paddle != null) stepEntity(paddle, cmd, ctx.dt);
        },
      );

      await driveFrames(room, predict, input, 60, moveX: 1);
      sim.reset();

      // Composite worlds always adopt (no wire-precision short-circuit), so
      // what survives a reset is float noise, not a real offset.
      expect(sim.lastCorrectionMag, lessThan(1e-3),
          reason: 'reset should drop the correction offset');

      final fresh =
          room.state!.getMap('players')![room.sessionId] as SchemaInstance;
      expect(sim.value('paddle.x'), closeTo(fresh['x'] as double, 0.5),
          reason: 'reset did not adopt the authoritative paddle position');
    });
  });

  test('a world with no bound parts requires an adopt callback', () async {
    await withRoom(playground, 'lab-hockey', (client, room) async {
      await waitForOwnEntry(room);
      final predict = Predict.of(room);
      final input = room.input()!;

      expect(
        () => predict.sim(
          input: input,
          options: const SimOptions(parts: [SimPart.opaque('ghost')]),
          step: (ctx, world, cmd) {},
        ),
        throwsA(isA<StateError>()),
        reason: 'without a restore point a rollback could not replay',
      );
    });
  });
}
