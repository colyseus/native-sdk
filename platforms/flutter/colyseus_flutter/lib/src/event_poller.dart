import 'dart:async';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'room.dart';
import 'types.dart';
import 'message.dart';

final _n = NativeFunctions.instance;

/// Singleton event poller that drives the native event queue.
/// Runs a Timer.periodic at ~60fps to poll events from the C layer
/// and dispatch them to the appropriate ColyseusRoom instances.
class ColyseusEventPoller {
  ColyseusEventPoller._();
  static final ColyseusEventPoller instance = ColyseusEventPoller._();

  Timer? _timer;
  final Map<int, ColyseusRoom> _rooms = {};
  final Map<int, Completer<ColyseusRoom>> _pendingJoins = {};

  void _ensureRunning() {
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _poll(),
    );
  }

  /// Register a room for event dispatch and return a Future that
  /// completes when the JOIN event arrives (or rejects on CLIENT_ERROR).
  Future<ColyseusRoom> registerPendingJoin(int roomRef, ColyseusRoom room) {
    _rooms[roomRef] = room;
    final completer = Completer<ColyseusRoom>();
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

  void _poll() {
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
          );
          break;

        case ColyseusEventType.itemRemove:
          room?.handleItemRemove(
            _n.eventGetCallbackHandle(),
            _n.eventGetKeyString().toDartString(),
            _n.eventGetInstance(),
            _n.eventGetValueType(),
          );
          break;

        case ColyseusEventType.none:
          break;
      }
    }
  }
}
