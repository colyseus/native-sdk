import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'bindings/colyseus_core.dart';
import 'colyseus.dart';
import 'events.dart';
import 'input_handle.dart';
import 'interned_names.dart';
import 'reconciler.dart';
import 'room.dart';
import 'schema.dart';
import 'schema_view.dart';
import 'sim_reconciler.dart';
import 'spawns.dart';

/// How a tracked field follows the server stream.
///
/// Values mirror the C `colyseus_predict_mode_t`. They are spelled out rather
/// than read off the generated enum because Dart enum initializers must be
/// compile-time constants; [_assertModesMatchNative] pins them to it.
enum PredictMode {
  /// Render slightly in the past and interpolate between real samples.
  /// Always accurate, never ahead — the default for entities you don't
  /// control.
  lerp(0),

  /// Continue the last known velocity past the newest sample. Hides latency
  /// at the cost of overshooting when the entity changes direction.
  extrapolate(1),

  /// Spring toward the newest sample. No added delay and no overshoot, but
  /// it lags during sustained motion.
  damped(2),

  /// Forward-simulate the last snapshot with a step function shared with the
  /// server. Exact while the entity follows the shared rules.
  reckon(3),

  /// No smoothing — read the last decoded value.
  raw(4);

  final int value;
  const PredictMode(this.value);
}

/// Fails loudly in debug builds if the generated enum ever renumbers.
bool _assertModesMatchNative() {
  assert(
    PredictMode.lerp.value == colyseus_predict_mode_t.COLYSEUS_PREDICT_LERP.value &&
        PredictMode.extrapolate.value ==
            colyseus_predict_mode_t.COLYSEUS_PREDICT_EXTRAPOLATE.value &&
        PredictMode.damped.value ==
            colyseus_predict_mode_t.COLYSEUS_PREDICT_DAMPED.value &&
        PredictMode.reckon.value ==
            colyseus_predict_mode_t.COLYSEUS_PREDICT_RECKON.value &&
        PredictMode.raw.value == colyseus_predict_mode_t.COLYSEUS_PREDICT_RAW.value,
    'PredictMode has drifted from colyseus_predict_mode_t',
  );
  return true;
}

/// Per-field smoothing settings. Zero values take the reference defaults.
class FieldOptions {
  final PredictMode mode;

  /// Interpolation delay in milliseconds for [PredictMode.lerp] (default 100).
  ///
  /// Must match what the app actually displays: with lag compensation the
  /// server rewinds to this instant, so a mismatch makes it rewind to a frame
  /// the player never saw.
  final double delay;

  /// Spring constant (1/s) for damped and extrapolate (default 15).
  final double damping;

  /// Cap on how far extrapolation may run past the newest sample, in
  /// milliseconds (default 200).
  final double maxExtrapolate;

  /// Snap samples to an arrival grid of this many milliseconds; 0 is off.
  final double tickInterval;

  /// Distance beyond which a change is treated as a teleport and applied
  /// instantly instead of smoothed; 0 is off.
  final double snap;

  /// Treat the field as radians and take the shortest arc between samples.
  final bool angle;

  const FieldOptions({
    this.mode = PredictMode.lerp,
    this.delay = 0,
    this.damping = 0,
    this.maxExtrapolate = 0,
    this.tickInterval = 0,
    this.snap = 0,
    this.angle = false,
  });

  /// Fills a native options struct.
  void _write(Pointer<colyseus_predict_field_options_t> out) {
    assert(_assertModesMatchNative());
    out.ref.modeAsInt = mode.value;
    out.ref.delay = delay;
    out.ref.damping = damping;
    out.ref.max_extrapolate = maxExtrapolate;
    out.ref.tick_interval = tickInterval;
    out.ref.snap = snap;
    out.ref.angle = angle;
  }
}

/// Advances a dead-reckoned entity in place.
///
/// [state] is a scratch copy of the latest snapshot, [dt] the step in seconds
/// and [elapsedMs] the absolute server time at the end of the step. Must
/// integrate the same motion the server does, or the entity will drift.
typedef ReckonStep = void Function(
  SchemaView state,
  double dt,
  double elapsedMs,
);

