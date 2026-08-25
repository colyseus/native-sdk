import 'dart:async';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'bindings/native_functions.dart';
import 'room.dart';
import 'schema.dart';
import 'schema_ref.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Entry point to schema-state callbacks, mirroring the C# SDK's
/// `Callbacks.Get(room)`.
///
/// ```dart
/// final callbacks = Callbacks.get(room);
/// final state = room.stateAs(MyRoomState.new)!;
///
/// callbacks.onAdd(state.players, (sessionId, player) { ... });
/// callbacks.listen(state, 'currentTurn', (value, previous) { ... });
/// ```
abstract final class Callbacks {
  /// The [StateCallbacks] for [room]; every call returns the same object.
  static StateCallbacks get(ColyseusRoom room) => room.stateCallbacks;
}

/// Registers schema-state callbacks against one room's decoder.
///
/// The typed methods mirror the C# SDK's expression-based ones. Where C#
/// names the field with a lambda (`OnAdd(s => s.players, ...)`), Dart passes
/// the generated getter's value (`onAdd(state.players, ...)`): the wrapper a
/// generated getter returns knows which field of which instance it came from,
/// so the registration binds to the field — it works before the collection
/// first decodes and survives the server replacing it.
///
/// [onAddByName] / [onRemoveByName] and [listen] with an untyped handler are
/// the string-based variants, usable with no generated classes.
///
/// Obtain one with [Callbacks.get]. Every registration returns a
/// [StreamSubscription]; cancelling it unregisters the native callback.
/// [ColyseusRoom.dispose] disposes this object with the room.
class StateCallbacks {
  final ColyseusRoom _room;
  int _native = 0;
  bool _disposed = false;

  final Map<int, StreamController<dynamic>> _propertyChange = {};
  final Map<int, StreamController<dynamic>> _itemAdd = {};
  final Map<int, StreamController<dynamic>> _itemRemove = {};
  final Map<int, StreamController<void>> _instanceChange = {};

  @internal
  StateCallbacks.internal(this._room);

  /// One native callbacks manager per room, created on first subscription.
  ///
  /// The manager wraps the room's decoder, so it can only be built once the
  /// serializer exists — i.e. after the join handshake.
  int get _callbacks {
    if (_native == 0) {
      _native = _n.callbacksCreate(_room.roomRef);
      if (_native == 0) {
        throw StateError(
          'Failed to create callbacks manager — is the room joined yet?',
        );
      }
    }
    return _native;
  }

  // ===== Typed registration =====

  /// Fires for every item added to [collection], as `(key, value)` — the
  /// key is a `String` for maps and an `int` index for arrays.
  ///
  /// With [immediate] (the default), items already decoded replay on
  /// registration.
  ///
  /// [collection] must come from a generated getter (or another
  /// [SchemaRef]-based accessor), which records the field it belongs to.
  StreamSubscription<dynamic> onAdd<K, V>(
    SchemaCollection<K, V> collection,
    void Function(K key, V value) callback, {
    bool immediate = true,
  }) {
    final (owner, field) = _provenance(collection, 'onAdd');
    final handle = _registerOnAdd(owner, field, immediate);
    return _bridge(handle, field, _itemAdd, (event) {
      if (event is Map) {
        callback(collection.convertKey(event['key'] as String),
            collection.wrapItem(event['value']));
      }
    });
  }

  /// Fires for every item removed from [collection], as `(key, value)`.
  StreamSubscription<dynamic> onRemove<K, V>(
    SchemaCollection<K, V> collection,
    void Function(K key, V value) callback,
  ) {
    final (owner, field) = _provenance(collection, 'onRemove');
    final handle = _registerOnRemove(owner, field);
    return _bridge(handle, field, _itemRemove, (event) {
      if (event is Map) {
        // Detached wrap: the decoder has already freed a removed instance by
        // the time this delivers, so the cache must not see its handle.
        callback(collection.convertKey(event['key'] as String),
            collection.wrapItemDetached(event['value']));
      }
    });
  }

