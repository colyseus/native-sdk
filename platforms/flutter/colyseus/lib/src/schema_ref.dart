import 'dart:ffi' show nullptr;

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'bindings/native_functions.dart';
import 'schema.dart';
import 'schema_view.dart';

final _n = NativeFunctions.instance;

/// Base class for generated typed schema façades.
///
/// A [SchemaRef] wraps the same native handle a [SchemaInstance] does and adds
/// what `schema-codegen --dart` builds on: a lazily created [SchemaView] for
/// scalar access, and the [mapOf] / [arrayOf] / [refOf] helpers the generated
/// getters call. It *is* a [SchemaInstance], so untyped access (`player['x']`,
/// `state.getMap('players')`) keeps working on typed instances.
///
/// Reach instances through [ColyseusRoom.stateAs] (or a typed collection /
/// ref getter) each time rather than holding one across reconnects — the
/// room's [SchemaCache] hands back the same wrapper while the underlying
/// instance is alive, so re-fetching is cheap.
abstract base class SchemaRef extends SchemaInstance {
  SchemaCache? _cache;
  int _vtable = 0;
  SchemaView? _view;

  SchemaRef(super.handle);

  /// Fast scalar access to this instance, resolved once and cached.
  SchemaView get view => _view ??= SchemaView(handle);

  /// Routes children resolved through this wrapper into [cache]. For
  /// wrappers built outside [SchemaCache.wrap] (the room's own typed root).
  @internal
  void attachCache(SchemaCache cache) => _cache = cache;

  /// The typed map at [field]. Safe before the first decode — an absent
  /// collection just reads as empty.
  @protected
  MapSchema<T> mapOf<T extends SchemaRef>(String field, T Function(int) create) =>
      MapSchema.internal(view.childHandle(field), _wrapper(create), create,
          owner: handle, field: field);

  /// The typed array at [field]. Safe before the first decode.
  @protected
  ArraySchema<T> arrayOf<T extends SchemaRef>(
          String field, T Function(int) create) =>
      ArraySchema.internal(view.childHandle(field), _wrapper(create), create,
          owner: handle, field: field);

  /// The map of primitive values at [field].
  @protected
  MapSchema<T> primitiveMapOf<T>(String field) =>
      MapSchema.internal(view.childHandle(field), null, null,
          owner: handle, field: field);

  /// The array of primitive values at [field].
  @protected
  ArraySchema<T> primitiveArrayOf<T>(String field) =>
      ArraySchema.internal(view.childHandle(field), null, null,
          owner: handle, field: field);

  /// The typed child instance at [field], or null when absent.
  @protected
  T? refOf<T extends SchemaRef>(String field, T Function(int) create) {
    final child = view.childHandle(field);
    if (child == 0) return null;
    return _wrap(child, create, _cache);
  }

  T Function(int) _wrapper<T extends SchemaRef>(T Function(int) create) =>
      (handle) => _wrap(handle, create, _cache);
}

T _wrap<T extends SchemaRef>(int handle, T Function(int) create, SchemaCache? cache) =>
    cache == null ? create(handle) : cache.wrap(handle, create);

/// Wrapper identity for typed schema access.
///
/// Keyed by native handle, so `state.players[id]` returns the same [SchemaRef]
/// (with its warm [SchemaView]) on every frame while the underlying instance
/// is alive. Each [ColyseusRoom] owns one and clears it when the decoder
/// replaces instances wholesale — on reconnect and on dispose.
///
/// The decoder can also free a single instance mid-session (an entity
/// replaced by a patch) and later reuse its address for a new one. A hit is
/// therefore only trusted when the instance's vtable still matches the one
/// recorded at wrap time: same address, same schema type — reads land on
/// whatever live instance owns the address, which is the correct one.
final class SchemaCache {
  final _wrappers = <int, SchemaRef>{};

  /// The cached wrapper for [handle], or a fresh one via [create].
  T wrap<T extends SchemaRef>(int handle, T Function(int) create) {
    final vtable = _n.instanceVtable(handle);
    final hit = _wrappers[handle];
    if (hit is T && hit._vtable == vtable) return hit;

    final wrapper = create(handle)
      .._cache = this
      .._vtable = vtable;
    _wrappers[handle] = wrapper;
    return wrapper;
  }

  /// Drops every wrapper. Cheap — wrappers rebuild on demand.
  void clear() => _wrappers.clear();
}

/// Common surface of [MapSchema] and [ArraySchema]: a typed view over a
/// decoded collection, keyed by [K].
///
/// A wrapper obtained through a generated getter also records which field of
/// which instance it came from. That provenance is what lets
/// [StateCallbacks.onAdd] and [StateCallbacks.onRemove] take the collection
/// itself (`callbacks.onAdd(state.players, ...)`) and still register against
/// the *field* natively — so registration works before the collection first
/// decodes, and survives the server replacing the collection instance.
sealed class SchemaCollection<K, V> {
  final int _handle;
  final V Function(int handle)? _wrapRef;
  final V Function(int handle)? _createDetached;
  final int _ownerHandle;
  final String? _fieldName;