/// Smoothing and prediction for a room's entities.
///
/// The problem it solves: state arrives at the patch rate (20 Hz for the
/// prediction playground) but rendering runs at 60+ Hz. Reading decoded state
/// directly gives visible stepping, and for the entity the player controls it
/// also gives a full round-trip of input lag.
///
/// Two halves:
/// - Entities you don't control are *smoothed* — [attachAll] and [value].
/// - The entity you do control is *predicted and reconciled* — [reconciler].
///
/// Call [tick] once per frame; it drives everything, and returns how many
/// inputs are due:
///
/// ```dart
/// final predict = Predict.of(room);
/// predict.attachAll('players', config: {'x': PredictMode.damped,
///                                       'y': PredictMode.damped},
///                   exceptKey: room.sessionId);
///
/// void frame(double now) {
///   final steps = predict.tick(now);
///   for (var i = 0; i < steps; i++) { input.data['moveX'] = ...; input.send(); }
///   for (final p in players.values) {
///     draw(predict.value(p, 'x'), predict.value(p, 'y'));
///   }
/// }
/// ```
class Predict {
  final Pointer<colyseus_predict> _handle;
  final ColyseusRoom _room;
  final List<NativeCallable> _callables = [];
  final List<Reconciler> _children = [];
  final List<EventChannel> _channels = [];
  final List<Spawns> _spawns = [];
  bool _disposed = false;

  Predict._(this._handle, this._room);

  /// The prediction layer for [room], wired to its clock and input channel.
  ///
  /// Each call builds a new one; hold onto the result and [dispose] it when
  /// the screen goes away. Disposing the room also disposes it, so it can
  /// never outlive the decoder its callbacks live on.
  factory Predict.of(ColyseusRoom room) {
    final native = room.nativeRoom;
    if (native == nullptr) {
      throw StateError('Room is not connected yet — await the join first');
    }
    final predict = Predict._(core.colyseus_predict_for_room(native), room);
    room.registerPredict(predict);
    return predict;
  }

  /// The native handle.
  Pointer<colyseus_predict> get handle => _handle;

  /// Smooths [instance]'s fields per [config].
  ///
  /// Values are a [PredictMode] or a [FieldOptions]. Fields the instance's
  /// schema doesn't declare are ignored, so one config can cover a mixed
  /// collection.
  void attach(SchemaInstance instance, Map<String, Object> config) {
    _withConfig(config, (cfg, count) {
      core.colyseus_predict_attach(
        _handle,
        Pointer<colyseus_schema_t>.fromAddress(instance.handle),
        cfg,
        count,
      );
    });
  }

  /// Smooths every entry of [collection], including ones that arrive later,
  /// and stops when they are removed.
  ///
  /// Pass [exceptKey] your own session id to leave your entity to the
  /// reconciler. With no [config], every numeric field is tracked using
  /// [fallback].
  void attachAll(
    String collection, {
    Map<String, Object>? config,
    String? exceptKey,
    FieldOptions? fallback,
  }) {
    final state = _rootState();
    using((arena) {
      final collectionPtr = collection.toNativeUtf8(allocator: arena);
      final exceptPtr = exceptKey == null
          ? nullptr
          : exceptKey.toNativeUtf8(allocator: arena);
      final fallbackPtr = fallback == null
          ? nullptr
          : (arena<colyseus_predict_field_options_t>()..let(fallback._write));

      if (config == null) {
        core.colyseus_predict_attach_all(_handle, state, collectionPtr.cast(),
            nullptr, 0, exceptPtr.cast(), fallbackPtr);
        return;
      }

      _withConfig(config, (cfg, count) {
        core.colyseus_predict_attach_all(_handle, state, collectionPtr.cast(),
            cfg, count, exceptPtr.cast(), fallbackPtr);
      });
    });
  }

  /// Dead-reckons every entry of [collection] with [step].
  ///
  /// Use when the entities follow rules the client also knows (patrolling
  /// bots, projectiles): forward-simulating the last snapshot beats
  /// interpolating it, because the result is exact rather than delayed.
  ///
  /// [smoothing] of 0 projects raw, which is right for deterministic motion.
  void attachAllReckon(
    String collection,
    List<String> fields,
    ReckonStep step, {
    double smoothing = 0,
    double substepMs = 0,
    double snap = 0,
  }) {
    final state = _rootState();
    final callable = _reckonCallable(step);

    using((arena) {
      final collectionPtr = collection.toNativeUtf8(allocator: arena);
      final fieldPtrs = arena<Pointer<Char>>(fields.length);
      for (var i = 0; i < fields.length; i++) {
        fieldPtrs[i] = fields[i].toNativeUtf8(allocator: arena).cast();
      }

      core.colyseus_predict_attach_all_reckon(
        _handle,
        state,
        collectionPtr.cast(),
        nullptr, // per-entry vtable — required for reflection schemas
        fieldPtrs,
        fields.length,
        callable.nativeFunction,
        smoothing,
        substepMs,
        snap,
        nullptr,
      );
    });
  }

