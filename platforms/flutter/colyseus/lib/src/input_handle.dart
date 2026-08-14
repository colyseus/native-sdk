import 'dart:ffi';

import 'bindings/colyseus_core.dart';
import 'colyseus.dart';
import 'schema_view.dart';

/// How an input channel reaches the server.
enum InputMode {
  /// Ordered and guaranteed. Required for anything the client predicts,
  /// because reconciliation replays the buffered inputs the server acked.
  reliable,

  /// Fire-and-forget. Rejected for now — it needs a WebTransport datagram
  /// channel, which this SDK does not have. [ColyseusRoom.input] throws.
  unreliable,
}

/// Configuration for [ColyseusRoom.input]. First call wins — the handle is
/// created lazily and later calls return the existing one.
class InputOptions {
  /// Delivery mode; defaults to [InputMode.reliable].
  final InputMode mode;

  /// How many seconds of inputs to keep for replay. 0 uses the default (3).
  final int historySize;

  /// Lag-compensation render delay in milliseconds.
  ///
  /// Leave at 0 and the predict layer binds it from its own interpolation
  /// delay — which is what you want, since the server rewinds to the instant
  /// you actually displayed. Set it by hand only when interpolating outside
  /// the predict layer.
  final double renderDelay;

  /// Decides per send whether this input carries a lag-compensation stamp.
  ///
  /// Stamping lets the server rewind other entities to what this client saw.
  /// Gate it on the inputs that need it (`(data) => data.getBool('fire')`)
  /// rather than stamping everything.
  final bool Function(SchemaView data)? allowRewind;

  const InputOptions({
    this.mode = InputMode.reliable,
    this.historySize = 0,
    this.renderDelay = 0,
    this.allowRewind,
  });
}

/// A typed input channel to the server.
///
/// Inputs are not messages: they ride a dedicated channel with sequence
/// numbers and acknowledgements, which is what makes prediction and
/// reconciliation possible. The server's ack rides back on the same channel
/// and drives the room clock, so a predicting client sends one input per tick
/// even when nothing changed.
///
/// Mutate [data], then [send]:
///
/// ```dart
/// final input = room.input();
/// for (var i = 0; i < steps; i++) {
///   input.data['moveX'] = keyboard.moveX;
///   input.data['moveY'] = keyboard.moveY;
///   input.send();
/// }
/// ```
///
/// The schema comes from the server's handshake, so field names match the
/// room's `defineInput()` declaration.
class InputHandle {
  final Pointer<colyseus_input_handle> _handle;
  SchemaView? _data;

  InputHandle(this._handle);

  /// The native handle.
  Pointer<colyseus_input_handle> get handle => _handle;

  /// The mutable input payload.
  ///
  /// One instance reused across sends — set the fields that changed and the
  /// encoder deltas the rest.
  SchemaView get data =>
      _data ??= SchemaView(core.colyseus_input_handle_data(_handle).address);

  /// Transmits the current [data] and returns its sequence number.
  ///
  /// Returns 0 when nothing was sent. Sequences start at 1 and are what
  /// reconcilers key their replay buffer on.
  int send() => core.colyseus_input_handle_send(_handle);

  /// Clears round-trip state and starts a new epoch.
  ///
  /// The next send emits a full snapshot instead of a delta. Reconcilers watch
  /// the epoch and self-reset, which is why this is the right call after a
  /// reconnect — the server counts sequences from zero again.
  void reset() => core.colyseus_input_handle_reset(_handle);

  /// How many inputs have been sent since the last [reset].
  int get sentCount => core.colyseus_input_handle_sent_count(_handle);

  /// The highest sequence the server has confirmed processing.
  int get lastProcessed => core.colyseus_input_handle_last_processed(_handle);

  /// Inputs sent but not yet acknowledged — the depth of the replay buffer,
  /// and a direct read on how much the client is predicting ahead.
  int get pendingCount => core.colyseus_input_handle_pending_count(_handle);

  /// Increments on every [reset]; observers compare it to detect one.
  int get epoch => core.colyseus_input_handle_epoch(_handle);

  /// Server tick rate in Hz, or 0 when the server didn't advertise one.
  int get tickRate => core.colyseus_input_handle_tick_rate(_handle);

  /// Server patch rate in Hz, or 0 when not advertised.
  int get patchRate => core.colyseus_input_handle_patch_rate(_handle);

  /// Simulation sub-steps per tick; at least 1.
  int get subSteps => core.colyseus_input_handle_sub_steps(_handle);

  /// Lag-compensation render delay in milliseconds.
  double get renderDelay => core.colyseus_input_handle_render_delay(_handle);

  set renderDelay(double milliseconds) =>
      core.colyseus_input_handle_set_render_delay(_handle, milliseconds);
}
