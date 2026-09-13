import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

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
/// The native SDK never calls into the app from a thread of its own. Sockets,
/// matchmaking replies and reconnection all advance inside [pump], and every
/// event they produce — join, state, messages, schema callbacks, drop,
/// reconnect, leave — is delivered there, on the thread that pumps.
///
/// By default a 16 ms timer pumps for you and nothing else is required. Games
/// should instead drive it from their own frame callback:
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
/// writes inside one frame, which is what makes reads during rendering
/// consistent.
class Colyseus {
  Colyseus._();

  /// Whether the SDK runs its own ~60 Hz poll timer (default true).
  ///
  /// Set false when the app drives [pump] itself; from then on nothing is
  /// delivered between the app's pumps. Existing rooms keep working either
  /// way, and both paths run the same [pump], so a stray double-pump is
  /// harmless. While no room exists the timer still runs a pending
  /// [selectByLatency], which has no frame of the app's to disturb.
  static bool get autoPoll => ColyseusEventPoller.instance.autoPoll;

  static set autoPoll(bool value) =>
      ColyseusEventPoller.instance.autoPoll = value;

  /// Advances the native runtime by one frame and delivers what it produced.
  ///
  /// Completes matchmaking requests, reads and decodes every socket, releases
  /// packets held by [ColyseusRoom.setLatency] and advances reconnection, then
  /// delivers the resulting events — all on the calling thread, before this
  /// returns. A join future completes in the pump that decodes its JOIN.
  ///
  /// Calling it from inside a callback it is delivering does nothing.
  static void pump() => ColyseusEventPoller.instance.pump();

  /// Packets currently held by the latency injector, both directions.
  ///
  /// Non-zero only while an injected delay is in effect; useful as a "network
  /// is busy" readout in debug HUDs.
  static int get packetsInFlight => core.colyseus_netdelay_in_flight();

  /// Picks the lowest-latency endpoint out of [endpoints].
  ///
  /// Measures each one and returns the fastest with its round-trip time, or
  /// null when every endpoint failed. Use it to choose a region before
  /// connecting.
  ///
  /// The probes' sockets advance inside [pump] like a room's; the poll timer
  /// keeps pumping while a measurement runs, even with no room open.
  static Future<({String endpoint, double latencyMs})?> selectByLatency(
    List<String> endpoints, {
    int pingCount = 1,
    int timeoutMs = 1500,
  }) {
    if (endpoints.isEmpty) return Future.value(null);

    final completer = Completer<({String endpoint, double latencyMs})?>();
    late final NativeCallable<Void Function(Pointer<Char>, Double)> callable;
    final release = ColyseusEventPoller.instance.hold();

    // A listener callable, not isolateLocal: the verdict comes from the
    // probes' coordinator thread, which isolateLocal forbids. The endpoint
    // arrives as a copy the native side allocated for exactly this reason,
    // and Dart frees it.
    callable = NativeCallable<Void Function(Pointer<Char>, Double)>.listener(
      (Pointer<Char> best, double latencyMs) {
        String? endpoint;
        if (best != nullptr) {
          endpoint = best.cast<Utf8>().toDartString();
          _n.freeString(best);
        }
        if (!completer.isCompleted) {
          completer.complete(endpoint == null
              ? null
              : (endpoint: endpoint, latencyMs: latencyMs));
        }
        callable.close();
        release();
      },
    );

    final arena = Arena();
    try {
      final list = arena<Pointer<Char>>(endpoints.length);
      for (var i = 0; i < endpoints.length; i++) {
        list[i] = endpoints[i].toNativeUtf8(allocator: arena).cast();
      }

      _n.selectByLatency(
        list,
        endpoints.length,
        pingCount,
        timeoutMs,
        endpoints.first.startsWith('wss://') ? 1 : 0,
        callable.nativeFunction,
      );
    } finally {
      // The core copies the endpoint strings before returning.
      arena.releaseAll();
    }

    return completer.future;
  }

  /// Has no effect: inbound traffic is always decoded on the pumping thread.
  @Deprecated('Decoding always runs inside Colyseus.pump(); remove the call.')
  static set serializedInbound(bool value) {}
}
