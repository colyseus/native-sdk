import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'colyseus.dart';
import 'interned_names.dart';
import 'payload_registry.dart';

/// A channel of optimistic events of one logical kind.
///
/// Some things a game does aren't positions — scoring a goal, firing a weapon,
/// picking something up. Prediction still applies: show it immediately, then
/// let the server agree or overrule. This channel tracks predictions the
/// client has made but the server hasn't settled.
///
/// Predict from the simulation with [StepContext.predict], which is
/// replay-safe (a rollback replay won't re-fire it), or from UI code with
/// [predict]. Settle with [confirm] when the authoritative signal arrives:
///
/// ```dart
/// final goals = predict.defineEvent(
///   onPredict: (payload) => showGoalBanner(),
///   onReject: (payload) => retractGoalBanner(),
/// );
///
/// // inside the reconciler step, when the predicted position crosses the line
/// ctx.predict(goals, 'goal:${ctx.tick}');
///
/// room.onMessage('goal').listen((_) => goals.confirm());
/// ```
///
/// Unsettled predictions don't linger: sim-born ones auto-reject once the
/// server has processed past them, UI-born ones expire on a wall clock.
class EventChannel {
  final Pointer<colyseus_event_channel> _handle;
  final List<NativeCallable> _callables;
  bool _disposed = false;

  EventChannel._(this._handle, this._callables);

  /// Builds a channel. Prefer [Predict.defineEvent], which also drives it.
  static EventChannel create({
    required Pointer<colyseus_room_clock> clock,
    void Function(Object? payload)? onPredict,
    void Function(Object? payload)? onConfirm,
    void Function(Object? payload)? onReject,
    void Function(String key)? onUnpredicted,
    int graceTicks = 0,
    double ttlMs = 0,
    double cooldownMs = 0,
  }) {
    final callables = <NativeCallable>[];

    NativeCallable<Void Function(Pointer<Void>, Pointer<Void>)>? wrap(
      void Function(Object?)? handler, {
      required bool releases,
    }) {
      if (handler == null && !releases) return null;
      final callable =
          NativeCallable<Void Function(Pointer<Void>, Pointer<Void>)>
              .isolateLocal((Pointer<Void> payload, Pointer<Void> _) {
        try {
          handler?.call(payloadFor(payload));
        } catch (_) {
          // Never unwind into C.
        }
      });
      callables.add(callable);
      return callable;
    }

    final predictCb = wrap(onPredict, releases: false);
    final confirmCb = wrap(onConfirm, releases: false);
    final rejectCb = wrap(onReject, releases: false);

    NativeCallable<Void Function(Pointer<Char>, Pointer<Void>)>? unpredictedCb;
    if (onUnpredicted != null) {
      unpredictedCb =
          NativeCallable<Void Function(Pointer<Char>, Pointer<Void>)>
              .isolateLocal((Pointer<Char> key, Pointer<Void> _) {
        try {
          onUnpredicted(key == nullptr ? '' : key.cast<Utf8>().toDartString());
        } catch (_) {}
      });
      callables.add(unpredictedCb);
    }

    // Runs after a settle callback and on silent drops — the one place a
    // payload's registry slot can be released without leaking or double-free.
    final freeCb = NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
      (Pointer<Void> payload) => releasePayload(payload),
    );
    callables.add(freeCb);

    final handle = using((arena) {
      final options = arena<colyseus_event_channel_options_t>();
      if (predictCb != null) options.ref.on_predict = predictCb.nativeFunction;
      if (confirmCb != null) options.ref.on_confirm = confirmCb.nativeFunction;
      if (rejectCb != null) options.ref.on_reject = rejectCb.nativeFunction;
      if (unpredictedCb != null) {
        options.ref.on_unpredicted = unpredictedCb.nativeFunction;
      }
      options.ref.payload_free = freeCb.nativeFunction;
      options.ref.grace_ticks = graceTicks;
      options.ref.ttl_ms = ttlMs;
      options.ref.cooldown_ms = cooldownMs;
      return core.colyseus_event_channel_create(options, clock);
    });

    if (handle == nullptr) {
      for (final callable in callables) {
        callable.close();
      }
      throw StateError('Could not create an event channel');
    }

    return EventChannel._(handle, callables);
  }

  /// The native handle.
  Pointer<colyseus_event_channel> get handle => _handle;

  /// Predicts an event from outside the simulation, for UI-driven optimism.
  ///
  /// Returns false when the prediction was dropped — [key] is already pending,
  /// or a cooldown is in effect. Settles on a wall clock, unlike the sim-born
  /// form, which settles on server progress.
  bool predict(String key, [Object? payload]) {
    return core.colyseus_event_channel_predict(
      _handle,
      internedName(key),
      retainPayload(payload),
    );
  }

  /// Whether [key] (or anything, when null) is awaiting settlement.
  bool has([String? key]) => core.colyseus_event_channel_has(
        _handle,
        key == null ? nullptr : internedName(key),
      );

  /// How many predictions are awaiting settlement.
  int get pendingCount => core.colyseus_event_channel_pending_count(_handle);

  /// Settles [key] (or every pending prediction) as correct.
  ///
  /// Returns how many were settled. Zero means the server signalled something
  /// this client never predicted, which fires `onUnpredicted`.
  int confirm([String? key]) => core.colyseus_event_channel_confirm(
        _handle,
        key == null ? nullptr : internedName(key),
      );

  /// Settles [key] (or every pending prediction) as wrong, firing `onReject`.
  int reject([String? key]) => core.colyseus_event_channel_reject(
        _handle,
        key == null ? nullptr : internedName(key),
      );

  /// Drops every pending prediction without firing confirm or reject.
  void clear() => core.colyseus_event_channel_clear(_handle);

  /// Releases the channel.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    core.colyseus_event_channel_free(_handle);
    for (final callable in _callables) {
      callable.close();
    }
    _callables.clear();
  }
}
