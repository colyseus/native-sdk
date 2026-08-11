import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'event_poller.dart';
import 'message.dart';
import 'schema.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Represents a room connection to a Colyseus server.
///
/// All events are exposed as [Stream]s for idiomatic Dart usage:
/// ```dart
/// room.onStateChange.listen((_) {
///   final state = room.state;
///   print(state['score']);
/// });
///
/// room.onMessage('chat').listen((data) {
///   print(data['text']);
/// });
///
/// room.onError.listen((error) {
///   print('Error: ${error.message}');
/// });
///
/// room.onLeave.listen((code) {
///   print('Left with code: $code');
/// });
/// ```
class ColyseusRoom {
  final int _roomRef;

  final _onJoinController = StreamController<void>.broadcast();
  final _onStateChangeController = StreamController<void>.broadcast();
  final _onErrorController = StreamController<ColyseusError>.broadcast();
  final _onLeaveController = StreamController<int>.broadcast();
  final _onDropController = StreamController<ColyseusError>.broadcast();
  final _onReconnectController = StreamController<void>.broadcast();
  final Map<String, StreamController<dynamic>> _messageControllers = {};
  final _onMessageAnyController =
      StreamController<MapEntry<String, dynamic>>.broadcast();

  // Schema callback streams, keyed by callback handle
  final Map<int, StreamController<dynamic>> _propertyChangeControllers = {};
  final Map<int, StreamController<dynamic>> _itemAddControllers = {};
  final Map<int, StreamController<dynamic>> _itemRemoveControllers = {};

  ColyseusRoom._(this._roomRef);

  /// Create a room instance (called internally by ColyseusClient).
  static ColyseusRoom create(int roomRef) {
    return ColyseusRoom._(roomRef);
  }

  // ===== Properties =====

  /// The room ID assigned by the server.
  String get id => _n.roomGetId(_roomRef).toDartString();

  /// The session ID for this client in this room.
  String get sessionId => _n.roomGetSessionId(_roomRef).toDartString();

  /// The room name/type.
  String get name => _n.roomGetName(_roomRef).toDartString();

  /// Token for reconnecting to this room.
  String get reconnectionToken =>
      _n.roomGetReconnectionToken(_roomRef).toDartString();

  /// Whether the room is currently connected.
  bool get isConnected => _n.roomIsConnected(_roomRef) != 0;

  /// Whether the room is currently inside an automatic reconnection cycle.
  bool get isReconnecting => _n.roomIsReconnecting(_roomRef) != 0;

  /// The room reference handle.
  int get roomRef => _roomRef;

  /// Get the root state as a dynamic schema accessor.
  SchemaInstance? get state {
    final handle = _n.roomGetState(_roomRef);
    return handle != 0 ? SchemaInstance(handle) : null;
  }

  // ===== Event Streams =====

  /// Fires when the client has joined the room.
  Stream<void> get onJoin => _onJoinController.stream;

  /// Fires when the room state has changed.
  Stream<void> get onStateChange => _onStateChangeController.stream;

  /// Fires on room errors.
  Stream<ColyseusError> get onError => _onErrorController.stream;

  /// Fires when the client leaves the room. Value is the close code.
  Stream<int> get onLeave => _onLeaveController.stream;

  /// Fires when the WebSocket drops with a recoverable close code. The room
  /// will automatically attempt to reconnect. Use this stream to drive a
  /// "reconnecting…" UI; on success, [onReconnect] fires. If retries are
  /// exhausted, [onLeave] fires with code 4003 (FAILED_TO_RECONNECT).
  Stream<ColyseusError> get onDrop => _onDropController.stream;

  /// Fires when an automatic reconnection attempt succeeds. Any messages
  /// buffered while disconnected have already been flushed by this point.
  Stream<void> get onReconnect => _onReconnectController.stream;