  /// Dead-reckons one instance with [step].
  void attachReckon(
    SchemaInstance instance,
    List<String> fields,
    ReckonStep step, {
    double smoothing = 0,
    double substepMs = 0,
    double snap = 0,
  }) {
    final callable = _reckonCallable(step);

    using((arena) {
      final fieldPtrs = arena<Pointer<Char>>(fields.length);
      for (var i = 0; i < fields.length; i++) {
        fieldPtrs[i] = fields[i].toNativeUtf8(allocator: arena).cast();
      }

      core.colyseus_predict_attach_reckon(
        _handle,
        Pointer<colyseus_schema_t>.fromAddress(instance.handle),
        nullptr,
        fieldPtrs,
        fields.length,
        callable.nativeFunction,
        smoothing,
        substepMs,
        snap,
        nullptr,
      );
    });
  }

  /// Stops smoothing every field of [instance].
  void detach(SchemaInstance instance) {
    core.colyseus_predict_detach(
      _handle,
      Pointer<colyseus_schema_t>.fromAddress(instance.handle),
    );
  }

  /// Advances one frame and returns how many fixed input steps are due.
  ///
  /// Send exactly one input per returned step to stay on the server's
  /// cadence. Returns 0 until a reconciler advertises the step rate, and never
  /// more than 5 — a hitch drops the backlog instead of firing a burst.
  ///
  /// [now] must come from [RoomClock.now], not `DateTime`.
  int tick(double now) => core.colyseus_predict_tick(_handle, now);

  /// The value to draw [field] at, smoothed per its attach config.
  ///
  /// Falls back to the raw decoded value for untracked fields, so it is always
  /// safe to read through.
  double value(SchemaInstance instance, String field) {
    return core.colyseus_predict_value(
      _handle,
      Pointer<colyseus_schema_t>.fromAddress(instance.handle),
      internedName(field),
    );
  }

  /// The raw reckoned value of [field] at server-time [time].
  ///
  /// For game logic rather than drawing: no smoothing offset is applied, so
  /// two clients asking the same question at the same instant get the same
  /// answer. Reckoning into the past clamps to the last snapshot.
  double valueAt(SchemaInstance instance, String field, double time) {
    return core.colyseus_predict_value_at(
      _handle,
      Pointer<colyseus_schema_t>.fromAddress(instance.handle),
      internedName(field),
      time,
    );
  }

  /// Creates a reconciler for the entity this client controls.
  ///
  /// See [Reconciler] for what it does and how [step] must behave.
  Reconciler reconciler(
    SchemaInstance truth, {
    required InputHandle input,
    required ReconcilerStep step,
    List<String>? fields,
    double smoothing = -1,
    double snap = 0,
    double stepMs = 0,
    int subSteps = 0,
    void Function(int ackedSeq)? onReconcile,
  }) {
    final child = Reconciler.create(
      predict: this,
      truth: truth,
      input: input,
      step: step,
      fields: fields,
      smoothing: smoothing,
      snap: snap,
      stepMs: stepMs,
      subSteps: subSteps,
      onReconcile: onReconcile,
    );
    return child;
  }

  /// Creates an optimistic-event channel driven by [tick].
  ///
  /// See [EventChannel] for what it does. [graceTicks] is how far the server
  /// may progress past a sim-born prediction before it auto-rejects.
  EventChannel defineEvent({
    void Function(Object? payload)? onPredict,
    void Function(Object? payload)? onConfirm,
    void Function(Object? payload)? onReject,
    void Function(String key)? onUnpredicted,
    int graceTicks = 0,
    double ttlMs = 0,
    double cooldownMs = 0,
  }) {
    final channel = EventChannel.create(
      clock: _room.clock.handle,
      onPredict: onPredict,
      onConfirm: onConfirm,
      onReject: onReject,
      onUnpredicted: onUnpredicted,
      graceTicks: graceTicks,
      ttlMs: ttlMs,
      cooldownMs: cooldownMs,
    );
    core.colyseus_predict_drive_events(_handle, channel.handle);
    _channels.add(channel);
    return channel;
  }

  /// Creates a predicted-spawn store bound to [collection].
  ///
  /// The collection's additions and removals are routed into the store, and
  /// the store is advanced by [tick] — this is the whole wiring a predicted
  /// collection needs. See [Spawns].
  Spawns spawns(String collection, SpawnsOptions options) {
    final store = Spawns.create(clock: _room.clock.handle, options: options);
    final state = _rootState();

    using((arena) {
      final collectionPtr = collection.toNativeUtf8(allocator: arena);

      Pointer<colyseus_spawns_reckon_t> reckon = nullptr;
      if (options.fields != null && options.reckonStep != null) {
        final fields = options.fields!;
        final names = arena<Pointer<Char>>(fields.length);
        for (var i = 0; i < fields.length; i++) {
          names[i] = fields[i].toNativeUtf8(allocator: arena).cast();
        }

        final callable = _reckonCallable(
          (state, dt, elapsedMs) => options.reckonStep!(state, dt, elapsedMs),
        );

        reckon = arena<colyseus_spawns_reckon_t>();
        reckon.ref.fields = names;
        reckon.ref.field_count = fields.length;
        reckon.ref.step = callable.nativeFunction;
        // Raw projection: a deterministic constant-step projectile rebases
        // exactly, so smoothing would only add lag.
        reckon.ref.smoothing = 0;
      }

      core.colyseus_predict_bind_spawns(
        _handle,
        store.handle,
        state,
        collectionPtr.cast(),
        reckon,
      );
    });

    _spawns.add(store);
    return store;
  }

