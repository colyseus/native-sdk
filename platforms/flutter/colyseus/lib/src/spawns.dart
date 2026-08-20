import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'colyseus.dart';
import 'interned_names.dart';
import 'payload_registry.dart';
import 'schema.dart';

/// One predicted or confirmed entity in a [Spawns] store.
///
/// A spawn starts as a local prediction and becomes server-backed when the
/// authoritative entity arrives; [id] survives that handoff, so sprites and
/// effects keyed on it never blink.
class SpawnEntry {
  /// Stable across the handoff from predicted to confirmed.
  final int id;

  /// The authoritative instance, or null while still predicted.
  final SchemaInstance? server;

  /// The local object passed to [Spawns.spawn], or null for entities spawned
  /// by someone else.
  final Object? local;

  /// Whether the server has acknowledged this entity.
  final bool confirmed;

  /// Measured uplink lead in milliseconds for this client's own spawns.
  ///
  /// How far ahead of the server this entity was created. The store uses it
  /// so a confirmed projectile keeps flying on the shooter's timeline instead
  /// of snapping backwards at the handoff.
  final double leadMs;

  const SpawnEntry({
    required this.id,
    required this.server,
    required this.local,
    required this.confirmed,
    required this.leadMs,
  });

  @override
  String toString() =>
      'SpawnEntry(id: $id, confirmed: $confirmed, lead: ${leadMs.round()}ms)';
}

/// Configuration for a [Spawns] store.
class SpawnsOptions {
  /// Whether an incoming server entity is one this client predicted.
  ///
  /// Return false for other players' entities so they are never matched to a
  /// local prediction. Null treats every entity as correlatable.
  final bool Function(SchemaInstance server)? owned;

  /// Pairs a pending local with an arriving server entity.
  ///
  /// Null pairs oldest-first, which is right when a client can only have one
  /// spawn in flight at a time.
  final bool Function(Object? local, SchemaInstance server)? correlate;

  /// The server-clock instant an entity was created, read off the entity.
  ///
  /// Supplying it enables [SpawnEntry.leadMs] and the seamless handoff.
  final double Function(SchemaInstance server)? spawnTime;

  /// Advances a still-predicted local by [dt] seconds.
  final void Function(Object? local, double dt)? step;

  /// Reads a named field off a predicted local, so [Spawns.value] works on
  /// both sides of the handoff and the app has one render path.
  final double Function(Object? local, String field)? localRead;

  /// How long an unmatched prediction survives, in milliseconds.
  /// 0 uses max(2×rtt, 600).
  final double ttlMs;

  /// Called when a prediction is evicted without ever being confirmed.
  final void Function(Object? local, int id)? onReject;

  /// Fields to dead-reckon on confirmed entities. Requires [reckonStep].
  final List<String>? fields;

  /// Advances a confirmed entity's scratch copy, shared with the server.
  final void Function(dynamic state, double dt, double elapsedMs)? reckonStep;

  const SpawnsOptions({
    this.owned,
    this.correlate,
    this.spawnTime,
    this.step,
    this.localRead,
    this.ttlMs = 0,
    this.onReject,
    this.fields,
    this.reckonStep,
  });
}

/// Optimistically spawned entities, reconciled with the server.
///
/// Firing a projectile shouldn't wait a round trip, but the projectile the
/// server creates is a different object from the one drawn locally. This store
/// holds the local prediction, matches it to the authoritative entity when it
/// arrives, and collapses them onto one entry with a stable id — so there is
/// no visible pop at the handoff.
///
/// ```dart
/// final projectiles = predict.spawns('projectiles', SpawnsOptions(
///   owned: (server) => server['owner'] == room.sessionId,
///   spawnTime: (server) => server['bornMs'] as double,
///   step: (local, dt) => stepProjectile(local as Bullet, dt),
///   localRead: (local, field) => (local as Bullet).read(field),
/// ));
///
/// projectiles.spawn(Bullet(x, y, vx, vy));
///
/// for (final e in projectiles.entries) {
///   draw(projectiles.value(e, 'x'), projectiles.value(e, 'y'));
/// }
/// ```
class Spawns {
  final Pointer<colyseus_spawns> _handle;
  final List<NativeCallable> _callables;
  bool _disposed = false;

