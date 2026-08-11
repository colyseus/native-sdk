import 'dart:ffi';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Wraps a native schema instance pointer for dynamic field access.
///
/// ```dart
/// final state = room.state;
/// print(state['playerName']); // String field
/// print(state['score']);      // Number field
///
/// final players = state.getMap('players');
/// final player = players['abc123'] as SchemaInstance;
/// print(player['x']);
/// ```
class SchemaInstance {
  final int _handle;

  SchemaInstance(this._handle);

  /// Get a field value by name.
  /// Returns the appropriate Dart type based on the field's schema type.
  dynamic operator [](String fieldName) {
    final namePtr = fieldName.toNativeUtf8();
    final fieldType = _n.schemaGetFieldType(_handle, namePtr);
    malloc.free(namePtr);

    final type = SchemaFieldType.fromValue(fieldType);
    if (type == null) return null;

    switch (type) {
      case SchemaFieldType.string:
        final namePtr2 = fieldName.toNativeUtf8();
        final result = _n.schemaGetString(_handle, namePtr2).toDartString();
        malloc.free(namePtr2);
        return result;

      case SchemaFieldType.ref:
        final namePtr2 = fieldName.toNativeUtf8();
        final refHandle = _n.schemaGetNumber(_handle, namePtr2).toInt();
        malloc.free(namePtr2);
        return refHandle != 0 ? SchemaInstance(refHandle) : null;

      case SchemaFieldType.array:
        final namePtr2 = fieldName.toNativeUtf8();
        final arrHandle = _n.schemaGetNumber(_handle, namePtr2).toInt();
        malloc.free(namePtr2);
        return arrHandle != 0 ? SchemaArray(arrHandle) : null;

      case SchemaFieldType.map:
        final namePtr2 = fieldName.toNativeUtf8();
        final mapHandle = _n.schemaGetNumber(_handle, namePtr2).toInt();
        malloc.free(namePtr2);
        return mapHandle != 0 ? SchemaMap(mapHandle) : null;

      default:
        // All numeric/boolean types
        final namePtr2 = fieldName.toNativeUtf8();
        final value = _n.schemaGetNumber(_handle, namePtr2);
        malloc.free(namePtr2);
        if (type == SchemaFieldType.boolean) {
          return value > 0.5;
        }
        return value;
    }
  }

  /// Get the field type for a given field name.
  SchemaFieldType? getFieldType(String fieldName) {
    final namePtr = fieldName.toNativeUtf8();
    final type = _n.schemaGetFieldType(_handle, namePtr);
    malloc.free(namePtr);
    return SchemaFieldType.fromValue(type);
  }

  /// Get a map collection field by name.
  SchemaMap? getMap(String fieldName) {
    final namePtr = fieldName.toNativeUtf8();
    final mapHandle = _n.schemaGetNumber(_handle, namePtr).toInt();
    malloc.free(namePtr);
    return mapHandle != 0 ? SchemaMap(mapHandle) : null;
  }

  /// The native handle for this schema instance.
  int get handle => _handle;

  @override
  String toString() => 'SchemaInstance(0x${_handle.toRadixString(16)})';
}

/// Wraps a native MapSchema for key-based access.
class SchemaMap {
  final int _handle;

  SchemaMap(this._handle);

  /// The native handle.
  int get handle => _handle;

  @override
  String toString() => 'SchemaMap(0x${_handle.toRadixString(16)})';
}

/// Wraps a native ArraySchema for index-based access.
class SchemaArray {
  final int _handle;

  SchemaArray(this._handle);

  /// The native handle.
  int get handle => _handle;

  @override
  String toString() => 'SchemaArray(0x${_handle.toRadixString(16)})';
}
