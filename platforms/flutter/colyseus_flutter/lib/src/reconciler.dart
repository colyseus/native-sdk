import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'colyseus.dart';
import 'drift.dart';
import 'input_handle.dart';
import 'events.dart';
import 'interned_names.dart';
import 'payload_registry.dart';
import 'predict.dart';
import 'schema.dart';
import 'schema_view.dart';

/// Matches COLYSEUS_MEMO_VEC_MAX — a #define, so ffigen doesn't emit it.
const _memoVecMax = 4;

/// The per-step context handed to a [ReconcilerStep].
///
/// Reused across steps — read it inside the step, never retain it.
class StepContext {
  Pointer<colyseus_step_ctx_t> _handle;

  StepContext._(this._handle);

  /// An unbound context, rebound per step by whoever drives the callback.
  ///
  /// The composite reconciler builds its own step trampoline, so it needs the
  /// same flyweight the flat path uses.
  StepContext.detached() : _handle = nullptr;

  /// Fixed step in seconds. Always the same value; the simulation is not
  /// frame-rate dependent.
  double get dt => _handle.ref.dt;

  /// Fixed step in milliseconds.
  double get dtMs => _handle.ref.dt_ms;

  /// The sequence number of the input being applied.
  int get tick => _handle.ref.tick;

  /// Physics sub-steps per fixed step; at least 1.
  int get subSteps => _handle.ref.sub_steps;

  /// [dt] divided by [subSteps].
  double get subDt => _handle.ref.sub_dt;

  /// [dtMs] divided by [subSteps].
  double get subDtMs => _handle.ref.sub_dt_ms;

  /// Whether this step is re-simulating an already-applied input.
  ///
  /// Anything that fires once — a sound, a particle, a screen shake — must be
  /// guarded on `!isReplay`, or it repeats every time the server corrects you.
  bool get isReplay => _handle.ref.is_replay;

  /// The server-clock instant this input was stamped at.
  ///
  /// Use it, not the current time, for anything that queries other entities'
  /// positions — it is stable across replays, so the same input always reaches
  /// the same verdict.
  double get reckonTime => _handle.ref.reckon_time;

  /// Whether this input carries a lag-compensation stamp.
  bool get lagCompActive => _handle.ref.lag_comp_active;

  /// Freezes a value that replay could not re-derive.
  ///
  /// [compute] runs exactly once, on the live step, and every replay of the
  /// same input returns the frozen result. Use it for random rolls and for
  /// collision verdicts against moving entities — anything whose inputs are
  /// not themselves part of the reconciled state.
  ///
  /// Return [double.nan] from [compute] to record nothing for this step.
  double memo(String key, double Function() compute) {
    final callable =
        NativeCallable<Double Function(Pointer<Void>)>.isolateLocal(
      (Pointer<Void> _) {
        try {
          return compute();
        } catch (_) {
          return double.nan;
        }
      },
      exceptionalReturn: double.nan,
    );
    try {
      return core.colyseus_step_memo(
        _handle,
        internedName(key),
        callable.nativeFunction,
        nullptr,
      );
    } finally {
      callable.close();
    }
  }

  /// Vector form of [memo]: freezes up to 4 values under one key.
  ///
  /// Cheaper than several [memo] calls when one derivation yields several
  /// numbers — a hit verdict plus the impact point, say — because [compute]
  /// runs once for the whole tuple.
  ///
  /// Returns an empty list when the step recorded nothing.
  List<double> memoVec(String key, List<double> Function() compute) {
    final out = calloc<Double>(_memoVecMax);
    final callable =
        NativeCallable<Int Function(Pointer<Double>, Pointer<Void>)>
            .isolateLocal(
      (Pointer<Double> target, Pointer<Void> _) {
        try {
          final values = compute();
          final count = values.length.clamp(0, _memoVecMax);
          for (var i = 0; i < count; i++) {
            target[i] = values[i];
          }
          return count;
        } catch (_) {
          return 0;
        }
      },
      exceptionalReturn: 0,
    );

    try {
      final count = core.colyseus_step_memo_vec(
        _handle,
        internedName(key),
        callable.nativeFunction,
        nullptr,
        out,
      );
      return [for (var i = 0; i < count; i++) out[i]];
    } finally {
      callable.close();
      calloc.free(out);
    }
  }

