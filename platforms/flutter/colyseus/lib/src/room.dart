import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'callbacks.dart';
import 'colyseus.dart';
import 'event_poller.dart';
import 'input_handle.dart';
import 'predict.dart';
import 'message.dart';
import 'room_clock.dart';
import 'schema.dart';
import 'schema_ref.dart';
import 'schema_view.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Represents a room connection to a Colyseus server.
///
/// [TState] is the room's schema root. Joining with a generated class —
/// `client.joinOrCreate('my_room', stateType: MyRoomState.new)`, the Dart
/// spelling of C#'s `JoinOrCreate<MyRoomState>("my_room")` — types [state]
/// and [onStateChange]; joining without one leaves them on the dynamic
/// [SchemaInstance] accessors.
///
/// All events are exposed as [Stream]s for idiomatic Dart usage:
/// ```dart
/// final room = await client.joinOrCreate('my_room',
///     stateType: MyRoomState.new);
///
/// final state = await room.onStateChange.first;   // typed, first patch
/// print(state.players.length);
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
class ColyseusRoom<TState extends SchemaInstance> {
  final int _roomRef;
  final TState Function(int handle)? _stateType;
  TState? _stateWrapper;
  int _stateWrapperHandle = 0;

  final _onJoinController = StreamController<void>.broadcast();
  final _onStateChangeController = StreamController<TState>.broadcast();
  final _onErrorController = StreamController<ColyseusError>.broadcast();
  final _onLeaveController = StreamController<int>.broadcast();
  final _onDropController = StreamController<ColyseusError>.broadcast();
  final _onReconnectController = StreamController<void>.broadcast();
  final Map<String, StreamController<dynamic>> _messageControllers = {};
  final _onMessageAnyController =
      StreamController<MapEntry<String, dynamic>>.broadcast();

  StateCallbacks? _stateCallbacks;
  RoomClock? _clock;
  InputHandle? _input;
  NativeCallable<Bool Function(Pointer<Void>, Pointer<Void>)>? _allowRewind;

  /// Prediction layers built over this room.
  ///
  /// Tearing a Predict down touches the room's callbacks layer and decoder, so
  /// they have to go before the room does. Tracking them here means
  /// [dispose] can enforce that instead of leaving it to call order.
  final List<Predict> _predicts = [];

  ColyseusRoom._(this._roomRef, this._stateType);

