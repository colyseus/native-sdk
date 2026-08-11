import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'colyseus.dart';
import 'event_poller.dart';
import 'input_handle.dart';
import 'message.dart';
import 'room_clock.dart';
import 'schema.dart';
import 'schema_view.dart';
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
  int _callbacksHandle = 0;
  RoomClock? _clock;
  InputHandle? _input;
  NativeCallable<Bool Function(Pointer<Void>, Pointer<Void>)>? _allowRewind;

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

  /// The core room pointer the 0.18 APIs take, or `nullptr` before the join
  /// resolves.
  Pointer<colyseus_room> get nativeRoom =>
      Pointer<colyseus_room>.fromAddress(_n.roomPtr(_roomRef));

  /// Clock sync and RTT estimation for this room.
  ///
  /// Only carries real values once the server declares inputs — see
  /// [RoomClock].
  RoomClock get clock {
    final room = nativeRoom;
    if (room == nullptr) {
      throw StateError('Room is not connected yet — await the join first');
    }
    return _clock ??= RoomClock(core.colyseus_room_get_clock(room));
  }

  /// The typed input channel for this room, created on first call.
  ///
  /// Returns null when the server's room does not declare inputs (no
  /// `defineInput()`), in which case prediction isn't available either.
  ///
  /// [options] apply only to the call that creates the handle; later calls
  /// return the same handle and ignore them.
  InputHandle? input([InputOptions options = const InputOptions()]) {
    if (_input != null) return _input;

    final room = nativeRoom;
    if (room == nullptr) {
      throw StateError('Room is not connected yet — await the join first');
    }

    final native = using((arena) {
      final opts = arena<colyseus_input_options_t>();
      opts.ref.unreliable = options.mode == InputMode.unreliable;
      opts.ref.history_size = options.historySize;
      opts.ref.render_delay = options.renderDelay;
      // A NULL vtable tells the core to synthesize the schema from the
      // handshake's input reflection, which is what every dynamic binding does.
      return core.colyseus_room_input(room, nullptr, opts.cast<Void>());
    });

    if (native == nullptr) return null;
    final handle = InputHandle(native);

    if (options.allowRewind != null) {
      _bindAllowRewind(handle, options.allowRewind!);
    }

    return _input = handle;
  }

  /// Installs the lag-compensation gate.
  ///
  /// The core calls this synchronously from inside `send()`, which Dart
  /// itself initiated, so the callback runs on this isolate's own thread and
  /// an isolate-local native callable is safe. A listener callable would be
  /// asynchronous and could not return the verdict the gate needs.
  void _bindAllowRewind(InputHandle handle, bool Function(SchemaView) gate) {
    final view = handle.data;
    _allowRewind = NativeCallable<Bool Function(Pointer<Void>, Pointer<Void>)>
        .isolateLocal(
      (Pointer<Void> data, Pointer<Void> _) {
        try {
          return gate(view);
        } catch (_) {
          // Throwing across the FFI boundary would abort the process; a
          // failed gate just means "don't stamp this input".
          return false;
        }
      },
      exceptionalReturn: false,
    );

    core.colyseus_input_handle_set_allow_rewind(
      handle.handle,
      _allowRewind!.nativeFunction,
      nullptr,
    );
  }

  // ===== Network simulation =====

  /// Injects one-way latency on this room's transport.
  ///
  /// Both directions are delayed by [delayMs] plus up to [jitterMs] of noise,
  /// clamped so jitter can never reorder packets. Values are global across
  /// rooms. Zero for both restores immediate delivery.
  ///
  /// This is a debug facility: use it to see how prediction behaves under a
  /// realistic connection while developing against localhost.
  void setLatency({double delayMs = 0, double jitterMs = 0}) {
    final room = nativeRoom;
    if (room == nullptr) return;
    core.colyseus_netdelay_set(room, delayMs, jitterMs);
  }

  /// Kills the transport as if the network dropped.
  ///
  /// Closes with code 4010, so the SDK treats it as a recoverable drop and
  /// starts reconnecting — [onDrop] fires, then [onReconnect] on success.
  /// Use it to exercise reconnection handling on demand.
  void dropConnection() {
    final room = nativeRoom;
    if (room == nullptr) return;
    core.colyseus_netdelay_drop(room);
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

  /// One native callbacks manager per room, created on first subscription.
  ///
  /// The manager wraps the room's decoder, so it can only be built once the
  /// serializer exists — i.e. after the join handshake.
  int get _callbacks {
    if (_callbacksHandle == 0) {
      _callbacksHandle = _n.callbacksCreate(_roomRef);
      if (_callbacksHandle == 0) {
        throw StateError(
          'Failed to create callbacks manager — is the room joined yet?',
        );
      }
    }
    return _callbacksHandle;
  }

  /// Registers a native schema callback and bridges it to a Dart stream.
  ///
  /// Cancelling the returned subscription unregisters the native callback,
  /// so listeners don't outlive their subscribers.
  StreamSubscription<dynamic> _subscribe(
    int Function(int callbacks, int instance, Pointer<Utf8> property) register,
    Map<int, StreamController<dynamic>> controllers,
    String property,
    int instanceHandle,
    void Function(dynamic event) deliver,
  ) {
    final callbacks = _callbacks;

    final propPtr = property.toNativeUtf8();
    final int handle;
    try {
      handle = register(callbacks, instanceHandle, propPtr);
    } finally {
      malloc.free(propPtr);
    }

    if (handle < 0) {
      throw StateError('Failed to register "$property" callback');
    }

    final controller = StreamController<dynamic>.broadcast(
      onCancel: () {
        _n.callbacksRemoveHandle(callbacks, handle);
        controllers.remove(handle)?.close();
      },
    );
    controllers[handle] = controller;

    return controller.stream.listen(deliver);
  }

  /// Listen to property changes on a schema instance.
  ///
  /// [instanceHandle] defaults to the root state. Cancel the returned
  /// subscription to stop listening and release the native callback.
  StreamSubscription<dynamic> listen(
    String property,
    void Function(dynamic value, dynamic previousValue) callback, {
    int instanceHandle = 0,
  }) {
    return _subscribe(
      _n.callbacksListen,
      _propertyChangeControllers,
      property,
      instanceHandle,
      (event) {
        if (event is Map) callback(event['value'], event['previousValue']);
      },
    );
  }

  /// Listen to items added to a collection.
  StreamSubscription<dynamic> onAdd(
    String property,
    void Function(dynamic value, String key) callback, {
    int instanceHandle = 0,
  }) {
    return _subscribe(
      _n.callbacksOnAdd,
      _itemAddControllers,
      property,
      instanceHandle,
      (event) {
        if (event is Map) callback(event['value'], event['key'] as String);
      },
    );
  }

  /// Listen to items removed from a collection.
  StreamSubscription<dynamic> onRemove(
    String property,
    void Function(dynamic value, String key) callback, {
    int instanceHandle = 0,
  }) {
    return _subscribe(
      _n.callbacksOnRemove,
      _itemRemoveControllers,
      property,
      instanceHandle,
      (event) {
        if (event is Map) callback(event['value'], event['key'] as String);
      },
    );
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

    if (_callbacksHandle != 0) {
      _n.callbacksFree(_callbacksHandle);
      _callbacksHandle = 0;
    }

    _allowRewind?.close();
    _allowRewind = null;

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

  /// Collection items arrive either as instance handles (schema children) or
  /// as values already unboxed by the native trampoline (primitive children,
  /// flagged by the event carrying the child's own field type).
  dynamic _itemValue(
    int valueType,
    int instanceHandle,
    double valueNumber,
    String valueString,
  ) {
    switch (SchemaFieldType.fromValue(valueType)) {
      case SchemaFieldType.ref:
      case SchemaFieldType.array:
      case SchemaFieldType.map:
        return instanceHandle != 0 ? SchemaInstance(instanceHandle) : null;
      case SchemaFieldType.string:
        return valueString;
      case SchemaFieldType.boolean:
        return valueNumber > 0.5;
      case null:
        return null;
      default:
        return valueNumber;
    }
  }

  void handleItemAdd(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
    double valueNumber,
    String valueString,
  ) {
    _itemAddControllers[callbackHandle]?.add({
      'value': _itemValue(valueType, instanceHandle, valueNumber, valueString),
      'key': key,
    });
  }

  void handleItemRemove(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
    double valueNumber,
    String valueString,
  ) {
    _itemRemoveControllers[callbackHandle]?.add({
      'value': _itemValue(valueType, instanceHandle, valueNumber, valueString),
      'key': key,
    });
  }

  @override
  String toString() => 'ColyseusRoom(ref=$_roomRef)';
}
