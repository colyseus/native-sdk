import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'event_poller.dart';
import 'native_library.dart';

/// The generated bindings over the native SDK's public C API.
///
/// Shared by every wrapper class in this package so the library is opened once.
final core = ColyseusCore(loadColyseusLibrary());

final _n = NativeFunctions.instance;

/// Process-wide runtime control.
///
/// The SDK delivers native events to Dart by draining a queue. By default a
/// 16 ms timer does that for you and nothing else is required. Games should
/// instead drive it from their own frame callback:
///
/// ```dart
/// Colyseus.autoPoll = false;          // once, before joining
///
/// void onTick(Duration _) {
///   Colyseus.pump();                  // decode inbound, deliver events
///   final steps = predict.tick(now);  // then advance prediction
///   for (var i = 0; i < steps; i++) { ...; input.send(); }
///   render();                         // finally read predicted values
/// }
/// ```
///
/// Pumping from the frame callback keeps decode, input acks and prediction
/// writes on one thread and inside one frame, which is what makes reads
/// during rendering consistent.
class Colyseus {
  Colyseus._();

  /// Whether the SDK runs its own ~60 Hz poll timer (default true).
  ///
  /// Set false when the app drives [pump] itself. Existing rooms keep working
  /// either way; both paths share one drain routine and draining is
  /// idempotent, so a stray double-pump is harmless.
  static bool get autoPoll => ColyseusEventPoller.instance.autoPoll;

  static set autoPoll(bool value) =>
      ColyseusEventPoller.instance.autoPoll = value;

  /// Advances the native runtime by one frame and delivers pending events.
  ///
  /// Order matters: inbound frames are released (and therefore decoded) by the
  /// netdelay pump, so it has to run before the event queue is drained or the
  /// events it produces would wait a frame — including the JOIN that resolves
  /// a pending join future.
  static void pump() {
    core.colyseus_netdelay_pump();
    core.colyseus_reconnect_poll();
    ColyseusEventPoller.instance.drain();
  }

  /// Packets currently held by the latency injector, both directions.
  ///
  /// Non-zero only while an injected delay is in effect; useful as a "network
  /// is busy" readout in debug HUDs.
  static int get packetsInFlight => core.colyseus_netdelay_in_flight();

  /// Turns off the transport wrap that serializes inbound decoding onto the
  /// pumping thread.
  ///
  /// On by default and required by the prediction layer. Only disable it for
  /// a client that neither predicts nor injects latency, and do so before
  /// joining any room.
  static set serializedInbound(bool value) =>
      _n.setSerializedInbound(value ? 1 : 0);
}
