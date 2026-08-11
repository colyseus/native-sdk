import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'event_poller.dart';
import 'room.dart';

final _n = NativeFunctions.instance;

/// A Colyseus multiplayer client.
///
/// ```dart
/// final client = ColyseusClient('ws://localhost:2567');
/// final room = await client.joinOrCreate('my_room', {'name': 'Player1'});
///
/// room.onStateChange.listen((_) {
///   print('State changed!');
/// });
///
/// room.send('move', {'x': 10, 'y': 20});
///
/// // When done:
/// await room.leave();
/// room.dispose();
/// client.dispose();
/// ```
class ColyseusClient {
  int _handle;

  /// Create a client connected to the given endpoint.
  /// [endpoint] should include protocol, e.g. "ws://localhost:2567" or "wss://example.com"
  ColyseusClient(String endpoint) : _handle = 0 {
    final endpointPtr = endpoint.toNativeUtf8();
    _handle = _n.clientCreate(endpointPtr);
    malloc.free(endpointPtr);
    if (_handle == 0) {
      throw StateError('Failed to create Colyseus client for "$endpoint"');
    }
  }

  /// Join or create a room.
  /// [options] is an optional map that will be JSON-encoded and sent to the server.
  /// Returns a [Future] that completes when the room is joined.
  Future<ColyseusRoom> joinOrCreate(String roomName,
      [Map<String, dynamic>? options]) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientJoinOrCreate(clientHandle, namePtr, optsPtr),
      roomName,
      options,
    );
  }

  /// Create a new room.
  Future<ColyseusRoom> create(String roomName,
      [Map<String, dynamic>? options]) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientCreateRoom(clientHandle, namePtr, optsPtr),
      roomName,
      options,
    );
  }

  /// Join an existing room by name.
  Future<ColyseusRoom> join(String roomName,
      [Map<String, dynamic>? options]) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientJoin(clientHandle, namePtr, optsPtr),
      roomName,
      options,
    );
  }

  /// Join a specific room by ID.
  Future<ColyseusRoom> joinById(String roomId,
      [Map<String, dynamic>? options]) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientJoinById(clientHandle, namePtr, optsPtr),
      roomId,
      options,
    );
  }

  /// Reconnect to a room using a reconnection token.
  Future<ColyseusRoom> reconnect(String reconnectionToken) {
    final tokenPtr = reconnectionToken.toNativeUtf8();
    final roomRef = _n.clientReconnect(_handle, tokenPtr);
    malloc.free(tokenPtr);

    if (roomRef == 0) {
      return Future.error(
          StateError('Failed to start reconnection (no room slot available)'));
    }

    final room = ColyseusRoom.create(roomRef);
    return ColyseusEventPoller.instance.registerPendingJoin(roomRef, room);
  }

  Future<ColyseusRoom> _joinRoom(
    int Function(int, Pointer<Utf8>, Pointer<Utf8>) nativeCall,
    String nameOrId,
    Map<String, dynamic>? options,
  ) {
    final namePtr = nameOrId.toNativeUtf8();
    final optsJson = options != null ? jsonEncode(options) : '{}';
    final optsPtr = optsJson.toNativeUtf8();

    final roomRef = nativeCall(_handle, namePtr, optsPtr);
    malloc.free(namePtr);
    malloc.free(optsPtr);

    if (roomRef == 0) {
      return Future.error(
          StateError('Failed to start join (no room slot available)'));
    }

    final room = ColyseusRoom.create(roomRef);
    return ColyseusEventPoller.instance.registerPendingJoin(roomRef, room);
  }

  /// Dispose the client and release native resources.
  void dispose() {
    if (_handle != 0) {
      _n.clientFree(_handle);
      _handle = 0;
    }
  }
}
