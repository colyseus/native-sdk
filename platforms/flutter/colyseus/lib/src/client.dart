import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';

import 'auth.dart';
import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'event_poller.dart';
import 'http.dart';
import 'room.dart';
import 'schema.dart';

final _n = NativeFunctions.instance;

/// A Colyseus multiplayer client.
///
/// Passing a generated schema class as `stateType:` types the returned room —
/// the Dart spelling of C#'s `JoinOrCreate<MyRoomState>("my_room")`:
///
/// ```dart
/// final client = ColyseusClient('ws://localhost:2567');
/// final room = await client.joinOrCreate('my_room',
///     options: {'name': 'Player1'}, stateType: MyRoomState.new);
///
/// final state = await room.onStateChange.first;   // MyRoomState
/// print(state.players.length);
///
/// room.send('move', {'x': 10, 'y': 20});
///
/// // When done:
/// await room.leave();
/// room.dispose();
/// client.dispose();
/// ```
///
/// Without `stateType:`, the room's state reads dynamically through
/// [SchemaInstance].
class ColyseusClient {
  int _handle;
  ColyseusHttp? _http;
  ColyseusAuth? _auth;

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
  ///
  /// [options] is JSON-encoded and sent to the server. [stateType] is the
  /// generated class for the room's schema root; it types the room's `state`
  /// and `onStateChange`.
  Future<ColyseusRoom<T>> joinOrCreate<T extends SchemaInstance>(
    String roomName, {
    Map<String, dynamic>? options,
    T Function(int handle)? stateType,
  }) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientJoinOrCreate(clientHandle, namePtr, optsPtr),
      roomName,
      options,
      stateType,
    );
  }

  /// Create a new room.
  Future<ColyseusRoom<T>> create<T extends SchemaInstance>(
    String roomName, {
    Map<String, dynamic>? options,
    T Function(int handle)? stateType,
  }) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientCreateRoom(clientHandle, namePtr, optsPtr),
      roomName,
      options,
      stateType,
    );
  }

  /// Join an existing room by name.
  Future<ColyseusRoom<T>> join<T extends SchemaInstance>(
    String roomName, {
    Map<String, dynamic>? options,
    T Function(int handle)? stateType,
  }) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientJoin(clientHandle, namePtr, optsPtr),
      roomName,
      options,
      stateType,
    );
  }

  /// Join a specific room by ID.
  Future<ColyseusRoom<T>> joinById<T extends SchemaInstance>(
    String roomId, {
    Map<String, dynamic>? options,
    T Function(int handle)? stateType,
  }) {
    return _joinRoom(
      (clientHandle, namePtr, optsPtr) =>
          _n.clientJoinById(clientHandle, namePtr, optsPtr),
      roomId,
      options,
      stateType,
    );
  }

  /// Reconnect to a room using a reconnection token.
  Future<ColyseusRoom<T>> reconnect<T extends SchemaInstance>(
    String reconnectionToken, {
    T Function(int handle)? stateType,
  }) {
    final tokenPtr = reconnectionToken.toNativeUtf8();
    final roomRef = _n.clientReconnect(_handle, tokenPtr);
    malloc.free(tokenPtr);

    if (roomRef == 0) {
      return Future.error(
          StateError('Failed to start reconnection (no room slot available)'));
    }

    final room = ColyseusRoom.create<T>(roomRef, stateType);
    return ColyseusEventPoller.instance.registerPendingJoin(roomRef, room);
  }

  Future<ColyseusRoom<T>> _joinRoom<T extends SchemaInstance>(
    int Function(int, Pointer<Utf8>, Pointer<Utf8>) nativeCall,
    String nameOrId,
    Map<String, dynamic>? options,
    T Function(int handle)? stateType,
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

    final room = ColyseusRoom.create<T>(roomRef, stateType);
    return ColyseusEventPoller.instance.registerPendingJoin(roomRef, room);
  }

  /// The HTTP surface: `client.http.get('/test')`.
  ///
  /// Paths resolve against this client's endpoint. Requests run on a worker
  /// thread, so they never stall the frame loop.
  ColyseusHttp get http => _http ??=
      ColyseusHttp(Pointer<colyseus_client_t>.fromAddress(_handle));

  /// The auth surface: `client.auth.signInAnonymously()`.
  ///
  /// A token obtained here is attached to every later request from this
  /// client, [http] included.
  ColyseusAuth get auth => _auth ??=
      ColyseusAuth(Pointer<colyseus_client_t>.fromAddress(_handle));

  /// Dispose the client and release native resources.
  void dispose() {
    if (_handle != 0) {
      _auth?.dispose();
      _auth = null;
      _http = null;
      _n.clientFree(_handle);
      _handle = 0;
    }
  }
}