  /// Listen to changes of [property] on [instance], as
  /// `(value, previousValue)`.
  ///
  /// [V] types the handler (`callbacks.listen(player, 'hp',
  /// (double hp, double? prev) { ... })`); leave the parameters untyped for
  /// the dynamic string-based form. With [immediate] (the default), the
  /// current value replays on registration.
  StreamSubscription<dynamic> listen<V>(
    SchemaInstance instance,
    String property,
    void Function(V value, V? previous) callback, {
    bool immediate = true,
  }) {
    final handle = _registerListen(instance.handle, property, immediate);
    return _bridge(handle, property, _propertyChange, (event) {
      if (event is Map) {
        callback(event['value'] as V, event['previousValue'] as V?);
      }
    });
  }

  /// Listen to the child-instance [property] on [instance], delivered
  /// through [create] (null when the server clears the field).
  StreamSubscription<dynamic> listenRef<R extends SchemaRef>(
    SchemaInstance instance,
    String property,
    R Function(int handle) create,
    void Function(R? value) callback, {
    bool immediate = true,
  }) {
    final handle = _registerListen(instance.handle, property, immediate);
    return _bridge(handle, property, _propertyChange, (event) {
      if (event is Map) {
        final value = event['value'];
        callback(value is SchemaInstance
            ? _room.schemaCache.wrap(value.handle, create)
            : null);
      }
    });
  }

  /// Fires after any property of [instance] changes.
  StreamSubscription<void> onChange(
    SchemaInstance instance,
    void Function() callback,
  ) {
    final handle = _n.callbacksOnChange(_callbacks, instance.handle);
    return _bridge(handle, 'onChange', _instanceChange, (_) => callback());
  }

  // ===== String-based registration =====

  /// [onAdd] by field name, with no generated classes: fires as
  /// `(key, value)` with the key as a string (arrays: the index in string
  /// form) and the value as a [SchemaInstance] or unboxed primitive.
  StreamSubscription<dynamic> onAddByName(
    SchemaInstance instance,
    String property,
    void Function(String key, dynamic value) callback, {
    bool immediate = true,
  }) {
    final handle = _registerOnAdd(instance.handle, property, immediate);
    return _bridge(handle, property, _itemAdd, (event) {
      if (event is Map) callback(event['key'] as String, event['value']);
    });
  }

  /// [onRemove] by field name; see [onAddByName] for the handler's shape.
  StreamSubscription<dynamic> onRemoveByName(
    SchemaInstance instance,
    String property,
    void Function(String key, dynamic value) callback,
  ) {
    final handle = _registerOnRemove(instance.handle, property);
    return _bridge(handle, property, _itemRemove, (event) {
      if (event is Map) callback(event['key'] as String, event['value']);
    });
  }

  // ===== Internals =====

  /// The (instance, field) pair a collection wrapper was resolved from.
  (int, String) _provenance(SchemaCollection collection, String what) {
    final owner = collection.ownerHandle;
    final field = collection.fieldName;
    if (owner == 0 || field == null) {
      throw ArgumentError(
        '$what needs a collection obtained from a schema getter '
        '(e.g. state.players), so it knows which field to observe',
      );
    }
    return (owner, field);
  }

  int _registerListen(int instanceHandle, String property, bool immediate) {
    final propPtr = property.toNativeUtf8();
    try {
      return _n.callbacksListen(
          _callbacks, instanceHandle, propPtr, immediate ? 1 : 0);
    } finally {
      malloc.free(propPtr);
    }
  }

  int _registerOnAdd(int instanceHandle, String property, bool immediate) {
    final propPtr = property.toNativeUtf8();
    try {
      return _n.callbacksOnAdd(
          _callbacks, instanceHandle, propPtr, immediate ? 1 : 0);
    } finally {
      malloc.free(propPtr);
    }
  }

