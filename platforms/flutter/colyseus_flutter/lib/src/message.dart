import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'types.dart';

final _n = NativeFunctions.instance;

/// Builds a native message handle from a Dart object.
/// Returns the intptr_t handle to be passed to room_send_message.
int buildMessage(Object? data) {
  if (data == null) {
    return _n.messageCreateNil();
  } else if (data is Map) {
    return _buildMap(data);
  } else if (data is List) {
    return _buildArray(data);
  } else if (data is String) {
    final ptr = data.toNativeUtf8();
    final handle = _n.messageCreateString(ptr);
    malloc.free(ptr);
    return handle;
  } else if (data is int) {
    return _n.messageCreateInt(data);
  } else if (data is double) {
    return _n.messageCreateFloat(data);
  } else if (data is bool) {
    return _n.messageCreateBool(data ? 1 : 0);
  }
  // Fallback: convert to string
  final ptr = data.toString().toNativeUtf8();
  final handle = _n.messageCreateString(ptr);
  malloc.free(ptr);
  return handle;
}

int _buildMap(Map data) {
  final handle = _n.messageCreateMap();
  data.forEach((key, value) {
    final keyStr = key.toString();
    final keyPtr = keyStr.toNativeUtf8();

    if (value == null) {
      _n.messageMapPutNil(handle, keyPtr);
    } else if (value is String) {
      final valPtr = value.toNativeUtf8();
      _n.messageMapPutStr(handle, keyPtr, valPtr);
      malloc.free(valPtr);
    } else if (value is int) {
      _n.messageMapPutInt(handle, keyPtr, value);
    } else if (value is double) {
      _n.messageMapPutFloat(handle, keyPtr, value);
    } else if (value is bool) {
      _n.messageMapPutBool(handle, keyPtr, value ? 1 : 0);
    } else if (value is Map || value is List) {
      final nested = buildMessage(value);
      _n.messageMapPut(handle, keyPtr, nested);
    } else {
      final valPtr = value.toString().toNativeUtf8();
      _n.messageMapPutStr(handle, keyPtr, valPtr);
      malloc.free(valPtr);
    }

    malloc.free(keyPtr);
  });
  return handle;
}

int _buildArray(List data) {
  final handle = _n.messageCreateArray();
  for (final value in data) {
    if (value == null) {
      _n.messageArrayPushNil(handle);
    } else if (value is String) {
      final ptr = value.toNativeUtf8();
      _n.messageArrayPushStr(handle, ptr);
      malloc.free(ptr);
    } else if (value is int) {
      _n.messageArrayPushInt(handle, value);
    } else if (value is double) {
      _n.messageArrayPushFloat(handle, value);
    } else if (value is bool) {
      _n.messageArrayPushBool(handle, value ? 1 : 0);
    } else if (value is Map || value is List) {
      final nested = buildMessage(value);
      _n.messageArrayPush(handle, nested);
    } else {
      final ptr = value.toString().toNativeUtf8();
      _n.messageArrayPushStr(handle, ptr);
      malloc.free(ptr);
    }
  }
  return handle;
}

/// Reads the current polled message event into a Dart object.
/// Must be called while the event is still active (before next poll).
Object? readCurrentMessage() {
  final type = MessageValueType.fromValue(_n.messageGetType());

  switch (type) {
    case MessageValueType.nil:
      return null;
    case MessageValueType.string:
      return _n.messageReadStringValue().toDartString();
    case MessageValueType.integer:
    case MessageValueType.unsignedInteger:
    case MessageValueType.float:
      return _n.messageReadNumberValue();
    case MessageValueType.boolean:
      return _n.messageReadNumberValue() > 0.5;
    case MessageValueType.map:
      return _readMap();
    case MessageValueType.array:
      return _readArray();
    case MessageValueType.binary:
      final dataPtr = _n.eventGetData();
      final dataLen = _n.eventGetDataLength();
      if (dataLen > 0) {
        return Uint8List.fromList(dataPtr.asTypedList(dataLen));
      }
      return Uint8List(0);
  }
}

Map<String, dynamic> _readMap() {
  final result = <String, dynamic>{};
  _n.messageIterBegin();
  while (_n.messageIterNext() != 0) {
    final key = _n.messageIterKey().toDartString();
    final valueType = MessageValueType.fromValue(_n.messageIterValueType());
    switch (valueType) {
      case MessageValueType.string:
        result[key] = _n.messageIterValueString().toDartString();
        break;
      case MessageValueType.integer:
      case MessageValueType.unsignedInteger:
      case MessageValueType.float:
        result[key] = _n.messageIterValueNumber();
        break;
      case MessageValueType.boolean:
        result[key] = _n.messageIterValueNumber() > 0.5;
        break;
      case MessageValueType.nil:
        result[key] = null;
        break;
      default:
        // Nested maps/arrays not yet iterable through this simple API;
        // store null for now (can be extended with sub-reader support).
        result[key] = null;
        break;
    }
  }
  return result;
}

List<dynamic> _readArray() {
  final size = _n.messageArraySize();
  final result = <dynamic>[];
  for (int i = 0; i < size; i++) {
    final elemType = MessageValueType.fromValue(_n.messageArrayElementType(i));
    switch (elemType) {
      case MessageValueType.string:
        result.add(_n.messageArrayElementString(i).toDartString());
        break;
      case MessageValueType.integer:
      case MessageValueType.unsignedInteger:
      case MessageValueType.float:
        result.add(_n.messageArrayElementNumber(i));
        break;
      case MessageValueType.boolean:
        result.add(_n.messageArrayElementNumber(i) > 0.5);
        break;
      case MessageValueType.nil:
        result.add(null);
        break;
      default:
        result.add(null);
        break;
    }
  }
  return result;
}
