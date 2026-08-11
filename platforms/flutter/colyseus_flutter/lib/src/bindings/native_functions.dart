import 'dart:ffi';
import 'package:ffi/ffi.dart';

import '../native_library.dart';

/// Thin typed-wrapper around the native C functions.
/// Uses dart:ffi lookups on the shared library.
class NativeFunctions {
  NativeFunctions._();
  static final NativeFunctions instance = NativeFunctions._();

  final DynamicLibrary _lib = loadColyseusLibrary();

  // ===== Client =====

  late final clientCreate = _lib.lookupFunction<
      IntPtr Function(Pointer<Utf8>),
      int Function(Pointer<Utf8>)>('colyseus_flutter_client_create');

  late final clientFree = _lib.lookupFunction<
      Void Function(IntPtr),
      void Function(int)>('colyseus_flutter_client_free');

  late final clientJoinOrCreate = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>, Pointer<Utf8>)>('colyseus_flutter_client_join_or_create');

  late final clientCreateRoom = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>, Pointer<Utf8>)>('colyseus_flutter_client_create_room');

  late final clientJoin = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>, Pointer<Utf8>)>('colyseus_flutter_client_join');

  late final clientJoinById = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>, Pointer<Utf8>)>('colyseus_flutter_client_join_by_id');

  late final clientReconnect = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>)>('colyseus_flutter_client_reconnect');

  // ===== Room =====

  late final roomLeave = _lib.lookupFunction<
      Void Function(Int32),
      void Function(int)>('colyseus_flutter_room_leave');

  late final roomFree = _lib.lookupFunction<
      Void Function(Int32),
      void Function(int)>('colyseus_flutter_room_free');

  late final roomGetId = _lib.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('colyseus_flutter_room_get_id');

  late final roomGetSessionId = _lib.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('colyseus_flutter_room_get_session_id');

  late final roomGetName = _lib.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('colyseus_flutter_room_get_name');

  late final roomGetReconnectionToken = _lib.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('colyseus_flutter_room_get_reconnection_token');

  late final roomIsConnected = _lib.lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('colyseus_flutter_room_is_connected');

  late final roomIsReconnecting = _lib.lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('colyseus_flutter_room_is_reconnecting');

  late final roomSetReconnectionOptions = _lib.lookupFunction<
      Void Function(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32),
      void Function(int, int, int, int, int, int, int, int)>(
      'colyseus_flutter_room_set_reconnection_options');

  // ===== Room Send =====

  late final roomSendMessage = _lib.lookupFunction<
      Void Function(Int32, Pointer<Utf8>, IntPtr),
      void Function(int, Pointer<Utf8>, int)>('colyseus_flutter_room_send_message');

  late final roomSendMessageInt = _lib.lookupFunction<
      Void Function(Int32, Int32, IntPtr),
      void Function(int, int, int)>('colyseus_flutter_room_send_message_int');

  late final roomSendBytes = _lib.lookupFunction<
      Void Function(Int32, Pointer<Utf8>, Pointer<Uint8>, Int32),
      void Function(int, Pointer<Utf8>, Pointer<Uint8>, int)>('colyseus_flutter_room_send_bytes');

  // ===== Message Builder =====

  late final messageCreateMap = _lib.lookupFunction<
      IntPtr Function(),
      int Function()>('colyseus_flutter_message_create_map');

  late final messageCreateArray = _lib.lookupFunction<
      IntPtr Function(),
      int Function()>('colyseus_flutter_message_create_array');

  late final messageCreateString = _lib.lookupFunction<
      IntPtr Function(Pointer<Utf8>),
      int Function(Pointer<Utf8>)>('colyseus_flutter_message_create_string');

  late final messageCreateInt = _lib.lookupFunction<
      IntPtr Function(Int64),
      int Function(int)>('colyseus_flutter_message_create_int');

  late final messageCreateFloat = _lib.lookupFunction<
      IntPtr Function(Double),
      int Function(double)>('colyseus_flutter_message_create_float');

  late final messageCreateBool = _lib.lookupFunction<
      IntPtr Function(Int32),
      int Function(int)>('colyseus_flutter_message_create_bool');

  late final messageCreateNil = _lib.lookupFunction<
      IntPtr Function(),
      int Function()>('colyseus_flutter_message_create_nil');

  late final messageMapPutStr = _lib.lookupFunction<
      Void Function(IntPtr, Pointer<Utf8>, Pointer<Utf8>),
      void Function(int, Pointer<Utf8>, Pointer<Utf8>)>('colyseus_flutter_message_map_put_str');

  late final messageMapPutInt = _lib.lookupFunction<
      Void Function(IntPtr, Pointer<Utf8>, Int64),
      void Function(int, Pointer<Utf8>, int)>('colyseus_flutter_message_map_put_int');

  late final messageMapPutFloat = _lib.lookupFunction<
      Void Function(IntPtr, Pointer<Utf8>, Double),
      void Function(int, Pointer<Utf8>, double)>('colyseus_flutter_message_map_put_float');

  late final messageMapPutBool = _lib.lookupFunction<
      Void Function(IntPtr, Pointer<Utf8>, Int32),
      void Function(int, Pointer<Utf8>, int)>('colyseus_flutter_message_map_put_bool');

  late final messageMapPutNil = _lib.lookupFunction<
      Void Function(IntPtr, Pointer<Utf8>),
      void Function(int, Pointer<Utf8>)>('colyseus_flutter_message_map_put_nil');

  late final messageMapPut = _lib.lookupFunction<
      Void Function(IntPtr, Pointer<Utf8>, IntPtr),
      void Function(int, Pointer<Utf8>, int)>('colyseus_flutter_message_map_put');

  late final messageArrayPushStr = _lib.lookupFunction<
      Void Function(IntPtr, Pointer<Utf8>),
      void Function(int, Pointer<Utf8>)>('colyseus_flutter_message_array_push_str');

  late final messageArrayPushInt = _lib.lookupFunction<
      Void Function(IntPtr, Int64),
      void Function(int, int)>('colyseus_flutter_message_array_push_int');

  late final messageArrayPushFloat = _lib.lookupFunction<
      Void Function(IntPtr, Double),
      void Function(int, double)>('colyseus_flutter_message_array_push_float');

  late final messageArrayPushBool = _lib.lookupFunction<
      Void Function(IntPtr, Int32),
      void Function(int, int)>('colyseus_flutter_message_array_push_bool');

  late final messageArrayPushNil = _lib.lookupFunction<
      Void Function(IntPtr),
      void Function(int)>('colyseus_flutter_message_array_push_nil');

  late final messageArrayPush = _lib.lookupFunction<
      Void Function(IntPtr, IntPtr),
      void Function(int, int)>('colyseus_flutter_message_array_push');

  late final messageFree = _lib.lookupFunction<
      Void Function(IntPtr),
      void Function(int)>('colyseus_flutter_message_free');

  // ===== Event Polling =====

  late final pollEvent = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_poll_event');

  late final eventGetRoom = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_event_get_room');

  late final eventGetCode = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_event_get_code');

  late final eventGetMessage = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_event_get_message');

  late final eventGetData = _lib.lookupFunction<
      Pointer<Uint8> Function(),
      Pointer<Uint8> Function()>('colyseus_flutter_event_get_data');

  late final eventGetDataLength = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_event_get_data_length');

  // ===== Schema Event Accessors =====

  late final eventGetCallbackHandle = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_event_get_callback_handle');

  late final eventGetInstance = _lib.lookupFunction<
      IntPtr Function(),
      int Function()>('colyseus_flutter_event_get_instance');

  late final eventGetValueNumber = _lib.lookupFunction<
      Double Function(),
      double Function()>('colyseus_flutter_event_get_value_number');

  late final eventGetValueString = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_event_get_value_string');

  late final eventGetPrevValueNumber = _lib.lookupFunction<
      Double Function(),
      double Function()>('colyseus_flutter_event_get_prev_value_number');

  late final eventGetPrevValueString = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_event_get_prev_value_string');

  late final eventGetKeyString = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_event_get_key_string');

  late final eventGetValueType = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_event_get_value_type');

  // ===== Message Reader =====

  late final messageGetTypeStr = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_message_get_type_str');

  late final messageGetType = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_message_get_type');

  late final messageReadString = _lib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('colyseus_flutter_message_read_string');

  late final messageReadNumber = _lib.lookupFunction<
      Double Function(Pointer<Utf8>),
      double Function(Pointer<Utf8>)>('colyseus_flutter_message_read_number');

  late final messageReadBool = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>),
      int Function(Pointer<Utf8>)>('colyseus_flutter_message_read_bool');

  late final messageReadStringValue = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_message_read_string_value');

  late final messageReadNumberValue = _lib.lookupFunction<
      Double Function(),
      double Function()>('colyseus_flutter_message_read_number_value');

  late final messageMapSize = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_message_map_size');

  late final messageIterBegin = _lib.lookupFunction<
      Void Function(),
      void Function()>('colyseus_flutter_message_iter_begin');

  late final messageIterNext = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_message_iter_next');

  late final messageIterKey = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_message_iter_key');

  late final messageIterValueType = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_message_iter_value_type');

  late final messageIterValueString = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('colyseus_flutter_message_iter_value_string');

  late final messageIterValueNumber = _lib.lookupFunction<
      Double Function(),
      double Function()>('colyseus_flutter_message_iter_value_number');

  late final messageArraySize = _lib.lookupFunction<
      Int32 Function(),
      int Function()>('colyseus_flutter_message_array_size');

  late final messageArrayElementType = _lib.lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('colyseus_flutter_message_array_element_type');

  late final messageArrayElementString = _lib.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('colyseus_flutter_message_array_element_string');

  late final messageArrayElementNumber = _lib.lookupFunction<
      Double Function(Int32),
      double Function(int)>('colyseus_flutter_message_array_element_number');

  // ===== State / Schema =====

  late final roomGetState = _lib.lookupFunction<
      IntPtr Function(Int32),
      int Function(int)>('colyseus_flutter_room_get_state');

  late final schemaGetString = _lib.lookupFunction<
      Pointer<Utf8> Function(IntPtr, Pointer<Utf8>),
      Pointer<Utf8> Function(int, Pointer<Utf8>)>('colyseus_flutter_schema_get_string');

  late final schemaGetNumber = _lib.lookupFunction<
      Double Function(IntPtr, Pointer<Utf8>),
      double Function(int, Pointer<Utf8>)>('colyseus_flutter_schema_get_number');

  late final schemaGetFieldType = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>)>('colyseus_flutter_schema_get_field_type');

  late final mapGet = _lib.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf8>, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>, Pointer<Utf8>)>('colyseus_flutter_map_get');

  // ===== Callbacks =====

  late final callbacksCreate = _lib.lookupFunction<
      IntPtr Function(Int32),
      int Function(int)>('colyseus_flutter_callbacks_create');

  late final callbacksFree = _lib.lookupFunction<
      Void Function(IntPtr),
      void Function(int)>('colyseus_flutter_callbacks_free');

  late final callbacksRemoveHandle = _lib.lookupFunction<
      Void Function(IntPtr, Int32),
      void Function(int, int)>('colyseus_flutter_callbacks_remove_handle');

  late final callbacksListen = _lib.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Pointer<Utf8>),
      int Function(int, int, Pointer<Utf8>)>('colyseus_flutter_callbacks_listen');

  late final callbacksOnAdd = _lib.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Pointer<Utf8>),
      int Function(int, int, Pointer<Utf8>)>('colyseus_flutter_callbacks_on_add');

  late final callbacksOnRemove = _lib.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Pointer<Utf8>),
      int Function(int, int, Pointer<Utf8>)>('colyseus_flutter_callbacks_on_remove');

  // ===== Extras: room bridge =====

  /// The core `colyseus_room_t*` behind a glue room ref (0 when unresolved).
  late final roomPtr = _lib.lookupFunction<
      IntPtr Function(Int32),
      int Function(int)>('colyseus_flutter_room_ptr');

  late final setSerializedInbound = _lib.lookupFunction<
      Void Function(Int32),
      void Function(int)>('colyseus_flutter_set_serialized_inbound');

  /// Wraps colyseus_select_by_latency so the winning endpoint reaches Dart as
  /// an owned copy — the core's own string is gone by the time an async
  /// listener callback runs.
  late final selectByLatency = _lib.lookupFunction<
      Void Function(Pointer<Pointer<Char>>, Int32, Int32, Int32, Int32,
          Pointer<NativeFunction<Void Function(Pointer<Char>, Double)>>),
      void Function(Pointer<Pointer<Char>>, int, int, int, int,
          Pointer<NativeFunction<Void Function(Pointer<Char>, Double)>>)>(
      'colyseus_flutter_select_by_latency');

  late final freeString = _lib.lookupFunction<
      Void Function(Pointer<Char>),
      void Function(Pointer<Char>)>('colyseus_flutter_free_string');

  // ===== Extras: field access =====
  //
  // Resolve a name once, then read/write through (type, offset, index).
  // The accessors are leaf calls — no Dart callback can run underneath them.

  late final fieldResolve = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>),
      int Function(int, Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>)>(
      'colyseus_flutter_field_resolve');

  /// The instance's own vtable — reflection schemas have no static one.
  late final instanceVtable = _lib.lookupFunction<
      IntPtr Function(IntPtr),
      int Function(int)>('colyseus_flutter_instance_vtable', isLeaf: true);

  late final fieldCount = _lib.lookupFunction<
      Int32 Function(IntPtr),
      int Function(int)>('colyseus_flutter_field_count', isLeaf: true);

  late final fieldNameAt = _lib.lookupFunction<
      Pointer<Utf8> Function(IntPtr, Int32),
      Pointer<Utf8> Function(int, int)>('colyseus_flutter_field_name_at');

  late final fieldGetNumber = _lib.lookupFunction<
      Double Function(IntPtr, Int32, Int32, Int32),
      double Function(int, int, int, int)>(
      'colyseus_flutter_field_get_number', isLeaf: true);

  late final fieldSetNumber = _lib.lookupFunction<
      Void Function(IntPtr, Int32, Int32, Int32, Double),
      void Function(int, int, int, int, double)>(
      'colyseus_flutter_field_set_number', isLeaf: true);

  late final fieldGetString = _lib.lookupFunction<
      Pointer<Utf8> Function(IntPtr, Int32, Int32),
      Pointer<Utf8> Function(int, int, int)>('colyseus_flutter_field_get_string');

  late final fieldGetRef = _lib.lookupFunction<
      IntPtr Function(IntPtr, Int32, Int32),
      int Function(int, int, int)>(
      'colyseus_flutter_field_get_ref', isLeaf: true);

  // ===== Extras: collections =====
  //
  // Maps are uthash-backed with no ordinal accessor, so iteration snapshots
  // the collection into a native scratch buffer that is then read by ordinal.
  // A snapshot is only valid until the next decode.

  late final collectionSnapshot = _lib.lookupFunction<
      Int32 Function(IntPtr, Int32),
      int Function(int, int)>('colyseus_flutter_collection_snapshot');

  late final collectionHasSchemaChild = _lib.lookupFunction<
      Int32 Function(),
      int Function()>(
      'colyseus_flutter_collection_has_schema_child', isLeaf: true);

  late final collectionPrimitiveType = _lib.lookupFunction<
      Int32 Function(),
      int Function()>(
      'colyseus_flutter_collection_primitive_type', isLeaf: true);

  late final collectionEntryKey = _lib.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('colyseus_flutter_collection_entry_key');

  late final collectionEntryIndex = _lib.lookupFunction<
      Int32 Function(Int32),
      int Function(int)>(
      'colyseus_flutter_collection_entry_index', isLeaf: true);

  late final collectionEntryRef = _lib.lookupFunction<
      IntPtr Function(Int32),
      int Function(int)>(
      'colyseus_flutter_collection_entry_ref', isLeaf: true);

  late final collectionEntryNumber = _lib.lookupFunction<
      Double Function(Int32),
      double Function(int)>(
      'colyseus_flutter_collection_entry_number', isLeaf: true);

  late final collectionEntryString = _lib.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('colyseus_flutter_collection_entry_string');

  late final collectionGet = _lib.lookupFunction<
      IntPtr Function(IntPtr, Int32, Pointer<Utf8>, Int32),
      int Function(int, int, Pointer<Utf8>, int)>('colyseus_flutter_collection_get');

  late final collectionCount = _lib.lookupFunction<
      Int32 Function(IntPtr, Int32),
      int Function(int, int)>(
      'colyseus_flutter_collection_count', isLeaf: true);

  late final collectionContains = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>)>('colyseus_flutter_collection_contains');
}
