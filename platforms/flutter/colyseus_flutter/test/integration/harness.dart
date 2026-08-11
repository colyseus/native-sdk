import 'dart:io';

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The repo's example-server (`cd example-server && npm start`).
///
/// Carries the room/message/callback surface but declares no `defineInput()`,
/// so `room.input()` is null there — prediction suites need [playground].
const exampleServer = 'ws://127.0.0.1:2567';

/// The prediction playground
/// (`cd demos/prediction-tools && pnpm dev --host 0.0.0.0`).
///
/// The `--host` flag is mandatory: without it Vite binds `::1` only and
/// native clients can't reach it.
const playground = 'ws://127.0.0.1:5173';

/// Whether [endpoint]'s TCP port accepts connections.
Future<bool> serverReachable(String endpoint) async {
  final uri = Uri.parse(endpoint.replaceFirst('ws://', 'http://'));
  try {
    final socket = await Socket.connect(
      uri.host,
      uri.port,
      timeout: const Duration(milliseconds: 500),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

/// Skips the enclosing group when [endpoint] isn't up, with a message naming
/// the command that starts it.
///
/// Integration suites are meant to run locally against live servers; a missing
/// server should read as "not run here", not as a failure.
Future<void> requireServer(String endpoint) async {
  if (await serverReachable(endpoint)) return;

  final how = endpoint == playground
      ? 'cd demos/prediction-tools && pnpm dev --host 0.0.0.0'
      : 'cd example-server && npm start';
  markTestSkipped('$endpoint is not reachable — start it with: $how');
}

/// Runs the event loop for [duration], letting native events reach Dart.
///
/// The SDK's own 16 ms poll timer drives dispatch, so this is just a yield.
Future<void> settle([
  Duration duration = const Duration(milliseconds: 250),
]) async {
  await Future<void>.delayed(duration);
}

/// Waits until [predicate] holds, polling every [interval].
///
/// Returns false on timeout rather than throwing, so callers can assert with
/// their own message.
Future<bool> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(interval);
  }
  return predicate();
}

/// Waits for [compute] to return a non-null value, then yields it.
Future<T?> waitForValue<T>(
  T? Function() compute, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 20),
}) async {
  T? value;
  await waitFor(
    () => (value = compute()) != null,
    timeout: timeout,
    interval: interval,
  );
  return value;
}

/// Waits for this client's own entry in [collection] to decode.
///
/// The join future resolves on the JOIN opcode, which can land a patch or two
/// before the state carrying the player — so every read path has to wait for
/// the entry rather than for the root state.
///
/// Always re-reads from `room.state`: the decoder frees and replaces instances
/// on resync, so a handle captured earlier can dangle.
Future<SchemaInstance?> waitForOwnEntry(
  ColyseusRoom room, {
  String collection = 'players',
  Duration timeout = const Duration(seconds: 5),
}) {
  return waitForValue<SchemaInstance>(
    () {
      final entry = room.state?.getMap(collection)?[room.sessionId];
      return entry is SchemaInstance ? entry : null;
    },
    timeout: timeout,
  );
}

/// Runs [body] against a room of type [roomName], tearing both down after.
///
/// Creates a fresh room per call rather than joining a shared one. Test files
/// run concurrently and a shared room would let them see each other's bots,
/// items and moves — every ordering assertion here would be flaky. Pass
/// [shared] when a test genuinely needs two clients in one room.
Future<void> withRoom(
  String endpoint,
  String roomName,
  Future<void> Function(ColyseusClient client, ColyseusRoom room) body, {
  Map<String, dynamic>? options,
  bool shared = false,
}) async {
  final client = ColyseusClient(endpoint);
  ColyseusRoom? room;
  try {
    room = shared
        ? await client.joinOrCreate(roomName, options)
        : await client.create(roomName, options);
    await body(client, room);
  } finally {
    if (room != null) {
      await closeRoom(room);
    }
    client.dispose();
  }
}

/// Leaves [room], waits for the socket to actually close, then frees it.
///
/// Freeing while the transport thread is still ticking races its teardown and
/// takes the whole process down, so the wait is load-bearing rather than
/// cosmetic. Latency injection is cleared first: it is global, and queued
/// packets would otherwise outlive the room they belong to.
Future<void> closeRoom(ColyseusRoom room) async {
  room.setLatency();
  await waitFor(() => Colyseus.packetsInFlight == 0,
      timeout: const Duration(seconds: 2));

  await room.leave();
  await waitFor(() => !room.isConnected, timeout: const Duration(seconds: 3));
  await settle(const Duration(milliseconds: 250));

  room.dispose();
  await settle(const Duration(milliseconds: 100));
}
