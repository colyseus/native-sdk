import 'dart:async';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'colyseus.dart';
import 'message.dart';
import 'room.dart';
import 'schema.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Drives the native runtime and dispatches its events to [ColyseusRoom]s.
///
/// The native SDK runs in polled mode: sockets, matchmaking replies and
/// reconnection only advance inside `colyseus_poll()`, and every callback they
/// fire lands in a native queue that [drain] empties. [pump] does both on the
/// calling thread, so no SDK callback runs on any thread but Dart's.
///
/// Two ways to run it: the built-in ~60 Hz timer (the default), or the app's
/// own frame callback via `Colyseus.pump()`. Apps that pump themselves should
/// set `Colyseus.autoPoll = false` so events aren't also delivered mid-frame
/// by the timer.
class ColyseusEventPoller {
  ColyseusEventPoller._();
  static final ColyseusEventPoller instance = ColyseusEventPoller._();

  Timer? _timer;
  bool _autoPoll = true;
  bool _pumping = false;
  int _holds = 0;
  final Map<int, ColyseusRoom> _rooms = {};
  final Map<int, Completer<ColyseusRoom>> _pendingJoins = {};

  bool get autoPoll => _autoPoll;

  set autoPoll(bool value) {
    if (_autoPoll == value) return;
    _autoPoll = value;
    _updateTimer();
  }

  /// With [autoPoll] off the app owns the pump — except while no room exists,
  /// when a pump has nothing of the app's to deliver mid-frame and a [hold]
  /// would otherwise never advance.
  bool get _wantsTimer => _autoPoll
      ? (_rooms.isNotEmpty || _holds > 0)
      : (_rooms.isEmpty && _holds > 0);

  void _updateTimer() {
    if (_wantsTimer) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => pump());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Keeps the runtime pumping while native work that belongs to no room is
  /// in flight (a latency probe). Call the returned function once it settles.
  void Function() hold() {
    _holds++;
    _updateTimer();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holds--;
      _updateTimer();
    };
  }

  /// Register a room for event dispatch and return a Future that
  /// completes when the JOIN event arrives (or rejects on CLIENT_ERROR).
  Future<ColyseusRoom<T>> registerPendingJoin<T extends SchemaInstance>(
      int roomRef, ColyseusRoom<T> room) {
    _rooms[roomRef] = room;
    final completer = Completer<ColyseusRoom<T>>();
    _pendingJoins[roomRef] = completer;
    _updateTimer();
    return completer.future;
  }

  /// Unregister a room (called on room.dispose()).
  void unregisterRoom(int roomRef) {
    _rooms.remove(roomRef);
    _pendingJoins.remove(roomRef);
    _updateTimer();
  }

  /// Runs one frame of the native runtime, then delivers what it produced.
  ///
  /// A pump from inside a callback this pump is delivering does nothing:
  /// decode and dispatch would re-enter mid-frame.
  void pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      core.colyseus_poll();
      drain();
    } finally {
      _pumping = false;
    }
  }

  /// Delivers every queued native event to its room.
  void drain() {
    // Drain all available events per tick
    for (;;) {
      final eventType = _n.pollEvent();
      if (eventType == 0) break;

      final type = ColyseusEventType.fromValue(eventType);
      final roomRef = _n.eventGetRoom();
      final room = _rooms[roomRef];

      switch (type) {
        case ColyseusEventType.roomJoin:
          if (room != null) {
            room.handleJoin();
            final completer = _pendingJoins.remove(roomRef);
            completer?.complete(room);
          }
          break;

        case ColyseusEventType.roomStateChange:
          room?.handleStateChange();
          break;

        case ColyseusEventType.roomMessage:
          if (room != null) {
            final messageType = _n.messageGetTypeStr().toDartString();
            final data = readCurrentMessage();
            room.handleMessage(messageType, data);
          }
          break;

        case ColyseusEventType.roomError:
          if (room != null) {
            final code = _n.eventGetCode();
            final message = _n.eventGetMessage().toDartString();
            room.handleError(code, message);
          }
          break;

        case ColyseusEventType.roomLeave:
          if (room != null) {
            final code = _n.eventGetCode();
            room.handleLeave(code);
          }
          break;

        case ColyseusEventType.roomDrop:
          if (room != null) {
            final code = _n.eventGetCode();
            final reason = _n.eventGetMessage().toDartString();
            room.handleDrop(code, reason);
          }
          break;

        case ColyseusEventType.roomReconnect:
          room?.handleReconnect();
          break;

        case ColyseusEventType.clientError:
          final code = _n.eventGetCode();
          final message = _n.eventGetMessage().toDartString();
          final completer = _pendingJoins.remove(roomRef);
          if (completer != null && !completer.isCompleted) {
            completer.completeError(ColyseusError(code, message));
          }
          _rooms.remove(roomRef);
          _updateTimer();
          break;

        case ColyseusEventType.propertyChange:
          room?.handlePropertyChange(
            _n.eventGetCallbackHandle(),
            _n.eventGetValueType(),
            _n.eventGetValueNumber(),
            _n.eventGetValueString().toDartString(),
            _n.eventGetPrevValueNumber(),
            _n.eventGetPrevValueString().toDartString(),
            _n.eventGetInstance(),
          );
          break;

        case ColyseusEventType.itemAdd:
          room?.handleItemAdd(
            _n.eventGetCallbackHandle(),
            _n.eventGetKeyString().toDartString(),
            _n.eventGetInstance(),
            _n.eventGetValueType(),
            _n.eventGetValueNumber(),
            _n.eventGetValueString().toDartString(),
          );
          break;

        case ColyseusEventType.itemRemove:
          room?.handleItemRemove(
            _n.eventGetCallbackHandle(),
            _n.eventGetKeyString().toDartString(),
            _n.eventGetInstance(),
            _n.eventGetValueType(),
            _n.eventGetValueNumber(),
            _n.eventGetValueString().toDartString(),
          );
          break;

        case ColyseusEventType.instanceChange:
          room?.handleInstanceChange(_n.eventGetCallbackHandle());
          break;

        case ColyseusEventType.none:
          break;
      }
    }
  }
}