  Spawns._(this._handle, this._callables);

  /// Builds a store. Prefer [Predict.spawns], which also wires the collection.
  static Spawns create({
    required Pointer<colyseus_room_clock> clock,
    required SpawnsOptions options,
  }) {
    final callables = <NativeCallable>[];

    NativeCallable<Bool Function(Pointer<colyseus_schema_t>, Pointer<Void>)>?
        ownedCb;
    if (options.owned != null) {
      ownedCb = NativeCallable<
          Bool Function(Pointer<colyseus_schema_t>,
              Pointer<Void>)>.isolateLocal(
        (Pointer<colyseus_schema_t> server, Pointer<Void> _) {
          try {
            return options.owned!(SchemaInstance(server.address));
          } catch (_) {
            return false;
          }
        },
        exceptionalReturn: false,
      );
      callables.add(ownedCb);
    }

    NativeCallable<
        Bool Function(Pointer<Void>, Pointer<colyseus_schema_t>,
            Pointer<Void>)>? correlateCb;
    if (options.correlate != null) {
      correlateCb = NativeCallable<
          Bool Function(Pointer<Void>, Pointer<colyseus_schema_t>,
              Pointer<Void>)>.isolateLocal(
        (Pointer<Void> local, Pointer<colyseus_schema_t> server,
            Pointer<Void> _) {
          try {
            return options.correlate!(
              payloadFor(local),
              SchemaInstance(server.address),
            );
          } catch (_) {
            return false;
          }
        },
        exceptionalReturn: false,
      );
      callables.add(correlateCb);
    }

    NativeCallable<Double Function(Pointer<colyseus_schema_t>, Pointer<Void>)>?
        spawnTimeCb;
    if (options.spawnTime != null) {
      spawnTimeCb = NativeCallable<
          Double Function(Pointer<colyseus_schema_t>,
              Pointer<Void>)>.isolateLocal(
        (Pointer<colyseus_schema_t> server, Pointer<Void> _) {
          try {
            return options.spawnTime!(SchemaInstance(server.address));
          } catch (_) {
            return 0.0;
          }
        },
        exceptionalReturn: 0.0,
      );
      callables.add(spawnTimeCb);
    }

    NativeCallable<Void Function(Pointer<Void>, Double, Pointer<Void>)>? stepCb;
    if (options.step != null) {
      stepCb = NativeCallable<
          Void Function(Pointer<Void>, Double, Pointer<Void>)>.isolateLocal(
        (Pointer<Void> local, double dt, Pointer<Void> _) {
          try {
            options.step!(payloadFor(local), dt);
          } catch (_) {}
        },
      );
      callables.add(stepCb);
    }

    NativeCallable<
        Double Function(Pointer<Void>, Pointer<Char>, Pointer<Void>)>?
        localReadCb;
    if (options.localRead != null) {
      localReadCb = NativeCallable<
          Double Function(Pointer<Void>, Pointer<Char>,
              Pointer<Void>)>.isolateLocal(
        (Pointer<Void> local, Pointer<Char> field, Pointer<Void> _) {
          try {
            return options.localRead!(
              payloadFor(local),
              field == nullptr ? '' : field.cast<Utf8>().toDartString(),
            );
          } catch (_) {
            return double.nan;
          }
        },
        exceptionalReturn: double.nan,
      );
      callables.add(localReadCb);
    }

    NativeCallable<Void Function(Pointer<Void>, Int, Pointer<Void>)>? rejectCb;
    if (options.onReject != null) {
      rejectCb = NativeCallable<
          Void Function(Pointer<Void>, Int, Pointer<Void>)>.isolateLocal(
        (Pointer<Void> local, int id, Pointer<Void> _) {
          try {
            options.onReject!(payloadFor(local), id);
          } catch (_) {}
        },
      );
      callables.add(rejectCb);
    }

    // Runs when an entry holding a local dies — the one place its registry
    // slot is released.
    final freeCb = NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
      (Pointer<Void> local) => releasePayload(local),
    );
    callables.add(freeCb);

