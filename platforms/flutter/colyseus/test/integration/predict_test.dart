@Tags(['integration'])
library;

import 'dart:math';

import 'package:colyseus/colyseus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Drives [frames] frames of the standard loop against a live room.
///
/// Mirrors what an app does: pump, tick, send one input per due step, then
/// read. Returns the number of inputs sent.
///
/// [paceMs] falls back to a fixed-interval pacer. `tick()` only reports due
/// steps once a reconciler has advertised the fixed step, so a room with only
/// passive smoothing would otherwise never send an input — and without inputs
/// there are no acks, no clock samples, and nothing for reckoning to work from.
Future<int> driveFrames(
  ColyseusRoom room,
  Predict predict,
  InputHandle input,
  int frames, {
  double moveX = 0,
  double moveY = 0,
  double paceMs = 0,
  void Function(int frame)? onFrame,
}) async {
  var sent = 0;
  var nextSend = 0.0;

  for (var i = 0; i < frames; i++) {
    Colyseus.pump();

    final now = room.clock.now;
    var steps = predict.tick(now);
    if (steps == 0 && paceMs > 0) {
      if (nextSend == 0) nextSend = now;
      if (now >= nextSend) {
        steps = 1;
        nextSend = now + paceMs;
      }
    }

    for (var s = 0; s < steps; s++) {
      input.data['moveX'] = moveX;
      input.data['moveY'] = moveY;
      input.send();
      sent++;
    }

    onFrame?.call(i);
    await settle(const Duration(milliseconds: 16));
  }
  return sent;
}