  int _registerOnRemove(int instanceHandle, String property) {
    final propPtr = property.toNativeUtf8();
    try {
      return _n.callbacksOnRemove(_callbacks, instanceHandle, propPtr);
    } finally {
      malloc.free(propPtr);
    }
  }

  /// Bridges a registered native callback to a Dart stream subscription whose
  /// cancellation unregisters it.
  StreamSubscription<E> _bridge<E>(
    int handle,
    String what,
    Map<int, StreamController<E>> controllers,
    void Function(E event) deliver,
  ) {
    if (handle < 0) {
      throw StateError('Failed to register "$what" callback');
    }

    final controller = StreamController<E>.broadcast(
      onCancel: () {
        // On dispose the whole native manager goes away; removing individual
        // handles from it then would touch freed memory.
        if (!_disposed && _native != 0) {
          _n.callbacksRemoveHandle(_native, handle);
        }
        controllers.remove(handle)?.close();
      },
    );
    controllers[handle] = controller;

    return controller.stream.listen(deliver);
  }

  /// Closes every subscription and frees the native manager.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final controllers in [_propertyChange, _itemAdd, _itemRemove]) {
      for (final c in controllers.values.toList()) {
        c.close();
      }
      controllers.clear();
    }
    for (final c in _instanceChange.values.toList()) {
      c.close();
    }
    _instanceChange.clear();

    if (_native != 0) {
      _n.callbacksFree(_native);
      _native = 0;
    }
  }

  // ===== Dispatch entry points (called via ColyseusRoom by the poller) =====

  @internal
  void dispatchPropertyChange(
    int callbackHandle,
    int valueType,
    double valueNumber,
    String valueString,
    double prevValueNumber,
    String prevValueString,
    int instanceHandle,
  ) {
    final controller = _propertyChange[callbackHandle];
    if (controller == null) return;

    final type = SchemaFieldType.fromValue(valueType);
    dynamic value;
    dynamic previousValue;

    if (type == SchemaFieldType.string) {
      value = valueString;
      previousValue = prevValueString;
    } else if (type == SchemaFieldType.ref) {
      value = instanceHandle != 0 ? SchemaInstance(instanceHandle) : null;
      previousValue = null;
    } else if (type == SchemaFieldType.boolean) {
      value = valueNumber > 0.5;
      previousValue = prevValueNumber > 0.5;
    } else {
      value = valueNumber;
      previousValue = prevValueNumber;
    }

    controller.add({'value': value, 'previousValue': previousValue});
  }

  /// Collection items arrive either as instance handles (schema children) or
  /// as values already unboxed by the native trampoline (primitive children,
  /// flagged by the event carrying the child's own field type).
  dynamic _itemValue(
    int valueType,
    int instanceHandle,
    double valueNumber,
    String valueString,
  ) {
    switch (SchemaFieldType.fromValue(valueType)) {
      case SchemaFieldType.ref:
      case SchemaFieldType.array:
      case SchemaFieldType.map:
        return instanceHandle != 0 ? SchemaInstance(instanceHandle) : null;
      case SchemaFieldType.string:
        return valueString;
      case SchemaFieldType.boolean:
        return valueNumber > 0.5;
      case null:
        return null;
      default:
        return valueNumber;
    }
  }

  @internal
  void dispatchItemAdd(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
    double valueNumber,
    String valueString,
  ) {
    _itemAdd[callbackHandle]?.add({
      'value': _itemValue(valueType, instanceHandle, valueNumber, valueString),
      'key': key,
    });
  }

  @internal
  void dispatchItemRemove(
    int callbackHandle,
    String key,
    int instanceHandle,
    int valueType,
    double valueNumber,
    String valueString,
  ) {
    _itemRemove[callbackHandle]?.add({
      'value': _itemValue(valueType, instanceHandle, valueNumber, valueString),
      'key': key,
    });
  }

  @internal
  void dispatchInstanceChange(int callbackHandle) {
    _instanceChange[callbackHandle]?.add(null);
  }
}
