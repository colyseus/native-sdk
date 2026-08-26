import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'colyseus.dart';
import 'input_handle.dart';
import 'payload_registry.dart';
import 'predict.dart';
import 'reconciler.dart';
import 'schema.dart';
import 'schema_view.dart';

/// One entity in a composite simulation.
///
/// Bound parts wrap a decoded instance: the store mirrors it and pulls the
/// mirror back from the server on every reconcile. Opaque parts are the app's
/// own objects — the store never touches them, so [SimOptions.adopt] has to
/// restore them.
class SimPart {
  /// Prefix for this part's pose keys, e.g. `paddle` gives `paddle.x`.
  final String name;

  /// The authoritative instance, or null for an opaque part.
  final SchemaInstance? source;

  /// The app's own object, for an opaque part. Null for a bound one.
  final Object? opaque;

  const SimPart(this.name, this.source) : opaque = null;

  /// A part the store doesn't manage.
  ///
  /// Use it for state that has no decoded instance behind it — an AI the
  /// client simulates, say. The store never touches [object]; reach it from
  /// [SimWorld.opaque] inside the step, and restore it from authority in
  /// [SimOptions.adopt], which is the rollback's only restore point for it.
  const SimPart.opaque(this.name, [Object? object])
      : source = null,
        opaque = object;
}

/// The world handed to a composite step.
///
/// Views are built once per part and reused, so stepping allocates nothing.
class SimWorld {
  final Pointer<colyseus_sim_world> _handle;
  final Map<String, SchemaView> _parts = {};

  SimWorld._(this._handle, this._opaque);

  final Map<String, Object?> _opaque;

  /// The app object behind the opaque part named [name].
  ///
  /// Opaque parts have no schema instance, so they are reached this way
  /// rather than through [part].
  Object? opaque(String name) => _opaque[name];

  /// A mutable view of the part named [name].
  ///
  /// Only bound parts resolve; an opaque part has no schema instance to view,
  /// so use [opaque] for those.
  SchemaView? part(String name) {
    final cached = _parts[name];
    if (cached != null) return cached;

    final ptr = using((arena) => core.colyseus_sim_world_part(
          _handle,
          name.toNativeUtf8(allocator: arena).cast(),
        ));
    if (ptr == nullptr) return null;

    final view = SchemaView(ptr.address);
    _parts[name] = view;
    return view;
  }
}

/// Advances a whole world of parts by one input.
typedef SimStep = void Function(
  StepContext ctx,
  SimWorld world,
  SchemaView command,
);

/// Configuration for [Predict.sim].
class SimOptions {
  /// The entities that make up the simulation.
  final List<SimPart> parts;

  /// Restores opaque parts from authority before each replay.
  ///
  /// Bound parts are pulled from their sources automatically. Required when
  /// no part is bound, since otherwise a rollback has no restore point.
  final void Function(SimWorld world)? adopt;

  /// Error-decay time constant (ms); negative takes the default, 0 snaps hard.
  final double smoothMs;

  /// Correction magnitude past which the result pops instead of decaying.
  final double snap;

  /// Fixed step overrides; 0 adopts the server-advertised rate.
  final double stepMs;
  final int subSteps;

  /// Called after each reconcile with the acknowledged sequence.
  final void Function(int ackedSeq)? onReconcile;

  const SimOptions({
    required this.parts,
    this.adopt,
    this.smoothMs = -1,
    this.snap = 0,
    this.stepMs = 0,
    this.subSteps = 0,
    this.onReconcile,
  });
}