  /// Predicts an optimistic event from inside the simulation.
  ///
  /// Fires only on the live step — a rollback replay of the same input is
  /// silently skipped, so the event happens once no matter how many times its
  /// input is re-simulated. That is the difference from
  /// [EventChannel.predict], and the reason to prefer this form for anything
  /// the simulation itself decides.
  ///
  /// Settles by server progress rather than wall clock: if the server
  /// processes past this input without confirming, the prediction is rejected.
  void predict(EventChannel channel, String key, [Object? payload]) {
    core.colyseus_step_predict(
      _handle,
      channel.handle,
      internedName(key),
      retainPayload(payload),
    );
  }

  /// Points this flyweight at the context for the step about to run.
  void rebind(Pointer<colyseus_step_ctx_t> handle) => _handle = handle;
}

/// Applies one input to the predicted state.
///
/// Must be deterministic and must match what the server does for the same
/// input, because it runs both live and again during replay. [state] is the
/// predicted mirror to mutate; [command] is the input being applied.
typedef ReconcilerStep = void Function(
  StepContext ctx,
  SchemaView state,
  SchemaView command,
);

/// Server-reconciled prediction for the entity this client controls.
///
/// Waiting for the server to confirm your own movement costs a full round
/// trip. Instead the reconciler applies each input immediately to a local
/// mirror, and when the server's version of that input arrives it rewinds to
/// the authoritative state and replays whatever is still unacknowledged. When
/// client and server agree, nothing visibly happens; when they disagree, the
/// difference is absorbed as an offset that decays away rather than a jump.
///
/// Read [value] to draw, [state] for game logic:
///
/// ```dart
/// final recon = predict.reconciler(me,
///   input: input,
///   fields: ['x', 'y', 'vx', 'vy'],
///   step: (ctx, state, cmd) => stepEntity(state, cmd, ctx.dt),
/// );
///
/// draw(recon.value('x'), recon.value('y'));
/// ```
class Reconciler {
  final Pointer<colyseus_reconciler> _handle;
  final Predict? _owner;
  final List<NativeCallable> _callables;
  SchemaView? _state;
  bool _disposed = false;

  Reconciler._(this._handle, this._owner, this._callables);

  /// Wraps an already-created native reconciler.
  ///
  /// The composite (`sim`) path builds its handle through a different entry
  /// point but shares this whole surface, so it hands the result here.
  factory Reconciler.adopt(
    Pointer<colyseus_reconciler> handle,
    Predict owner,
    List<NativeCallable> callables,
  ) {
    final reconciler = Reconciler._(handle, owner, callables);
    owner.adoptChild(reconciler);
    return reconciler;
  }

