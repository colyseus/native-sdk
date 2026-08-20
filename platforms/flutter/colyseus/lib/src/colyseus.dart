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

  /// Picks the lowest-latency endpoint out of [endpoints].
  ///
  /// Measures each one and returns the fastest with its round-trip time, or
  /// null when every endpoint failed. Use it to choose a region before
  /// connecting.
  ///
  /// Measurement runs on worker threads, so the callback arrives
  /// asynchronously — unlike the predict layer's callbacks, which are
  /// synchronous by construction.
  static Future<({String endpoint, double latencyMs})?> selectByLatency(
    List<String> endpoints, {
    int pingCount = 1,
    int timeoutMs = 1500,
  }) {
    if (endpoints.isEmpty) return Future.value(null);

    final completer = Completer<({String endpoint, double latencyMs})?>();
    late final NativeCallable<Void Function(Pointer<Char>, Double)> callable;

    // A listener callable, not isolateLocal: measurement finishes on a worker
    // thread, which isolateLocal forbids. The endpoint arrives as a copy the
    // native side allocated for exactly this reason, and Dart frees it.
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

  /// Turns off the transport wrap that serializes inbound decoding onto the
  /// pumping thread.
  ///
  /// On by default and required by the prediction layer. Only disable it for
  /// a client that neither predicts nor injects latency, and do so before
  /// joining any room.
  static set serializedInbound(bool value) =>
      _n.setSerializedInbound(value ? 1 : 0);
}