  /// Update the automatic reconnection options. Any value <= -1 is left
  /// unchanged; pass enabled=0 to disable reconnection entirely.
  void setReconnectionOptions({
    bool? enabled,
    int? maxRetries,
    int? minDelayMs,
    int? maxDelayMs,
    int? minUptimeMs,
    int? delayMs,
    int? maxEnqueuedMessages,
  }) {
    _n.roomSetReconnectionOptions(
      _roomRef,
      enabled == null ? -1 : (enabled ? 1 : 0),
      maxRetries ?? -1,
      minDelayMs ?? -1,
      maxDelayMs ?? -1,
      minUptimeMs ?? -1,
      delayMs ?? -1,
      maxEnqueuedMessages ?? -1,
    );
  }

  /// Listen to messages of a specific type.
  Stream<dynamic> onMessage(String type) {
    return _messageControllers
        .putIfAbsent(type, () => StreamController<dynamic>.broadcast())
        .stream;
  }

  /// Listen to all messages (type, data) pairs.
  Stream<MapEntry<String, dynamic>> get onMessageAny =>
      _onMessageAnyController.stream;

  // ===== Send =====

  /// Send a message with a string type.
  /// [data] can be a Map, List, String, int, double, bool, or null.
  void send(String type, [Object? data]) {
    final msgHandle = buildMessage(data);
    final typePtr = type.toNativeUtf8();
    _n.roomSendMessage(_roomRef, typePtr, msgHandle);
    malloc.free(typePtr);
  }

  /// Send a message with an integer type.
  void sendInt(int type, [Object? data]) {
    final msgHandle = buildMessage(data);
    _n.roomSendMessageInt(_roomRef, type, msgHandle);
  }

  /// Send raw bytes with a string type (ROOM_DATA_BYTES protocol).
  void sendBytes(String type, Uint8List data) {
    final typePtr = type.toNativeUtf8();
    final dataPtr = malloc<Uint8>(data.length);
    dataPtr.asTypedList(data.length).setAll(0, data);
    _n.roomSendBytes(_roomRef, typePtr, dataPtr, data.length);
    malloc.free(typePtr);
    malloc.free(dataPtr);
  }

  // ===== Schema Callbacks =====

  /// Listen to property changes on a schema instance.
  /// Pass [instance] handle or 0/null for root state.
  /// Returns a subscription that can be cancelled.
  StreamSubscription<dynamic> listen(
    String property,
    void Function(dynamic value, dynamic previousValue) callback, {
    int instanceHandle = 0,
  }) {
    final callbacksHandle = _n.callbacksCreate(_roomRef);
    if (callbacksHandle == 0) {
      throw StateError('Failed to create callbacks manager');
    }

    final propPtr = property.toNativeUtf8();
    final handle =
        _n.callbacksListen(callbacksHandle, instanceHandle, propPtr);
    malloc.free(propPtr);

    if (handle < 0) {
      throw StateError('Failed to register listen callback');
    }

    final controller = StreamController<dynamic>.broadcast();
    _propertyChangeControllers[handle] = controller;

    return controller.stream.listen((event) {
      if (event is Map) {
        callback(event['value'], event['previousValue']);
      }
    });
  }

  /// Listen to items added to a collection.
  StreamSubscription<dynamic> onAdd(
    String property,
    void Function(dynamic value, String key) callback, {
    int instanceHandle = 0,
  }) {
    final callbacksHandle = _n.callbacksCreate(_roomRef);
    if (callbacksHandle == 0) {
      throw StateError('Failed to create callbacks manager');
    }

    final propPtr = property.toNativeUtf8();
    final handle =
        _n.callbacksOnAdd(callbacksHandle, instanceHandle, propPtr);
    malloc.free(propPtr);

    if (handle < 0) {
      throw StateError('Failed to register onAdd callback');
    }

    final controller = StreamController<dynamic>.broadcast();
    _itemAddControllers[handle] = controller;

    return controller.stream.listen((event) {
      if (event is Map) {
        callback(event['value'], event['key'] as String);
      }
    });
  }

  /// Listen to items removed from a collection.
  StreamSubscription<dynamic> onRemove(
    String property,
    void Function(dynamic value, String key) callback, {
    int instanceHandle = 0,
  }) {
    final callbacksHandle = _n.callbacksCreate(_roomRef);
    if (callbacksHandle == 0) {
      throw StateError('Failed to create callbacks manager');
    }

    final propPtr = property.toNativeUtf8();
    final handle =
        _n.callbacksOnRemove(callbacksHandle, instanceHandle, propPtr);
    malloc.free(propPtr);

    if (handle < 0) {
      throw StateError('Failed to register onRemove callback');
    }

    final controller = StreamController<dynamic>.broadcast();
    _itemRemoveControllers[handle] = controller;

    return controller.stream.listen((event) {
      if (event is Map) {
        callback(event['value'], event['key'] as String);
      }
    });
  }