void main() {
  setUpAll(() => requireServer(playground));

  tearDown(() => Colyseus.autoPoll = true);

  group('passive smoothing', () {
    test('value falls back to the raw field when untracked', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        expect(predict.value(me!, 'x'), me['x']);
        expect(predict.value(me, 'y'), me['y']);
      });
    });

    test('attachAll tracks entries and smooths them', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        predict.attachAll('players', config: {
          'x': PredictMode.damped,
          'y': PredictMode.damped,
        });

        final input = room.input()!;
        await driveFrames(room, predict, input, 60, moveX: 1, paceMs: 50);

        final me = room.state!.getMap('players')![room.sessionId]
            as SchemaInstance;
        final smoothed = predict.value(me, 'x');

        expect(smoothed, isNot(0));
        // Damped trails the truth but must stay in its neighbourhood.
        expect((smoothed - (me['x'] as double)).abs(), lessThan(20),
            reason: 'smoothed $smoothed vs raw ${me['x']}');
      });
    });

    test('lerp with an explicit delay stays behind the raw value', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        predict.attachAll('players', config: {
          'x': const FieldOptions(mode: PredictMode.lerp, delay: 100),
        });

        final input = room.input()!;
        await driveFrames(room, predict, input, 60, moveX: 1, paceMs: 50);

        final me = room.state!.getMap('players')![room.sessionId]
            as SchemaInstance;
        expect(predict.value(me, 'x'), isNot(0));
      });
    });

    test('exceptKey leaves one entry untracked', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        predict.attachAll(
          'players',
          config: {'x': PredictMode.damped},
          exceptKey: room.sessionId,
        );

        final input = room.input()!;
        await driveFrames(room, predict, input, 30, moveX: 1, paceMs: 50);

        final fresh = room.state!.getMap('players')![room.sessionId]
            as SchemaInstance;
        // Untracked, so the read is the raw decoded field.
        expect(predict.value(fresh, 'x'), fresh['x']);
        expect(me, isNotNull);
      });
    });
  });

  group('dead reckoning', () {
    test('attachAllReckon runs the Dart step and advances entities', () async {
      await withRoom(playground, 'lab-bots', (client, room) async {
        await waitForOwnEntry(room);

        final bots = await waitForValue(() {
          final map = room.state?.getMap('bots');
          return (map != null && map.isNotEmpty) ? map : null;
        });
        expect(bots, isNotNull, reason: 'lab-bots never sent bots');

        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        var stepCalls = 0;
        predict.attachAllReckon('bots', ['x', 'y'], (state, dt, elapsedMs) {
          stepCalls++;
          // Constant-velocity projection: enough to prove the step runs and
          // can both read and write the scratch.
          state['x'] = state['x'] + state['vx'] * dt;
          state['y'] = state['y'] + state['vy'] * dt;
        });

        final input = room.input()!;
        var lastReckoned = 0.0;

        // Reckoning is driven by reads, the way rendering drives it.
        await driveFrames(room, predict, input, 60, paceMs: 50, onFrame: (_) {
          final map = room.state?.getMap('bots');
          if (map == null || map.isEmpty) return;
          final bot = map.values.first;
          if (bot is SchemaInstance) lastReckoned = predict.value(bot, 'x');
        });

        expect(stepCalls, greaterThan(0),
            reason: 'the Dart reckon step never ran');
        expect(lastReckoned, isNot(0),
            reason: 'reckoned position never resolved');
      });
    });
  });

  group('reconciler', () {
    test('predicts locally and stays matched with the server', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        // The playground's shared movement rules, ported to Dart.
        final recon = predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) => stepEntity(state, cmd, ctx.dt),
        );

        final startX = recon.value('x');
        await driveFrames(room, predict, input, 90, moveX: 1);

        expect(recon.value('x'), greaterThan(startX + 5),
            reason: 'prediction never moved');
        expect(recon.reconcileSeq, greaterThan(5),
            reason: 'server acks never drove a reconcile');
        expect(recon.stepMs, closeTo(50, 1),
            reason: 'lab-move runs at 20 Hz');

        // Deterministic step + no injected latency: the two simulations should
        // agree to float noise.
        expect(recon.drift.ema, lessThan(0.01),
            reason: 'drift ${recon.drift} — the Dart step has diverged');
        expect(classifyDrift(recon.drift), DriftStatus.matched);
      });
    });

    test('tick() without a timestamp drives from the room clock', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        final recon = predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) => stepEntity(state, cmd, ctx.dt),
        );

        final startX = recon.value('x');
        // driveFrames' loop, minus the timestamp. An omitted `now` has to come
        // back on the room clock's axis, or the step budget never lines up with
        // the server's cadence and the prediction drifts off it.
        for (var i = 0; i < 90; i++) {
          Colyseus.pump();
          final steps = predict.tick();
          for (var s = 0; s < steps; s++) {
            input.data['moveX'] = 1;
            input.send();
          }
          await settle(const Duration(milliseconds: 16));
        }

        expect(recon.value('x'), greaterThan(startX + 5),
            reason: 'prediction never moved');
        expect(recon.reconcileSeq, greaterThan(5),
            reason: 'server acks never drove a reconcile');
        expect(recon.drift.ema, lessThan(0.01),
            reason: 'drift ${recon.drift} — the defaulted tick is off-axis');
      });
    });

    test('state and value agree while settled', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        final recon = predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) => stepEntity(state, cmd, ctx.dt),
        );

        await driveFrames(room, predict, input, 60, moveX: 1);
        await driveFrames(room, predict, input, 30);

        expect(recon.value('x'), closeTo(recon.state['x'], 1.0),
            reason: 'the correction offset never decayed');
      });
    });

    test('pendingCount grows with injected latency', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        final recon = predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) => stepEntity(state, cmd, ctx.dt),
        );

        await driveFrames(room, predict, input, 40, moveX: 1);
        final settled = recon.pendingCount;

        room.setLatency(delayMs: 400);
        try {
          await driveFrames(room, predict, input, 60, moveX: 1);
          expect(recon.pendingCount, greaterThan(settled),
              reason: 'latency did not deepen the in-flight window');
        } finally {
          room.setLatency();
        }

        await driveFrames(room, predict, input, 60, moveX: 1);
        expect(recon.drift.ema, lessThan(0.5),
            reason: 'drift ${recon.drift} after the latency spike');
      });
    });

    // Latency alone does not cause replay: when the prediction matched the
    // server the core short-circuits the whole reconcile. Replay is what
    // happens on a MISPREDICTION, so the test has to cause one — `impulse`
    // applies a server-side velocity kick the client never predicted.
    test('a misprediction triggers rollback replay', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        var liveSteps = 0;
        var replaySteps = 0;
        var sawFixedDt = true;
        var peakCorrection = 0.0;
        final replayedTicks = <int>{};

        late final Reconciler recon;
        recon = predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          // Sampled per reconcile: by the end of the run the prediction has
          // re-converged, so the LAST correction is legitimately zero.
          onReconcile: (_) {
            final mag = recon.lastCorrectionMag;
            if (mag > peakCorrection) peakCorrection = mag;
          },
          step: (ctx, state, cmd) {
            if (ctx.isReplay) {
              replaySteps++;
              replayedTicks.add(ctx.tick);
              // Only inputs that already ran live are ever replayed.
              expect(ctx.tick, lessThanOrEqualTo(input.sentCount));
            } else {
              liveSteps++;
            }
            if ((ctx.dt - 0.05).abs() > 1e-9) sawFixedDt = false;
            stepEntity(state, cmd, ctx.dt);
          },
        );

        room.setLatency(delayMs: 300);
        try {
          await driveFrames(room, predict, input, 30, moveX: 1);
          // Several kicks: each one is a divergence the client must absorb.
          for (var i = 0; i < 5; i++) {
            room.send('impulse');
            await driveFrames(room, predict, input, 15, moveX: 1);
          }
        } finally {
          room.setLatency();
        }

        expect(liveSteps, greaterThan(0));
        expect(replaySteps, greaterThan(0),
            reason: 'server impulses never produced a rollback replay');
        expect(replayedTicks, isNotEmpty);
        expect(sawFixedDt, isTrue, reason: 'dt was not the fixed 50 ms step');
        expect(recon.reconcileSeq, greaterThan(0));
        expect(peakCorrection, greaterThan(0),
            reason: 'an impulse should register as a correction at some point');
      });
    });

    test('a matched prediction short-circuits without replaying', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        var replaySteps = 0;

        final recon = predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) {
            if (ctx.isReplay) replaySteps++;
            stepEntity(state, cmd, ctx.dt);
          },
        );

        room.setLatency(delayMs: 300);
        try {
          await driveFrames(room, predict, input, 90, moveX: 1);
        } finally {
          room.setLatency();
        }

        // Reconciles happened; none of them needed to rewind, because a
        // faithful step keeps predicting exactly what the server computes.
        expect(recon.reconcileSeq, greaterThan(5));
        expect(replaySteps, 0,
            reason: 'a matched prediction should not replay ($replaySteps did)');
        expect(recon.drift.ema, lessThan(0.01));
      });
    });

    test('onReconcile reports the acked sequence', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        final acked = <int>[];
        predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) => stepEntity(state, cmd, ctx.dt),
          onReconcile: acked.add,
        );

        await driveFrames(room, predict, input, 90, moveX: 1);

        expect(acked, isNotEmpty, reason: 'onReconcile never fired');
        expect(acked, orderedEquals(List.of(acked)..sort()),
            reason: 'acked sequences went backwards');
      });
    });

    test('reset re-seeds from the server', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        final recon = predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) => stepEntity(state, cmd, ctx.dt),
        );

        await driveFrames(room, predict, input, 60, moveX: 1);

        final fresh = room.state!.getMap('players')![room.sessionId]
            as SchemaInstance;
        final authoritativeX = fresh['x'] as double;
        recon.reset();

        // reset() re-seeds from the server. It deliberately does NOT touch the
        // input handle's in-flight window — that is input.reset()'s job.
        expect(recon.state['x'], closeTo(authoritativeX, 0.001),
            reason: 'reset did not adopt the authoritative position');
        expect(recon.lastCorrectionMag, 0,
            reason: 'reset should drop the pending correction offset');
      });
    });

    test('memo freezes a value across replays', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        var computeCalls = 0;
        final perTick = <int, double>{};
        var stableAcrossReplays = true;

        predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) {
            // A value replay could never re-derive: it depends on call order,
            // not on state. If memo works, each tick keeps its first answer.
            final value = ctx.memo('roll', () {
              computeCalls++;
              return computeCalls * 1.0;
            });
            final previous = perTick[ctx.tick];
            if (previous != null && previous != value) {
              stableAcrossReplays = false;
            }
            perTick[ctx.tick] = value;
            stepEntity(state, cmd, ctx.dt);
          },
        );

        room.setLatency(delayMs: 300);
        try {
          await driveFrames(room, predict, input, 90, moveX: 1);
        } finally {
          room.setLatency();
        }

        expect(perTick, isNotEmpty);
        expect(stableAcrossReplays, isTrue,
            reason: 'a memoized value changed when its input was replayed');
        expect(computeCalls, lessThanOrEqualTo(perTick.length),
            reason: 'compute ran more often than there were live steps');
      });
    });

    test('memoVec freezes a tuple under one key', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.get(room);
        addTearDown(predict.dispose);

        final input = room.input()!;
        final perTick = <int, List<double>>{};
        var stable = true;

        predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) {
            final v = ctx.memoVec('hit', () => [1, state['x'], state['y']]);
            final previous = perTick[ctx.tick];
            if (previous != null && !_sameList(previous, v)) stable = false;
            perTick[ctx.tick] = v;
            stepEntity(state, cmd, ctx.dt);
          },
        );

        room.setLatency(delayMs: 300);
        try {
          await driveFrames(room, predict, input, 90, moveX: 1);
        } finally {
          room.setLatency();
        }

        expect(perTick.values.every((v) => v.length == 3), isTrue);
        expect(stable, isTrue, reason: 'a memoized tuple changed on replay');
      });
    });
  });
}

