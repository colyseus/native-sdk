@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'predict_test.dart' show driveFrames, stepEntity;

void main() {
  setUpAll(() => requireServer(playground));

  tearDown(() => Colyseus.autoPoll = true);

  group('optimistic events', () {
    test('a UI-born prediction confirms', () async {
      await withRoom(playground, 'lab-goal', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.of(room);

        final predicted = <Object?>[];
        final confirmed = <Object?>[];
        final rejected = <Object?>[];

        final goals = predict.defineEvent(
          onPredict: predicted.add,
          onConfirm: confirmed.add,
          onReject: rejected.add,
        );

        expect(goals.predict('goal:1', 'payload-1'), isTrue);
        expect(goals.pendingCount, 1);
        expect(goals.has('goal:1'), isTrue);
        expect(predicted, ['payload-1'],
            reason: 'onPredict should fire immediately');

        expect(goals.confirm('goal:1'), 1);
        expect(confirmed, ['payload-1']);
        expect(goals.pendingCount, 0);
        expect(goals.has('goal:1'), isFalse);
        expect(rejected, isEmpty);
        expect(me, isNotNull);
      });
    });

    test('reject settles the other way', () async {
      await withRoom(playground, 'lab-goal', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.of(room);

        final rejected = <Object?>[];
        final goals = predict.defineEvent(onReject: rejected.add);

        goals.predict('shot:1', 42);
        expect(goals.reject('shot:1'), 1);
        expect(rejected, [42]);
        expect(goals.pendingCount, 0);
      });
    });

    test('a duplicate key is dropped while pending', () async {
      await withRoom(playground, 'lab-goal', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.of(room);
        final goals = predict.defineEvent();

        expect(goals.predict('dup'), isTrue);
        expect(goals.predict('dup'), isFalse,
            reason: 'the same key should not queue twice');
        expect(goals.pendingCount, 1);
      });
    });

    test('confirming nothing reports an unpredicted signal', () async {
      await withRoom(playground, 'lab-goal', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.of(room);

        final unpredicted = <String>[];
        final goals = predict.defineEvent(onUnpredicted: unpredicted.add);

        expect(goals.confirm('never-predicted'), 0);
        expect(unpredicted, ['never-predicted'],
            reason: 'a confirm that settled nothing should report the key');
      });
    });

    test('clear drops pending predictions silently', () async {
      await withRoom(playground, 'lab-goal', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.of(room);

        final settled = <Object?>[];
        final goals = predict.defineEvent(
          onConfirm: settled.add,
          onReject: settled.add,
        );

        goals.predict('a');
        goals.predict('b');
        expect(goals.pendingCount, 2);

        goals.clear();
        expect(goals.pendingCount, 0);
        expect(settled, isEmpty, reason: 'clear should not settle anything');
      });
    });

    test('a sim-born prediction fires once despite replay', () async {
      await withRoom(playground, 'lab-move', (client, room) async {
        final me = await waitForOwnEntry(room);
        final predict = Predict.of(room);
        final input = room.input()!;

        final fired = <Object?>[];
        final channel = predict.defineEvent(
          onPredict: fired.add,
          graceTicks: 1000, // never auto-reject during the test
        );

        var liveSteps = 0;
        var replaySteps = 0;

        predict.reconciler(
          me!,
          input: input,
          fields: const ['x', 'y', 'vx', 'vy'],
          step: (ctx, state, cmd) {
            if (ctx.isReplay) {
              replaySteps++;
            } else {
              liveSteps++;
            }
            // Keyed on the input's own sequence, so a replayed input asks for
            // the very same event.
            ctx.predict(channel, 'tick:${ctx.tick}', ctx.tick);
            stepEntity(state, cmd, ctx.dt);
          },
        );

        room.setLatency(delayMs: 300);
        try {
          await driveFrames(room, predict, input, 30, moveX: 1);
          for (var i = 0; i < 4; i++) {
            room.send('impulse');
            await driveFrames(room, predict, input, 15, moveX: 1);
          }
        } finally {
          room.setLatency();
        }

        expect(replaySteps, greaterThan(0),
            reason: 'no replay happened, so the test proves nothing');
        expect(fired, isNotEmpty);
        expect(fired.length, lessThanOrEqualTo(liveSteps),
            reason: 'a replayed input re-fired its event');
        expect(fired.toSet().length, fired.length,
            reason: 'the same sequence fired more than once: $fired');
      });
    });
  });

  group('predicted spawns', () {
    test('a local spawn is held then correlated with the server entity',
        () async {
      await withRoom(playground, 'lab-projectile', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.of(room);

        final rejects = <int>[];
        final store = predict.spawns(
          'projectiles',
          SpawnsOptions(
            owned: (server) => server['owner'] == room.sessionId,
            spawnTime: (server) => (server['bornMs'] as num).toDouble(),
            step: (local, dt) => (local as _Bullet).advance(dt),
            localRead: (local, field) => (local as _Bullet).read(field),
            onReject: (local, id) => rejects.add(id),
          ),
        );

        final bullet = _Bullet(50, 30, 20, 0);
        final id = store.spawn(bullet);

        expect(id, greaterThan(0));
        expect(store.alive(id), isTrue);
        expect(store.size, greaterThanOrEqualTo(1));

        final pending = store.entries.firstWhere((e) => e.id == id);
        expect(pending.confirmed, isFalse);
        expect(pending.local, same(bullet));
        expect(pending.server, isNull);

        // Reads span the handoff, so a pending entry still renders.
        expect(store.value(pending, 'x'), closeTo(50, 1e-9));

        final input = room.input()!;
        await driveFrames(room, predict, input, 20, paceMs: 50);

        // The turret fires on its own schedule, so a confirmation may or may
        // not arrive inside the window; either way the entry stays readable.
        final entry = store.entries.where((e) => e.id == id).firstOrNull;
        if (entry != null) {
          expect(store.value(entry, 'x').isNaN, isFalse);
        }
        expect(rejects.where((r) => r != id), isEmpty);
      });
    });

    test('cancel drops a pending spawn', () async {
      await withRoom(playground, 'lab-projectile', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.of(room);

        final store = predict.spawns(
          'projectiles',
          SpawnsOptions(
            owned: (server) => server['owner'] == room.sessionId,
            localRead: (local, field) => (local as _Bullet).read(field),
          ),
        );

        final id = store.spawn(_Bullet(10, 10, 0, 0));
        expect(store.alive(id), isTrue);

        store.cancel(id);
        expect(store.alive(id), isFalse);
        expect(store.entries.where((e) => e.id == id), isEmpty);
      });
    });

    test('the local step advances pending spawns', () async {
      await withRoom(playground, 'lab-projectile', (client, room) async {
        await waitForOwnEntry(room);
        final predict = Predict.of(room);

        final store = predict.spawns(
          'projectiles',
          SpawnsOptions(
            owned: (server) => server['owner'] == room.sessionId,
            step: (local, dt) => (local as _Bullet).advance(dt),
            localRead: (local, field) => (local as _Bullet).read(field),
            // Long enough that the test window can't evict it.
            ttlMs: 60000,
          ),
        );

        final bullet = _Bullet(10, 30, 25, 0);
        final id = store.spawn(bullet);

        final input = room.input()!;
        await driveFrames(room, predict, input, 40, paceMs: 50);

        expect(bullet.x, greaterThan(10),
            reason: 'the local step never ran (x still ${bullet.x})');

        final entry = store.entries.where((e) => e.id == id).firstOrNull;
        if (entry != null && !entry.confirmed) {
          expect(store.value(entry, 'x'), closeTo(bullet.x, 1e-9));
        }
      });
    });
  });
}

/// A predicted projectile owned entirely by the app.
///
/// The store treats it as opaque; it only reaches Dart through the callbacks.
class _Bullet {
  double x;
  double y;
  final double vx;
  final double vy;

  _Bullet(this.x, this.y, this.vx, this.vy);

  void advance(double dt) {
    x += vx * dt;
    y += vy * dt;
  }

  double read(String field) => switch (field) {
        'x' => x,
        'y' => y,
        'vx' => vx,
        'vy' => vy,
        _ => double.nan,
      };

  @override
  String toString() => '_Bullet(${x.toStringAsFixed(2)}, '
      '${y.toStringAsFixed(2)})';
}