  // ===== Lifecycle =====

  /// Leave the room gracefully.
  Future<void> leave() async {
    _n.roomLeave(_roomRef);
  }

  /// Dispose all resources. Call after leaving.
  void dispose() {
    _onJoinController.close();
    _onStateChangeController.close();
    _onErrorController.close();
    _onLeaveController.close();
    _onDropController.close();
    _onReconnectController.close();
    _onMessageAnyController.close();
    for (final c in _messageControllers.values) {
      c.close();
    }
    _messageControllers.clear();
    for (final c in _propertyChangeControllers.values) {
      c.close();
    }
    _propertyChangeControllers.clear();
    for (final c in _itemAddControllers.values) {
      c.close();
    }
    _itemAddControllers.clear();
    for (final c in _itemRemoveControllers.values) {
      c.close();
    }
    _itemRemoveControllers.clear();

    ColyseusEventPoller.instance.unregisterRoom(_roomRef);
    _n.roomFree(_roomRef);
  }

  // ===== Internal event handlers (called by EventPoller) =====

  void handleJoin() {
    _onJoinController.add(null);
  }

  void handleStateChange() {
    _onStateChangeController.add(null);
  }

  void handleMessage(String type, dynamic data) {
    _onMessageAnyController.add(MapEntry(type, data));
    _messageControllers[type]?.add(data);
  }

  void handleError(int code, String message) {
    _onErrorController.add(ColyseusError(code, message));
  }

  void handleLeave(int code) {
    _onLeaveController.add(code);
  }

  void handleDrop(int code, String reason) {
    _onDropController.add(ColyseusError(code, reason));
  }

  void handleReconnect() {
    _onReconnectController.add(null);
  }

  void handlePropertyChange(
    int callbackHandle,
    int valueType,
    double valueNumber,
    String valueString,
    double prevValueNumber,
    String prevValueString,
    int instanceHandle,
  ) {
    final controller = _propertyChangeControllers[callbackHandle];
    if (controller == null) return;

    final type = SchemaFieldType.fromValue(valueType);
    dynamic value;
    dynamic previousValue;

    if (type == SchemaFieldType.string) {
      value = valueString;
      previousValue = prevValueString;
    } else if (type == SchemaFieldType.ref) {
      value = instanceHandle != 0 ? SchemaInstance(instanceHandle) : null;
      previousValue = null;
    } else if (type == SchemaFieldType.boolean) {
      value = valueNumber > 0.5;
      previousValue = prevValueNumber > 0.5;
    } else {
      value = valueNumber;
      previousValue = prevValueNumber;
    }

    controller.add({'value': value, 'previousValue': previousValue});
  }

  void handleItemAdd(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
  ) {
    final controller = _itemAddControllers[callbackHandle];
    if (controller == null) return;

    dynamic value;
    final type = SchemaFieldType.fromValue(valueType);
    if (type == SchemaFieldType.ref ||
        type == SchemaFieldType.array ||
        type == SchemaFieldType.map) {
      value = instanceHandle != 0 ? SchemaInstance(instanceHandle) : null;
    } else {
      value = instanceHandle;
    }

    controller.add({'value': value, 'key': key});
  }

  void handleItemRemove(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
  ) {
    final controller = _itemRemoveControllers[callbackHandle];
    if (controller == null) return;

    dynamic value;
    final type = SchemaFieldType.fromValue(valueType);
    if (type == SchemaFieldType.ref ||
        type == SchemaFieldType.array ||
        type == SchemaFieldType.map) {
      value = instanceHandle != 0 ? SchemaInstance(instanceHandle) : null;
    } else {
      value = instanceHandle;
    }

    controller.add({'value': value, 'key': key});
  }

  @override
  String toString() => 'ColyseusRoom(ref=$_roomRef)';
}
