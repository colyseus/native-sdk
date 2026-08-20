import 'dart:ffi';

import 'bindings/colyseus_core.dart';
import 'colyseus.dart';

/// Clock sync and RTT estimation for a room.
///
/// Fed by the TIMED prefix the server prepends to state messages once the room
/// declares inputs via `defineInput()`. A room that never declares inputs
/// never receives samples: [serverNow] then equals [now] and the rest read
/// zero.
///
/// Reach it through `room.clock`.
class RoomClock {
  final Pointer<colyseus_room_clock> _handle;

  RoomClock(this._handle);

  /// Local monotonic milliseconds — the base [serverNow] offsets.
  ///
  /// This is the timebase `predict.tick()` expects, so drive the frame loop
  /// from it rather than from `DateTime.now()`.
  double get now => core.colyseus_room_clock_now(_handle);

  /// Estimated server clock: milliseconds since the room started.
  double get serverNow => core.colyseus_room_clock_server_now(_handle);

  /// Server clock on a slew-limited timeline, for drawing.
  ///
  /// Free-runs at 1 ms/ms and servos toward [serverNow] instead of jumping, so
  /// interpolated entities don't stutter when an estimate lands. Never use it
  /// for server-stamped deadlines — use [serverNow].
  double get renderNow => core.colyseus_room_clock_render_now(_handle);

  /// Most recent round-trip sample in milliseconds; 0 before the first one.
  double get rtt => core.colyseus_room_clock_rtt(_handle);

  /// EMA-smoothed round-trip time; prefer this for forward prediction.
  double get smoothedRtt => core.colyseus_room_clock_smoothed_rtt(_handle);

  /// Interarrival jitter in milliseconds, against the advertised patch rate.
  double get jitter => core.colyseus_room_clock_jitter(_handle);

  /// Server encode time of the most recent snapshot.
  double get lastServerTime =>
      core.colyseus_room_clock_last_server_time(_handle);

  /// Advertised patch interval in milliseconds.
  double get patchInterval => core.colyseus_room_clock_patch_interval(_handle);

  /// The estimated offset between the local and server clocks.
  double get offset => core.colyseus_room_clock_offset(_handle);

  /// Time constant for [renderNow]'s slewing, in milliseconds.
  ///
  /// Lower reacts faster and jitters more; values <= 0 disable slewing so
  /// [renderNow] tracks [serverNow] exactly.
  set renderTau(double milliseconds) =>
      core.colyseus_room_clock_set_render_tau(_handle, milliseconds);

  /// The native handle.
  Pointer<colyseus_room_clock> get handle => _handle;
}