    final handle = using((arena) {
      final opts = arena<colyseus_spawns_options_t>();
      if (ownedCb != null) opts.ref.owned = ownedCb.nativeFunction;
      if (correlateCb != null) opts.ref.correlate = correlateCb.nativeFunction;
      if (spawnTimeCb != null) {
        opts.ref.spawn_time = spawnTimeCb.nativeFunction;
        opts.ref.has_spawn_time = true;
      }
      if (stepCb != null) opts.ref.step = stepCb.nativeFunction;
      if (localReadCb != null) opts.ref.local_read = localReadCb.nativeFunction;
      if (rejectCb != null) opts.ref.on_reject = rejectCb.nativeFunction;
      opts.ref.local_free = freeCb.nativeFunction;
      opts.ref.ttl_ms = options.ttlMs;
      return core.colyseus_spawns_create(opts, clock);
    });

    if (handle == nullptr) {
      for (final callable in callables) {
        callable.close();
      }
      throw StateError('Could not create a spawn store');
    }

    return Spawns._(handle, callables);
  }

  /// The native handle.
  Pointer<colyseus_spawns> get handle => _handle;

  /// Records an optimistic spawn and returns its stable id.
  int spawn(Object? local) =>
      core.colyseus_spawns_spawn(_handle, retainPayload(local));

  /// Drops a still-pending prediction. No-op once confirmed.
  void cancel(int id) => core.colyseus_spawns_cancel(_handle, id);

  /// Exempts a pending entry from expiry — the server said yes and its patch
  /// is still in flight.
  void accept(int id) => core.colyseus_spawns_accept(_handle, id);

  /// Every entry, predicted and confirmed, in creation order.
  Iterable<SpawnEntry> get entries sync* {
    var cursor = core.colyseus_spawns_first(_handle);
    while (cursor != nullptr) {
      yield SpawnEntry(
        id: cursor.ref.id,
        server: cursor.ref.server == nullptr
            ? null
            : SchemaInstance(cursor.ref.server.address),
        local: payloadFor(cursor.ref.local),
        confirmed: cursor.ref.confirmed,
        leadMs: cursor.ref.lead_ms,
      );
      cursor = core.colyseus_spawns_next(_handle, cursor);
    }
  }

  /// The render value of [field] for [entry], on either side of the handoff.
  ///
  /// Reads the local prediction while pending and the authoritative entity
  /// once confirmed, so drawing code doesn't branch. Pending entries need
  /// [SpawnsOptions.localRead], or this returns NaN.
  double value(SpawnEntry entry, String field) {
    final cursor = _cursorFor(entry.id);
    if (cursor == nullptr) return double.nan;
    return core.colyseus_spawns_value(_handle, cursor, internedName(field));
  }

  /// How many entries the store holds.
  int get size => core.colyseus_spawns_size(_handle);

  /// Whether [id] is still alive.
  bool alive(int id) => core.colyseus_spawns_alive(_handle, id);

  /// Drops every entry.
  void clear() => core.colyseus_spawns_clear(_handle);

  /// Releases the store.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    core.colyseus_spawns_free(_handle);
    for (final callable in _callables) {
      callable.close();
    }
    _callables.clear();
  }

  /// The native cursor for [id], since [SpawnEntry] is a Dart-side snapshot.
  Pointer<colyseus_spawn_entry_t> _cursorFor(int id) {
    var cursor = core.colyseus_spawns_first(_handle);
    while (cursor != nullptr) {
      if (cursor.ref.id == id) return cursor;
      cursor = core.colyseus_spawns_next(_handle, cursor);
    }
    return nullptr;
  }
}
