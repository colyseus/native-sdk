import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'schema.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// A field resolved against a schema vtable, ready for repeated access.
class _Field {
  final int type;
  final int offset;
  final int index;

  const _Field(this.type, this.offset, this.index);
}

/// Fast scalar access to one schema instance.
///
/// [SchemaInstance] looks a field up by name on every read, which is fine for
/// occasional reads but not for a step function running dozens of times per
/// frame during rollback replay. A view resolves each name once and then costs
/// a single leaf FFI call per access.
///
/// Build one per instance and keep it for as long as that instance lives:
///
/// ```dart
/// final view = SchemaView(me.handle);
/// view['x'] = view['x'] + view['vx'] * dt;
/// ```
///
/// Views hold a raw pointer. The decoder frees and replaces instances on a
/// full resync or a reconnect, so re-create views for decoded state when
/// [ColyseusRoom.onReconnect] fires. Views over prediction mirrors and step
/// scratches are stable for the lifetime of their owner.
class SchemaView {
  final int _handle;
  final Map<String, _Field?> _fields = {};

  SchemaView(this._handle);

  /// The native instance pointer.
  int get handle => _handle;

  /// Every field name declared on this instance's type.
  List<String> get fieldNames {
    final count = _n.fieldCount(_handle);
    return [
      for (var i = 0; i < count; i++) _n.fieldNameAt(_handle, i).toDartString(),
    ];
  }

  _Field? _resolve(String name) {
    return _fields.putIfAbsent(name, () {
      final namePtr = name.toNativeUtf8();
      final out = calloc<Int32>(2);
      try {
        final index = _n.fieldResolve(_handle, namePtr, out, out + 1);
        if (index < 0) return null;
        return _Field(out[0], out[1], index);
      } finally {
        calloc.free(out);
        malloc.free(namePtr);
      }
    });
  }

  /// The numeric value of [field]; 0 when the field is unknown.
  ///
  /// Booleans read as 0 or 1 and integers widen to double — the whole
  /// prediction layer treats fields as doubles.
  double operator [](String field) {
    final f = _resolve(field);
    if (f == null) return 0;
    return _n.fieldGetNumber(_handle, f.type, f.offset, f.index);
  }

  /// Writes [value] to [field], narrowed to the field's declared type.
  ///
  /// Writing to decoded server state is pointless — the next patch overwrites
  /// it. Write to mirrors and scratches (a reconciler's `state`, a step's
  /// world parts, an input's `data`).
  void operator []=(String field, num value) {
    final f = _resolve(field);
    if (f == null) return;
    _n.fieldSetNumber(_handle, f.type, f.offset, f.index, value.toDouble());
  }

  /// The boolean value of [field].
  bool getBool(String field) => this[field] != 0;

  /// Writes a boolean to [field].
  void setBool(String field, bool value) => this[field] = value ? 1 : 0;

  /// The string value of [field], or null when the field is absent or unset.
  String? getString(String field) {
    final f = _resolve(field);
    if (f == null || f.type != SchemaFieldType.string.value) return null;
    final value = _n.fieldGetString(_handle, f.offset, f.index).toDartString();
    return value.isEmpty ? null : value;
  }

  /// The declared type of [field], or null when unknown.
  SchemaFieldType? typeOf(String field) {
    final f = _resolve(field);
    return f == null ? null : SchemaFieldType.fromValue(f.type);
  }

  /// Whether [field] exists on this instance's type.
  bool has(String field) => _resolve(field) != null;

  /// A view over the child instance at [field], or null when absent.
  SchemaView? child(String field) {
    final handle = childHandle(field);
    return handle == 0 ? null : SchemaView(handle);
  }

  /// The native handle behind [field], or 0 when absent.
  ///
  /// Works for any pointer-shaped field — ref, map and array alike — which is
  /// what the typed façade layer resolves its children and collections with.
  int childHandle(String field) {
    final f = _resolve(field);
    if (f == null) return 0;
    return _n.fieldGetRef(_handle, f.offset, f.index);
  }

  @override
  String toString() => 'SchemaView(0x${_handle.toRadixString(16)})';
}