  /// Releases the prediction layer and everything it drives.
  ///
  /// Safe to call twice, and called for you by [ColyseusRoom.dispose].
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final child in _children.toList()) {
      child.dispose();
    }
    _children.clear();

    // Children deregister themselves from the driver as they go, so they all
    // have to be gone before the Predict itself is freed.
    for (final channel in _channels) {
      channel.dispose();
    }
    _channels.clear();
    for (final store in _spawns) {
      store.dispose();
    }
    _spawns.clear();

    core.colyseus_predict_free(_handle);
    _room.unregisterPredict(this);

    for (final callable in _callables) {
      callable.close();
    }
    _callables.clear();
  }

  @internal
  /// Called by a child that was disposed on its own.
  void forget(Reconciler child) => _children.remove(child);

  @internal
  /// Registers a reconciler built outside [reconciler] for ordered teardown.
  void adoptChild(Reconciler child) {
    if (!_children.contains(child)) _children.add(child);
  }

  /// Creates a composite reconciler over several interacting entities.
  ///
  /// See [createSimReconciler] for when this beats a flat [reconciler].
  Reconciler sim({
    required InputHandle input,
    required SimStep step,
    required SimOptions options,
  }) {
    return createSimReconciler(
      predict: this,
      input: input,
      step: step,
      options: options,
    );
  }

  /// The root state, re-read every time.
  ///
  /// The decoder can free and replace instances, so caching the pointer would
  /// leave a dangling read after a resync.
  Pointer<colyseus_schema_t> _rootState() {
    final state = _room.state;
    if (state == null) {
      throw StateError('Room state has not decoded yet');
    }
    return Pointer<colyseus_schema_t>.fromAddress(state.handle);
  }

  /// Wraps [step] in a native callable and keeps it alive for this Predict.
  ///
  /// The core calls it synchronously from inside `tick()`, which Dart
  /// initiated, so it runs on this isolate's own thread.
  NativeCallable<Void Function(Pointer<colyseus_schema_t>, Double, Double,
      Pointer<Void>)> _reckonCallable(ReckonStep step) {
    // One view per scratch pointer: the core reuses a small set of scratch
    // instances, so this cache stays tiny and skips re-resolving field names.
    final views = <int, SchemaView>{};

    final callable = NativeCallable<
        Void Function(Pointer<colyseus_schema_t>, Double, Double,
            Pointer<Void>)>.isolateLocal((
      Pointer<colyseus_schema_t> state,
      double dt,
      double elapsedMs,
      Pointer<Void> _,
    ) {
      final view = views.putIfAbsent(state.address, () => SchemaView(state.address));
      try {
        step(view, dt, elapsedMs);
      } catch (_) {
        // An exception here would unwind through C and abort; a bad step
        // should leave the entity where it was instead.
      }
    });

    _callables.add(callable);
    return callable;
  }

  /// Marshals a Dart config map into the native array of field configs.
  void _withConfig(
    Map<String, Object> config,
    void Function(Pointer<colyseus_attach_field_t> cfg, int count) body,
  ) {
    using((arena) {
      final entries = config.entries.toList();
      final cfg = arena<colyseus_attach_field_t>(entries.length);

      for (var i = 0; i < entries.length; i++) {
        final value = entries[i].value;
        final options = switch (value) {
          PredictMode mode => FieldOptions(mode: mode),
          FieldOptions opts => opts,
          _ => throw ArgumentError(
              'Field "${entries[i].key}" must map to a PredictMode or '
              'FieldOptions, got ${value.runtimeType}'),
        };

        final optsPtr = arena<colyseus_predict_field_options_t>();
        options._write(optsPtr);
        cfg[i].field = entries[i].key.toNativeUtf8(allocator: arena).cast();
        cfg[i].opts = optsPtr;
      }

      body(cfg, entries.length);
    });
  }
}

extension<T extends NativeType> on Pointer<T> {
  /// Applies [body] to this pointer and returns it, for inline struct fills.
  Pointer<T> let(void Function(Pointer<T>) body) {
    body(this);
    return this;
  }
}