bool _sameList(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// The playground's shared movement rules, transcribed from
// `src/shared/movement.ts`. The drift assertions above are only meaningful
// because this matches the server operation for operation — any divergence
// here shows up as non-zero drift, which is exactly what they check.
const _accel = 220.0; // u/s²
const _maxSpeed = 34.0; // u/s
const _frictionK = 0.72;
const _arenaW = 100.0;
const _arenaH = 60.0;
const _playerHalf = 1.6;

void stepEntity(SchemaView e, SchemaView cmd, double dt) {
  var ax = cmd['moveX'];
  var ay = cmd['moveY'];
  if (ax != 0 && ay != 0) {
    ax *= sqrt1_2;
    ay *= sqrt1_2;
  }

  var vx = e['vx'];
  var vy = e['vy'];

  if (ax != 0 || ay != 0) {
    vx += ax * _accel * dt;
    vy += ay * _accel * dt;
  } else {
    vx *= _frictionK;
    vy *= _frictionK;
    if (vx > -0.05 && vx < 0.05) vx = 0;
    if (vy > -0.05 && vy < 0.05) vy = 0;
  }

  final sq = vx * vx + vy * vy;
  if (sq > _maxSpeed * _maxSpeed) {
    final s = _maxSpeed / sqrt(sq);
    vx *= s;
    vy *= s;
  }

  var x = e['x'] + vx * dt;
  var y = e['y'] + vy * dt;

  // Arena walls: clamp, then kill the outward velocity component only.
  const minX = _playerHalf, maxX = _arenaW - _playerHalf;
  const minY = _playerHalf, maxY = _arenaH - _playerHalf;
  if (x < minX) {
    x = minX;
    if (vx < 0) vx = 0;
  } else if (x > maxX) {
    x = maxX;
    if (vx > 0) vx = 0;
  }
  if (y < minY) {
    y = minY;
    if (vy < 0) vy = 0;
  } else if (y > maxY) {
    y = maxY;
    if (vy > 0) vy = 0;
  }

  e['x'] = x;
  e['y'] = y;
  e['vx'] = vx;
  e['vy'] = vy;
}
