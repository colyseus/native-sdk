import 'dart:ffi' show nullptr;

import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Converts a value cell from the O(1) collection_get path into a Dart value.
dynamic _unboxCell(int cell, int childType) {
  if (childType < 0) {
    // Schema child (-2) or unknown: the cell is the instance handle itself.
    return cell != 0 ? SchemaInstance(cell) : null;
  }
  switch (SchemaFieldType.fromValue(childType)) {
    case SchemaFieldType.string:
      return _n.collectionValueString(cell).toDartString();
    case SchemaFieldType.boolean:
      return _n.collectionValueNumber(cell, childType) > 0.5;
    default:
      return _n.collectionValueNumber(cell, childType);
  }
}

/// Reads a field by name, dispatching on its declared type.
///
/// Field names resolve through the native vtable on every call. For the
/// per-frame read paths (prediction, rendering) prefer [SchemaView], which
/// caches the resolution and costs a single leaf FFI call per read.
dynamic _readField(int handle, String fieldName) {
  final namePtr = fieldName.toNativeUtf8();
  try {
    final type = SchemaFieldType.fromValue(
      _n.schemaGetFieldType(handle, namePtr),
    );
    if (type == null) return null;

    switch (type) {
      case SchemaFieldType.string:
        return _n.schemaGetString(handle, namePtr).toDartString();

      case SchemaFieldType.ref:
        final ref = _n.schemaGetNumber(handle, namePtr).toInt();
        return ref != 0 ? SchemaInstance(ref) : null;

      case SchemaFieldType.array:
        final arr = _n.schemaGetNumber(handle, namePtr).toInt();
        return arr != 0 ? SchemaArray(arr) : null;

      case SchemaFieldType.map:
        final map = _n.schemaGetNumber(handle, namePtr).toInt();
        return map != 0 ? SchemaMap(map) : null;

      case SchemaFieldType.boolean:
        return _n.schemaGetNumber(handle, namePtr) > 0.5;

      default:
        return _n.schemaGetNumber(handle, namePtr);
    }
  } finally {
    malloc.free(namePtr);
  }
}

/// Converts a snapshot entry at [ordinal] into a Dart value, using the child
/// kind the native side recorded for the collection being iterated.
dynamic _snapshotEntry(int ordinal) {
  if (_n.collectionHasSchemaChild() == 1) {
    final ref = _n.collectionEntryRef(ordinal);
    return ref != 0 ? SchemaInstance(ref) : null;
  }

  final primitive = SchemaFieldType.fromValue(_n.collectionPrimitiveType());
  switch (primitive) {
    case SchemaFieldType.string:
      return _n.collectionEntryString(ordinal).toDartString();
    case SchemaFieldType.boolean:
      return _n.collectionEntryNumber(ordinal) > 0.5;
    case null:
      final ref = _n.collectionEntryRef(ordinal);
      return ref != 0 ? SchemaInstance(ref) : null;
    default:
      return _n.collectionEntryNumber(ordinal);
  }
}

/// A decoded schema instance.
///
/// Handles are raw native pointers: the decoder may free and replace an
/// instance when the server sends a full resync or the room reconnects. Reach
/// instances afresh from [ColyseusRoom.state] each frame rather than holding
/// one across frames.
///
/// ```dart
/// final players = room.state!.getMap('players')!;
/// final me = players[room.sessionId] as SchemaInstance;
/// print(me['x']);
/// ```
class SchemaInstance {
  final int _handle;

  SchemaInstance(this._handle);

  /// The value of [fieldName], typed by its schema declaration.
  dynamic operator [](String fieldName) => _readField(_handle, fieldName);

  /// The declared type of [fieldName], or null when the field is unknown.
  SchemaFieldType? getFieldType(String fieldName) {
    final namePtr = fieldName.toNativeUtf8();
    try {
      return SchemaFieldType.fromValue(_n.schemaGetFieldType(_handle, namePtr));
    } finally {
      malloc.free(namePtr);
    }
  }

  /// Every field name declared on this instance's schema type.
  List<String> get fieldNames {
    final count = _n.fieldCount(_handle);
    return [
      for (var i = 0; i < count; i++) _n.fieldNameAt(_handle, i).toDartString(),
    ];
  }

  /// The map at [fieldName], or null when absent or not a map.
  SchemaMap? getMap(String fieldName) {
    final value = this[fieldName];
    return value is SchemaMap ? value : null;
  }

  /// The array at [fieldName], or null when absent or not an array.
  SchemaArray? getArray(String fieldName) {
    final value = this[fieldName];
    return value is SchemaArray ? value : null;
  }

