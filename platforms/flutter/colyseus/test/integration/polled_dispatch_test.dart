@Tags(['integration'])
library;

import 'package:colyseus/colyseus.dart';
import 'package:colyseus/src/bindings/native_functions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _n = NativeFunctions.instance;

/// The SDK runs in polled mode: every native callback — the matchmaker's
/// reply, socket open and close, decode, drop, reconnect, leave — fires inside
/// `Colyseus.pump()`, on the Dart thread, and nowhere else.
void main() {
  setUpAll(() => requireServer(exampleServer));
  tearDown(() => Colyseus.autoPoll = true);

  /// Runs the event loop without pumping.
  Future<void> idle() =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  /// Pumps once per frame until [done] holds.
  Future<bool> pumpUntil(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) return false;
      Colyseus.pump();
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return true;
  }

  double? ownX(ColyseusRoom room) =>
      (room.state?.getMap('players')?[room.sessionId] as SchemaInstance?)?['x']
          as double?;

  /// Fails when a native callback ran off the Dart thread since [before].
  void expectOnDartThread(int before, String what) {
    expect(_n.debugDartThreadSwitches(), 0,
        reason: 'the isolate changed OS threads, which voids the check');
    expect(_n.debugForeignCallbacks() - before, 0,
        reason: '$what ran a native callback off the Dart thread');
  }

  Future<ColyseusRoom> privateRoom(ColyseusClient client) =>
      client.create('my_room', options: {'private': true});

  test('with autoPoll off, only a pump delivers join, state, message and leave',
      () async {
    Colyseus.autoPoll = false;
    final foreign = _n.debugForeignCallbacks();
    final client = ColyseusClient(exampleServer);
    ColyseusRoom? room;
    try {
      var joined = false;
      final joining = privateRoom(client);
      joining.then((_) => joined = true, onError: (Object _) => false);

      await idle();
      expect(joined, isFalse, reason: 'the join resolved without a pump');
      expect(_n.pendingEvents(), 0,
          reason: 'a native callback fired between pumps');

      expect(await pumpUntil(() => joined), isTrue,
          reason: 'no pump delivered the join');
      final r = room = await joining;
      expect(await pumpUntil(() => ownX(r) != null), isTrue,
          reason: 'own entry never decoded');

      var states = 0;
      final messages = <String>[];
      final stateSub = r.onStateChange.listen((_) => states++);
      final messageSub = r.onMessageAny.listen((m) => messages.add(m.key));

      r.send('move', {'x': 42.0, 'y': 0.0});
      r.send('echo', {'n': 1});
      await idle();
      expect(ownX(r), isNot(42.0), reason: 'state decoded between pumps');
      expect(states, 0, reason: 'onStateChange fired between pumps');
      expect(messages, isEmpty, reason: 'a message arrived between pumps');
      expect(_n.pendingEvents(), 0,
          reason: 'a native callback fired between pumps');

      expect(
        await pumpUntil(() =>
            ownX(r) == 42.0 && states > 0 && messages.contains('tagged_echo')),
        isTrue,
        reason: 'pumping never delivered the move and the echo',
      );
      await stateSub.cancel();
      await messageSub.cancel();

      int? leaveCode;
      final leaveSub = r.onLeave.listen((code) => leaveCode = code);
      await r.leave();
      await idle();
      expect(leaveCode, isNull, reason: 'onLeave fired between pumps');
      expect(await pumpUntil(() => leaveCode != null), isTrue,
          reason: 'no pump delivered the leave');
      await leaveSub.cancel();

      r.dispose();
      room = null;
      expectOnDartThread(foreign, 'the manual-pump round trip');
    } finally {
      if (room != null) {
        await room.leave();
        Colyseus.pump();
        room.dispose();
      }
      client.dispose();
    }
  });

  group('no native callback runs off the Dart thread', () {
    test('matchmaking: a failed and a successful join', () async {
      final before = _n.debugForeignCallbacks();
      final client = ColyseusClient(exampleServer);
      try {
        await expectLater(client.joinOrCreate('room_that_does_not_exist'),
            throwsA(isA<ColyseusError>()));
        final room = await privateRoom(client);
        await waitForOwnEntry(room);
        await closeRoom(room);
      } finally {
        client.dispose();
      }
      expectOnDartThread(before, 'matchmaking');
    });

    test('decode: state, schema callbacks and messages', () async {
      final before = _n.debugForeignCallbacks();
      final client = ColyseusClient(exampleServer);
      try {
        final room = await privateRoom(client);
        final me = await waitForOwnEntry(room);

        var added = 0, moved = 0, echoed = 0;
        final callbacks = Callbacks.get(room);
        callbacks.onAddByName(room.state!, 'players', (_, __) => added++);
        callbacks.listen(me!, 'x', (dynamic _, dynamic __) => moved++,
            immediate: false);
        final echoSub =
            room.onMessage('tagged_echo').listen((_) => echoed++);

        room.send('add_bot');
        room.send('move', {'x': 9.0, 'y': 0.0});
        room.send('echo', {'n': 1});
        expect(await waitFor(() => added > 1 && moved > 0 && echoed > 0),
            isTrue,
            reason: 'added=$added moved=$moved echoed=$echoed');

        await echoSub.cancel();
        await closeRoom(room);
      } finally {
        client.dispose();
      }
      expectOnDartThread(before, 'decode');
    });

    test('a drop and the automatic reconnect', () async {
      final before = _n.debugForeignCallbacks();
      final client = ColyseusClient(exampleServer);
      try {
        final room = await privateRoom(client);
        await waitForOwnEntry(room);
        room.setReconnectionOptions(
            minUptimeMs: 500, minDelayMs: 100, maxDelayMs: 500);
        await settle(const Duration(milliseconds: 600));

        var dropped = 0, reconnected = 0;
        final dropSub = room.onDrop.listen((_) => dropped++);
        final reconnectSub = room.onReconnect.listen((_) => reconnected++);
        room.dropConnection();
        expect(
            await waitFor(() => reconnected > 0,
                timeout: const Duration(seconds: 15)),
            isTrue,
            reason: 'never reconnected (drops: $dropped)');
        expect(dropped, 1);
        expect(await waitForOwnEntry(room), isNotNull,
            reason: 'state stopped decoding after the reconnect');

        await dropSub.cancel();
        await reconnectSub.cancel();
        await closeRoom(room);
      } finally {
        client.dispose();
      }
      expectOnDartThread(before, 'drop + reconnect');
    });

    test('reconnection giving up', () async {
      final before = _n.debugForeignCallbacks();
      final client = ColyseusClient(exampleServer);
      try {
        final room = await privateRoom(client);
        await waitForOwnEntry(room);
        room.setReconnectionOptions(maxRetries: 0, minUptimeMs: 500);
        await settle(const Duration(milliseconds: 600));

        int? leaveCode;
        final leaveSub = room.onLeave.listen((code) => leaveCode = code);
        room.dropConnection();
        expect(await waitFor(() => leaveCode != null), isTrue,
            reason: 'onLeave never fired after retries ran out');

        await leaveSub.cancel();
        room.dispose();
      } finally {
        client.dispose();
      }
      expectOnDartThread(before, 'reconnect give-up');
    });

    test('leave, and disposing a room that is still open', () async {
      final before = _n.debugForeignCallbacks();
      final client = ColyseusClient(exampleServer);
      try {
        final leaving = await privateRoom(client);
        var left = false;
        final leaveSub = leaving.onLeave.listen((_) => left = true);
        await leaving.leave();
        expect(await waitFor(() => left), isTrue);
        await leaveSub.cancel();
        leaving.dispose();

        // Its close is reported inside dispose, on the caller's thread.
        final open = await privateRoom(client);
        await waitForOwnEntry(open);
        open.dispose();
        await settle();
      } finally {
        client.dispose();
      }
      expectOnDartThread(before, 'leave + dispose');
    });
  });
}