/// Builds a composite reconciler over several entities at once.
///
/// The flat [Reconciler] predicts one entity's fields. When entities interact
/// — a paddle hitting a puck — predicting them separately doesn't work,
/// because rolling one back has to roll back what it collided with. This
/// rewinds and replays the whole world together.
///
/// Bound parts read back through [Predict.value] like any other entity, so
/// rendering doesn't change:
///
/// ```dart
/// final sim = predict.sim(
///   input: input,
///   options: SimOptions(parts: [
///     SimPart('paddle', me),
///     SimPart('puck', puck),
///   ]),
///   step: (ctx, world, cmd) {
///     final paddle = world.part('paddle')!;
///     final puck = world.part('puck')!;
///     stepPaddle(paddle, cmd, ctx.dt);
///     stepPuck(puck, ctx.dt);
///     collide(paddle, puck);
///   },
/// );
///
/// draw(predict.value(puck, 'x'), predict.value(puck, 'y'));
/// ```
Reconciler createSimReconciler({
  required Predict predict,
  required InputHandle input,
  required SimStep step,
  required SimOptions options,
}) {
  final callables = <NativeCallable>[];
  final n = NativeFunctions.instance;

  final ctx = StepContext.detached();
  SimWorld? world;
  SchemaView? commandView;

  // Opaque parts stay on the Dart side; the native store only carries the
  // cookie, and never dereferences it.
  final opaqueByName = <String, Object?>{
    for (final part in options.parts)
      if (part.source == null) part.name: part.opaque,
  };

  // A different world pointer means different mirrors, so the cached part
  // views go with it.
  SimWorld resolveWorld(Pointer<colyseus_sim_world> handle) {
    final existing = world;
    if (existing != null && existing._handle.address == handle.address) {
      return existing;
    }
    return world = SimWorld._(handle, opaqueByName);
  }

  final stepCallable = NativeCallable<
      Void Function(
    Pointer<colyseus_step_ctx_t>,
    Pointer<colyseus_sim_world>,
    Pointer<colyseus_schema_t>,
    Pointer<Void>,
  )>.isolateLocal((
    Pointer<colyseus_step_ctx_t> ctxPtr,
    Pointer<colyseus_sim_world> worldPtr,
    Pointer<colyseus_schema_t> commandPtr,
    Pointer<Void> _,
  ) {
    ctx.rebind(ctxPtr);
    if (commandView?.handle != commandPtr.address) {
      commandView = SchemaView(commandPtr.address);
    }
    try {
      step(ctx, resolveWorld(worldPtr), commandView!);
    } catch (_) {
      // Never unwind into C.
    }
  });
  callables.add(stepCallable);

  NativeCallable<Void Function(Pointer<colyseus_sim_world>, Pointer<Void>)>?
      adoptCallable;
  if (options.adopt != null) {
    adoptCallable = NativeCallable<
        Void Function(Pointer<colyseus_sim_world>,
            Pointer<Void>)>.isolateLocal(
      (Pointer<colyseus_sim_world> worldPtr, Pointer<Void> _) {
        try {
          options.adopt!(resolveWorld(worldPtr));
        } catch (_) {}
      },
    );
    callables.add(adoptCallable);
  }

  NativeCallable<Void Function(Int, Pointer<Void>)>? reconcileCallable;
  if (options.onReconcile != null) {
    reconcileCallable =
        NativeCallable<Void Function(Int, Pointer<Void>)>.isolateLocal(
      (int acked, Pointer<Void> _) {
        try {
          options.onReconcile!(acked);
        } catch (_) {}
      },
    );
    callables.add(reconcileCallable);
  }

  final handle = using((arena) {
    final parts = arena<colyseus_sim_part_t>(options.parts.length);
    for (var i = 0; i < options.parts.length; i++) {
      final part = options.parts[i];
      parts[i].name = part.name.toNativeUtf8(allocator: arena).cast();
      final source = part.source;
      if (source != null) {
        parts[i].source = Pointer<colyseus_schema_t>.fromAddress(source.handle);
        // Reflection schemas carry their vtable on the instance.
        parts[i].vtable = Pointer<colyseus_schema_vtable_t>.fromAddress(
          n.instanceVtable(source.handle),
        );
      } else {
        parts[i].opaque = retainPayload(part.opaque);
      }
    }

    final opts = arena<colyseus_sim_reconciler_options_t>();
    opts.ref.parts = parts;
    opts.ref.part_count = options.parts.length;
    opts.ref.smooth_ms = options.smoothMs;
    opts.ref.snap = options.snap;
    opts.ref.step_ms = options.stepMs;
    opts.ref.sub_steps = options.subSteps;
    opts.ref.manual_step = false;
    if (adoptCallable != null) opts.ref.adopt = adoptCallable.nativeFunction;
    if (reconcileCallable != null) {
      opts.ref.on_reconcile = reconcileCallable.nativeFunction;
    }

    return core.colyseus_predict_sim_reconciler(
      predict.handle,
      input.handle,
      stepCallable.nativeFunction,
      opts,
    );
  });

  if (handle == nullptr) {
    for (final callable in callables) {
      callable.close();
    }
    throw StateError(
      'Could not create a composite reconciler — the fixed step is unknown, '
      'a bound part has no scalar fields, or nothing is bound and no adopt '
      'callback was supplied.',
    );
  }

  return Reconciler.adopt(handle, predict, callables);
}