  /// The child instance at [fieldName], or null when absent.
  SchemaInstance? getRef(String fieldName) {
    final value = this[fieldName];
    return value is SchemaInstance ? value : null;
  }

  /// The native handle for this schema instance.
  int get handle => _handle;

  @override
  String toString() => 'SchemaInstance(0x${_handle.toRadixString(16)})';
}

/// A decoded `MapSchema`, keyed by string.
///
/// Iteration snapshots the native collection, so [keys], [values] and
/// [entries] each reflect the map as of the call. Values are [SchemaInstance]
/// for schema children and plain Dart values for primitive children.
class SchemaMap {
  final int _handle;
  int? _childType;

  SchemaMap(this._handle);

  /// The native handle.
  int get handle => _handle;

  /// Number of entries.
  int get length => _n.collectionCount(_handle, 1);

  bool get isEmpty => length == 0;
  bool get isNotEmpty => length != 0;

  /// The value stored under [key], or null when absent.
  ///
  /// A direct hash lookup — O(1), no snapshot, no per-entry allocation.
  dynamic operator [](String key) {
    final keyPtr = key.toNativeUtf8();
    try {
      final cell = _n.collectionGet(_handle, 1, keyPtr, 0);
      if (cell == 0) return null;
      return _unboxCell(cell, _childType ??= _n.collectionChildType(_handle, 1));
    } finally {
      malloc.free(keyPtr);
    }
  }

  /// Whether [key] is present.
  bool containsKey(String key) {
    final keyPtr = key.toNativeUtf8();
    try {
      return _n.collectionContains(_handle, keyPtr) == 1;
    } finally {
      malloc.free(keyPtr);
    }
  }

  /// The keys, in native iteration order.
  List<String> get keys {
    final count = _n.collectionSnapshot(_handle, 1);
    return [
      for (var i = 0; i < count; i++)
        _n.collectionEntryKey(i).toDartString(),
    ];
  }

  /// The values, in native iteration order.
  List<dynamic> get values {
    final count = _n.collectionSnapshot(_handle, 1);
    return [for (var i = 0; i < count; i++) _snapshotEntry(i)];
  }

  /// Key/value pairs, in native iteration order.
  List<MapEntry<String, dynamic>> get entries {
    final count = _n.collectionSnapshot(_handle, 1);
    return [
      for (var i = 0; i < count; i++)
        MapEntry(_n.collectionEntryKey(i).toDartString(), _snapshotEntry(i)),
    ];
  }

  /// Calls [action] for every entry.
  void forEach(void Function(String key, dynamic value) action) {
    final count = _n.collectionSnapshot(_handle, 1);
    for (var i = 0; i < count; i++) {
      action(_n.collectionEntryKey(i).toDartString(), _snapshotEntry(i));
    }
  }

  @override
  String toString() => 'SchemaMap(0x${_handle.toRadixString(16)}, $length)';
}

/// A decoded `ArraySchema`, indexed by position.
///
/// The native storage is a linked list in insertion-prepend order, so every
/// read here sorts by the item's decoded index — iteration matches the order
/// the server sees, not the order the list happens to hold.
class SchemaArray {
  final int _handle;
  int? _childType;

  SchemaArray(this._handle);

  /// The native handle.
  int get handle => _handle;

  /// Number of items.
  int get length => _n.collectionCount(_handle, 0);

  bool get isEmpty => length == 0;
  bool get isNotEmpty => length != 0;

  /// The item at [index], or null when out of range.
  dynamic operator [](int index) {
    final cell = _n.collectionGet(_handle, 0, nullptr, index);
    if (cell == 0) return null;
    return _unboxCell(cell, _childType ??= _n.collectionChildType(_handle, 0));
  }

  /// The items, in index order.
  List<dynamic> get values =>
      [for (final entry in _ordered()) _snapshotEntry(entry.ordinal)];

  /// Calls [action] for every item, in index order.
  void forEach(void Function(int index, dynamic value) action) {
    for (final entry in _ordered()) {
      action(entry.index, _snapshotEntry(entry.ordinal));
    }
  }

  /// Snapshot ordinals paired with their decoded indices, index-ascending.
  List<({int ordinal, int index})> _ordered() {
    final count = _n.collectionSnapshot(_handle, 0);
    final entries = [
      for (var i = 0; i < count; i++)
        (ordinal: i, index: _n.collectionEntryIndex(i)),
    ];
    entries.sort((a, b) => a.index.compareTo(b.index));
    return entries;
  }

  @override
  String toString() => 'SchemaArray(0x${_handle.toRadixString(16)}, $length)';
}
