import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';
import 'msgpack.dart';

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
///
/// Decoding happens in Dart over the event's raw payload, so nested maps and
/// arrays come through intact. Must be called while the event is still active
/// (before the next poll frees the payload).
Object? readCurrentMessage() {
  final length = _n.eventGetDataLength();
  if (length <= 0) return null;

  final payload = _n.eventGetData().asTypedList(length);
  return msgpackDecode(Uint8List.fromList(payload));
}
