import 'dart:async';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'colyseus.dart';
import 'message.dart';
import 'room.dart';
import 'schema.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Drives the native event queue and dispatches to [ColyseusRoom] instances.
///
/// Two ways to run: the built-in ~60 Hz timer (the default), or the app's own
/// frame callback via `Colyseus.pump()`. Both funnel into [drain]; apps that
/// pump themselves should set `Colyseus.autoPoll = false` so events aren't
/// also delivered mid-frame by the timer.
class ColyseusEventPoller {
  ColyseusEventPoller._();
  static final ColyseusEventPoller instance = ColyseusEventPoller._();

  Timer? _timer;
  bool _autoPoll = true;
  final Map<int, ColyseusRoom> _rooms = {};
  final Map<int, Completer<ColyseusRoom>> _pendingJoins = {};

  bool get autoPoll => _autoPoll;

  set autoPoll(bool value) {
    if (_autoPoll == value) return;
    _autoPoll = value;
    if (value) {
      if (_rooms.isNotEmpty) _ensureRunning();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _ensureRunning() {
    if (!_autoPoll) return;
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tick(),
    );
  }

  /// Register a room for event dispatch and return a Future that
  /// completes when the JOIN event arrives (or rejects on CLIENT_ERROR).
  Future<ColyseusRoom<T>> registerPendingJoin<T extends SchemaInstance>(
      int roomRef, ColyseusRoom<T> room) {
    _rooms[roomRef] = room;
    final completer = Completer<ColyseusRoom<T>>();
    _pendingJoins[roomRef] = completer;
    _ensureRunning();
    return completer.future;
  }

  /// Unregister a room (called on room.dispose()).
  void unregisterRoom(int roomRef) {
    _rooms.remove(roomRef);
    _pendingJoins.remove(roomRef);
    if (_rooms.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Timer path: release inbound traffic, then deliver what it produced.
  ///
  /// Inbound frames are queued at the transport seam and only decode inside
  /// the netdelay pump, so draining without pumping first would deliver
  /// nothing.
  void _tick() {
    core.colyseus_netdelay_pump();
    core.colyseus_reconnect_poll();
    drain();
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