  SchemaCollection._(this._handle, this._wrapRef, this._createDetached,
      this._ownerHandle, this._fieldName);

  /// The native handle (0 when the collection hasn't been decoded yet).
  int get handle => _handle;

  int get length;
  bool get isEmpty => length == 0;
  bool get isNotEmpty => length != 0;

  /// The instance this wrapper was resolved from (0 when built bare).
  @internal
  int get ownerHandle => _ownerHandle;

  /// The field this wrapper was resolved from (null when built bare).
  @internal
  String? get fieldName => _fieldName;

  /// Converts an event key — always a string on the wire — to [K].
  @internal
  K convertKey(String key);

  /// Converts a delivered item (instance or unboxed primitive) to [V].
  @internal
  V wrapItem(dynamic value) {
    final wrapRef = _wrapRef;
    if (wrapRef != null && value is SchemaInstance) return wrapRef(value.handle);
    return value as V;
  }

  /// [wrapItem], but bypassing the schema cache. For removal events: the
  /// decoder has already freed the instance by delivery time, so the cache
  /// must neither probe nor retain its handle.
  @internal
  V wrapItemDetached(dynamic value) {
    final create = _createDetached;
    if (create != null && value is SchemaInstance) return create(value.handle);
    return value as V;
  }
}

/// A typed view over a decoded `MapSchema`.
///
/// [T] is a generated [SchemaRef] subtype for schema children, or a Dart
/// primitive (`double`, `String`, `bool`) for primitive children. Lookups are
/// O(1) native hash gets; iteration snapshots the collection like [SchemaMap].
final class MapSchema<T> extends SchemaCollection<String, T> {
  @internal
  MapSchema.internal(int handle, T Function(int)? wrapRef,
      T Function(int)? createDetached, {int owner = 0, String? field})
      : super._(handle, wrapRef, createDetached, owner, field);

  SchemaMap get _untyped => SchemaMap(_handle);

  @override
  int get length => _handle == 0 ? 0 : _n.collectionCount(_handle, 1);

  @override
  String convertKey(String key) => key;

  /// The value stored under [key], or null when absent.
  T? operator [](String key) {
    if (_handle == 0) return null;
    final wrapRef = _wrapRef;
    if (wrapRef != null) {
      final keyPtr = key.toNativeUtf8();
      try {
        final cell = _n.collectionGet(_handle, 1, keyPtr, 0);
        return cell == 0 ? null : wrapRef(cell);
      } finally {
        malloc.free(keyPtr);
      }
    }
    return _untyped[key] as T?;
  }

  bool containsKey(String key) => _handle != 0 && _untyped.containsKey(key);

  List<String> get keys => _handle == 0 ? const [] : _untyped.keys;

  List<T> get values =>
      _handle == 0 ? [] : [for (final v in _untyped.values) wrapItem(v)];

  List<MapEntry<String, T>> get entries => _handle == 0
      ? []
      : [
          for (final e in _untyped.entries)
            MapEntry(e.key, wrapItem(e.value)),
        ];

  void forEach(void Function(String key, T value) action) {
    if (_handle == 0) return;
    _untyped.forEach((key, value) => action(key, wrapItem(value)));
  }

  @override
  String toString() => 'MapSchema<$T>(0x${_handle.toRadixString(16)}, $length)';
}

/// A typed view over a decoded `ArraySchema`; see [MapSchema] for the rules.
final class ArraySchema<T> extends SchemaCollection<int, T> {
  @internal
  ArraySchema.internal(int handle, T Function(int)? wrapRef,
      T Function(int)? createDetached, {int owner = 0, String? field})
      : super._(handle, wrapRef, createDetached, owner, field);

  SchemaArray get _untyped => SchemaArray(_handle);

  @override
  int get length => _handle == 0 ? 0 : _n.collectionCount(_handle, 0);

  @override
  int convertKey(String key) => int.parse(key);

  /// The item at [index], or null when out of range.
  T? operator [](int index) {
    if (_handle == 0) return null;
    final wrapRef = _wrapRef;
    if (wrapRef != null) {
      final cell = _n.collectionGet(_handle, 0, nullptr, index);
      return cell == 0 ? null : wrapRef(cell);
    }
    return _untyped[index] as T?;
  }

  /// The items, in index order.
  List<T> get values =>
      _handle == 0 ? [] : [for (final v in _untyped.values) wrapItem(v)];

  void forEach(void Function(int index, T value) action) {
    if (_handle == 0) return;
    _untyped.forEach((index, value) => action(index, wrapItem(value)));
  }

  @override
  String toString() =>
      'ArraySchema<$T>(0x${_handle.toRadixString(16)}, $length)';
}