  /// Create a room instance (called internally by ColyseusClient).
  @internal
  static ColyseusRoom<T> create<T extends SchemaInstance>(
      int roomRef, T Function(int handle)? stateType) {
    return ColyseusRoom<T>._(roomRef, stateType);
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

  /// The root state, or null before the first patch decodes.
  ///
  /// Typed by the `stateType:` the room was joined with; a room joined
  /// without one reads dynamically through [SchemaInstance]. The typed
  /// wrapper is kept for as long as the underlying instance lives, so
  /// reading this every frame is cheap.
  TState? get state {
    final handle = _n.roomGetState(_roomRef);
    if (handle == 0) return null;

    final create = _stateType;
    if (create == null) return SchemaInstance(handle) as TState;

    // The root handle only changes when the decoder rebuilds the state
    // (reconnect); the wrapper follows it.
    final cached = _stateWrapper;
    if (cached != null && _stateWrapperHandle == handle) return cached;

    final made = create(handle);
    // Children resolved through the wrapper share the room's schema cache.
    if (made is SchemaRef) made.attachCache(schemaCache);
    _stateWrapper = made;
    _stateWrapperHandle = handle;
    return made;
  }

  /// The root state wrapped in [create] — for narrowing to a class other
  /// than the room's own `stateType:` (a façade over part of the schema,
  /// say). Rooms joined with a `stateType:` mostly want [state] instead.
  ///
  /// Wrappers come from this room's [schemaCache], so calling this every
  /// frame hands back the same instances with their field resolution warm.
  T? stateAs<T extends SchemaRef>(T Function(int handle) create) {
    final handle = _n.roomGetState(_roomRef);
    return handle != 0 ? schemaCache.wrap(handle, create) : null;
  }

  /// Wrapper identity for typed schema access; cleared on reconnect and
  /// dispose, when the decoder replaces instances wholesale.
  @internal
  final SchemaCache schemaCache = SchemaCache();

  /// The schema-callbacks surface for this room; reach it via [Callbacks.get].
  @internal
  StateCallbacks get stateCallbacks =>
      _stateCallbacks ??= StateCallbacks.internal(this);

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

  /// Measures the round trip to this room over the live connection.
  ///
  /// Distinct from [RoomClock.rtt], which is a passive estimate riding the
  /// input stream: this actively sends a ping. Rooms without inputs have no
  /// clock samples at all, so this is the only round-trip figure they get.
  ///
  /// Completes with the round-trip time in milliseconds. Never completes if
  /// the connection closes first, so give it a timeout.
  Future<int> ping() {
    final room = nativeRoom;
    if (room == nullptr) {
      throw StateError('Room is not connected yet — await the join first');
    }

    final completer = Completer<int>();
    late final NativeCallable<Void Function(Int, Pointer<Void>)> callable;
    callable = NativeCallable<Void Function(Int, Pointer<Void>)>.isolateLocal(
      (int rttMs, Pointer<Void> _) {
        if (!completer.isCompleted) completer.complete(rttMs);
        callable.close();
      },
    );

    core.colyseus_room_ping(room, callable.nativeFunction, nullptr);
    return completer.future;
  }

  // ===== Network simulation =====

  /// Injects latency on this room's transport.
  ///
  /// [delayMs] and [jitterMs] are ROUND TRIPS, split evenly across the two
  /// directions — the same meaning the JS SDK's `__net()` has, so a given
  /// number produces the same `clock.smoothedRtt` on every SDK. Jitter is
  /// symmetric and clamped so it can never reorder packets. Values are global
  /// across rooms. Zero for both restores immediate delivery.
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

  /// Fires with the (typed) root state after every decoded patch.
  ///
  /// `room.onStateChange.first` is the bind-once idiom: the first event is
  /// the first decoded state, the place to register schema callbacks.
  Stream<TState> get onStateChange => _onStateChangeController.stream;

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

  // ===== Lifecycle =====

  /// Leave the room gracefully.
  Future<void> leave() async {
    _n.roomLeave(_roomRef);
  }

  @internal
  /// Registers a prediction layer for ordered teardown. Called by [Predict.get].
  void registerPredict(Predict predict) => _predicts.add(predict);

  @internal
  /// Forgets a prediction layer that disposed itself.
  void unregisterPredict(Predict predict) => _predicts.remove(predict);

  /// Dispose all resources. Call after leaving.
  void dispose() {
    // Before anything else: a Predict deregisters its schema callbacks on the
    // way out, and those live on the room's decoder.
    for (final predict in _predicts.toList()) {
      predict.dispose();
    }
    _predicts.clear();

    _stateCallbacks?.dispose();
    _stateCallbacks = null;
    schemaCache.clear();
    _stateWrapper = null;
    _stateWrapperHandle = 0;

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
    final current = state;
    if (current != null) _onStateChangeController.add(current);
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
    // The reconnect handshake resyncs the full state, freeing and replacing
    // every decoded instance — cached wrappers must not survive it.
    schemaCache.clear();
    _stateWrapper = null;
    _stateWrapperHandle = 0;
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
    _stateCallbacks?.dispatchPropertyChange(callbackHandle, valueType,
        valueNumber, valueString, prevValueNumber, prevValueString,
        instanceHandle);
  }

  void handleItemAdd(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
    double valueNumber,
    String valueString,
  ) {
    _stateCallbacks?.dispatchItemAdd(
        callbackHandle, key, instanceHandle, valueType, valueNumber,
        valueString);
  }

  void handleItemRemove(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
    double valueNumber,
    String valueString,
  ) {
    _stateCallbacks?.dispatchItemRemove(
        callbackHandle, key, instanceHandle, valueType, valueNumber,
        valueString);
  }

  void handleInstanceChange(int callbackHandle) {
    _stateCallbacks?.dispatchInstanceChange(callbackHandle);
  }

  @override
  String toString() => 'ColyseusRoom(ref=$_roomRef)';
}