  /// Builds a reconciler driven by [predict].
  ///
  /// Prefer [Predict.reconciler], which calls this.
  static Reconciler create({
    required Predict predict,
    required SchemaInstance truth,
    required InputHandle input,
    required ReconcilerStep step,
    List<String>? fields,
    double smoothing = -1,
    double snap = 0,
    double stepMs = 0,
    int subSteps = 0,
    void Function(int ackedSeq)? onReconcile,
  }) {
    final callables = <NativeCallable>[];

    // Rebound per call rather than reallocated: the core reuses one context
    // and one mirror, so the step path allocates nothing.
    final ctx = StepContext._(nullptr);
    SchemaView? stateView;
    SchemaView? commandView;

    final stepCallable = NativeCallable<
        Void Function(
      Pointer<colyseus_step_ctx_t>,
      Pointer<colyseus_schema_t>,
      Pointer<colyseus_schema_t>,
      Pointer<Void>,
    )>.isolateLocal((
      Pointer<colyseus_step_ctx_t> ctxPtr,
      Pointer<colyseus_schema_t> statePtr,
      Pointer<colyseus_schema_t> commandPtr,
      Pointer<Void> _,
    ) {
      ctx.rebind(ctxPtr);
      if (stateView?.handle != statePtr.address) {
        stateView = SchemaView(statePtr.address);
      }
      if (commandView?.handle != commandPtr.address) {
        commandView = SchemaView(commandPtr.address);
      }
      try {
        step(ctx, stateView!, commandView!);
      } catch (_) {
        // Unwinding through C would abort the process. A step that throws
        // leaves the mirror as it was; the next server ack corrects it.
      }
    });
    callables.add(stepCallable);

    NativeCallable<Void Function(Int, Pointer<Void>)>? reconcileCallable;
    if (onReconcile != null) {
      reconcileCallable =
          NativeCallable<Void Function(Int, Pointer<Void>)>.isolateLocal(
        (int acked, Pointer<Void> _) {
          try {
            onReconcile(acked);
          } catch (_) {}
        },
      );
      callables.add(reconcileCallable);
    }

    final handle = using((arena) {
      final options = arena<colyseus_reconciler_options_t>();
      options.ref.smoothing = smoothing;
      options.ref.snap = snap;
      options.ref.step_ms = stepMs;
      options.ref.sub_steps = subSteps;
      options.ref.manual_step = false;

      if (fields != null && fields.isNotEmpty) {
        final names = arena<Pointer<Char>>(fields.length);
        for (var i = 0; i < fields.length; i++) {
          names[i] = fields[i].toNativeUtf8(allocator: arena).cast();
        }
        options.ref.fields = names;
        options.ref.field_count = fields.length;
      }

      if (reconcileCallable != null) {
        options.ref.on_reconcile = reconcileCallable.nativeFunction;
      }

      return core.colyseus_predict_reconciler(
        predict.handle,
        Pointer<colyseus_schema_t>.fromAddress(truth.handle),
        // Reflection-derived schemas have no statically known vtable; each
        // instance carries its own, and the mirror is built from it.
        Pointer<colyseus_schema_vtable_t>.fromAddress(
          NativeFunctions.instance.instanceVtable(truth.handle),
        ),
        input.handle,
        stepCallable.nativeFunction,
        options,
      );
    });

    if (handle == nullptr) {
      for (final callable in callables) {
        callable.close();
      }
      throw StateError(
        'Could not create a reconciler — the fixed step is unknown '
        '(does the server advertise a tick rate?) or a named field is not on '
        'the schema.',
      );
    }

    return Reconciler.adopt(handle, predict, callables);
  }

  /// The native handle.
  Pointer<colyseus_reconciler> get handle => _handle;

  /// The predicted state, for game logic.
  ///
  /// This is the simulation's own view: exact at step boundaries and free of
  /// the visual smoothing offset. Draw with [value] instead.
  SchemaView get state =>
      _state ??= SchemaView(core.colyseus_reconciler_state(_handle).address);

  /// The value to draw [field] at: predicted state plus the decaying
  /// correction offset.
  double value(String field) =>
      core.colyseus_reconciler_value(_handle, internedName(field));

  /// Inputs applied locally but not yet confirmed by the server.
  ///
  /// Roughly round-trip time divided by tick interval; a good direct readout
  /// of how far ahead the client is running.
  int get pendingCount => core.colyseus_reconciler_pending_count(_handle);

  /// The fixed step in milliseconds.
  double get stepMs => core.colyseus_reconciler_step_ms(_handle);

  /// Increments on every reconcile. Compare across frames to detect one.
  int get reconcileSeq => core.colyseus_reconciler_reconcile_seq(_handle);

  /// Magnitude of the last correction, in world units.
  ///
  /// Near zero means client and server agree. Sustained non-zero means the
  /// step function has diverged from the server's.
  double get lastCorrectionMag =>
      core.colyseus_reconciler_last_correction_mag(_handle);

  /// The last correction applied to [field], signed.
  double lastCorrection(String field) =>
      core.colyseus_reconciler_last_correction(_handle, internedName(field));

  /// Smoothed prediction error over time.
  Drift get drift {
    final d = core.colyseus_reconciler_drift(_handle);
    return d == nullptr ? const Drift(0, 0) : Drift(d.ref.ema, d.ref.peak);
  }

  /// Re-seeds from the authoritative state, dropping offsets and the
  /// in-flight window.
  ///
  /// Call it on reconnect — the server counts sequences from zero again, so
  /// replaying inputs from the previous connection would corrupt the mirror.
  /// Also useful to absorb a teleport instead of smoothing across it.
  void reset() => core.colyseus_reconciler_reset(_handle);

  /// Releases the reconciler.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    core.colyseus_reconciler_free(_handle);
    _owner?.forget(this);

    for (final callable in _callables) {
      callable.close();
    }
    _callables.clear();
  }
}
