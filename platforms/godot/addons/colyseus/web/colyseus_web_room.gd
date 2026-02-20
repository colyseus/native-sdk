class_name ColyseusWebRoom
extends RefCounted
## Colyseus Web Room - JavaScript SDK Bridge
##
## This implementation uses JavaScriptBridge to communicate with the
## Colyseus JavaScript SDK for web exports.

## Emitted when successfully joined the room
signal joined()
## Emitted when the room state changes
signal state_changed()
## Emitted when a message is received from the server
signal message_received(type: Variant, data: Variant)
## Emitted when an error occurs
signal error(code: int, message: String)
## Emitted when leaving the room
signal left(code: int, reason: String)

var _js_room_id: int = -1
var _room_id: String = ""
var _session_id: String = ""
var _room_name: String = ""
var _joined: bool = false
var _state_type = null

# Keep JavaScript callback references alive to prevent GC
var _callbacks: Array = []
var _colyseus_godot: JavaScriptObject

# Reference to the callbacks instance that manages state synchronization
var _state_callbacks = null  # ColyseusWebCallbacks

func _init():
	# Get reference to the ColyseusGodot bridge object
	_colyseus_godot = JavaScriptBridge.get_interface("ColyseusGodot")

## Internal: Connect using join_or_create
func _connect_join_or_create(client_id: int, room_name: String, options: Dictionary) -> void:
	if not _colyseus_godot:
		push_error("ColyseusWebRoom: JavaScript bridge not available")
		return
	
	var on_success = JavaScriptBridge.create_callback(_on_connect_success)
	var on_error = JavaScriptBridge.create_callback(_on_connect_error)
	_callbacks.append(on_success)
	_callbacks.append(on_error)
	
	_colyseus_godot.joinOrCreate(client_id, room_name, _dict_to_js(options), on_success, on_error)

## Internal: Connect using create
func _connect_create(client_id: int, room_name: String, options: Dictionary) -> void:
	if not _colyseus_godot:
		push_error("ColyseusWebRoom: JavaScript bridge not available")
		return
	
	var on_success = JavaScriptBridge.create_callback(_on_connect_success)
	var on_error = JavaScriptBridge.create_callback(_on_connect_error)
	_callbacks.append(on_success)
	_callbacks.append(on_error)
	
	_colyseus_godot.create(client_id, room_name, _dict_to_js(options), on_success, on_error)

## Internal: Connect using join
func _connect_join(client_id: int, room_name: String, options: Dictionary) -> void:
	if not _colyseus_godot:
		push_error("ColyseusWebRoom: JavaScript bridge not available")
		return
	
	var on_success = JavaScriptBridge.create_callback(_on_connect_success)
	var on_error = JavaScriptBridge.create_callback(_on_connect_error)
	_callbacks.append(on_success)
	_callbacks.append(on_error)
	
	_colyseus_godot.join(client_id, room_name, _dict_to_js(options), on_success, on_error)

## Internal: Connect using join by ID
func _connect_join_by_id(client_id: int, room_id: String, options: Dictionary) -> void:
	if not _colyseus_godot:
		push_error("ColyseusWebRoom: JavaScript bridge not available")
		return
	
	var on_success = JavaScriptBridge.create_callback(_on_connect_success)
	var on_error = JavaScriptBridge.create_callback(_on_connect_error)
	_callbacks.append(on_success)
	_callbacks.append(on_error)
	
	_colyseus_godot.joinById(client_id, room_id, _dict_to_js(options), on_success, on_error)

## Internal: Connect using reconnect
func _connect_reconnect(client_id: int, reconnection_token: String) -> void:
	if not _colyseus_godot:
		push_error("ColyseusWebRoom: JavaScript bridge not available")
		return
	
	var on_success = JavaScriptBridge.create_callback(_on_connect_success)
	var on_error = JavaScriptBridge.create_callback(_on_connect_error)
	_callbacks.append(on_success)
	_callbacks.append(on_error)
	
	_colyseus_godot.reconnect(client_id, reconnection_token, on_success, on_error)

## Convert GDScript Dictionary to JavaScript object
func _dict_to_js(dict: Dictionary) -> JavaScriptObject:
	if dict.is_empty():
		return JavaScriptBridge.create_object("Object")
	# For non-empty dicts, we use JSON roundtrip
	var json_str = JSON.stringify(dict)
	return JavaScriptBridge.eval("JSON.parse('%s')" % json_str.replace("'", "\\'"), true)

## Extract result ID from callback args (handles JavaScriptObject edge case)
func _extract_result_id(args: Array) -> int:
	if args.size() == 0:
		return -1
	var arg = args[0]
	# Try direct int conversion first
	if arg is int:
		return arg
	if arg is float:
		return int(arg)
	# Fallback: use str() which works on JavaScriptObject
	var str_val = str(arg)
	if str_val.is_valid_int():
		return int(str_val)
	return -1

## Called when connection succeeds
func _on_connect_success(args: Array) -> void:
	var result_id = _extract_result_id(args)
	if result_id < 0:
		push_error("ColyseusWebRoom: Invalid result ID from callback")
		return
	
	# Fetch the result from JavaScript using getResult()
	var json_str = str(_colyseus_godot.getResult(result_id))
	var data = JSON.parse_string(json_str)
	
	if data is Dictionary and not data.get("error", false):
		_js_room_id = int(data.get("roomId", -1))
		_room_id = str(data.get("id", ""))
		_session_id = str(data.get("sessionId", ""))
		_room_name = str(data.get("name", ""))
		_joined = true
		_setup_room_callbacks()
		print("ColyseusWebRoom: Joined room ", _room_id, " session ", _session_id)
		joined.emit()
	else:
		var err_msg = data.get("message", "Unknown error") if data is Dictionary else "Invalid response"
		push_error("ColyseusWebRoom: Failed to join: ", err_msg)

## Called when connection fails
func _on_connect_error(args: Array) -> void:
	var result_id = _extract_result_id(args)
	var json_str = "{\"code\": 0, \"message\": \"Unknown error\"}"
	
	if result_id >= 0 and _colyseus_godot:
		json_str = str(_colyseus_godot.getResult(result_id))
	
	var data = JSON.parse_string(json_str)
	var code = int(data.get("code", 0)) if data is Dictionary else 0
	var message = str(data.get("message", "Unknown error")) if data is Dictionary else "Unknown error"
	error.emit(code, message)

## Setup room event callbacks
func _setup_room_callbacks() -> void:
	if not _colyseus_godot:
		return
	
	# State change callback
	var on_state = JavaScriptBridge.create_callback(_on_state_change)
	_callbacks.append(on_state)
	_colyseus_godot.setOnStateChange(_js_room_id, on_state)
	
	# Message callback
	var on_msg = JavaScriptBridge.create_callback(_on_message)
	_callbacks.append(on_msg)
	_colyseus_godot.setOnMessage(_js_room_id, on_msg)
	
	# Leave callback
	var on_leave = JavaScriptBridge.create_callback(_on_leave)
	_callbacks.append(on_leave)
	_colyseus_godot.setOnLeave(_js_room_id, on_leave)
	
	# Error callback
	var on_err = JavaScriptBridge.create_callback(_on_room_error)
	_callbacks.append(on_err)
	_colyseus_godot.setOnError(_js_room_id, on_err)

## Called when state changes
func _on_state_change(args: Array) -> void:
	# args[0] is a result ID, but we don't need to fetch it - just emit the signal
	# The state can be retrieved via get_state() if needed
	state_changed.emit()

## Called when message received
func _on_message(args: Array) -> void:
	var result_id = _extract_result_id(args)
	if result_id < 0 or not _colyseus_godot:
		return
	
	var json_str = str(_colyseus_godot.getResult(result_id))
	var data = JSON.parse_string(json_str)
	
	var type = data.get("type", "") if data is Dictionary else ""
	var message = data.get("data", null) if data is Dictionary else null
	message_received.emit(type, message)

## Called when leaving room
func _on_leave(args: Array) -> void:
	var result_id = _extract_result_id(args)
	var code = 1000
	
	if result_id >= 0 and _colyseus_godot:
		var json_str = str(_colyseus_godot.getResult(result_id))
		var data = JSON.parse_string(json_str)
		code = int(data.get("code", 1000)) if data is Dictionary else 1000
	
	_joined = false
	left.emit(code, "")

## Called on room error
func _on_room_error(args: Array) -> void:
	var result_id = _extract_result_id(args)
	var code = 0
	var message = "Unknown error"
	
	if result_id >= 0 and _colyseus_godot:
		var json_str = str(_colyseus_godot.getResult(result_id))
		var data = JSON.parse_string(json_str)
		code = int(data.get("code", 0)) if data is Dictionary else 0
		message = str(data.get("message", "Unknown error")) if data is Dictionary else "Unknown error"
	
	error.emit(code, message)

## Get the room ID
func get_id() -> String:
	return _room_id

## Get the session ID
func get_session_id() -> String:
	return _session_id

## Get the room name
func get_name() -> String:
	return _room_name

## Check if joined
func has_joined() -> bool:
	if _js_room_id >= 0 and _colyseus_godot:
		var result = _colyseus_godot.hasJoined(_js_room_id)
		return result == true
	return false

## Get reconnection token
func get_reconnection_token() -> String:
	if _js_room_id >= 0 and _colyseus_godot:
		return str(_colyseus_godot.getReconnectionToken(_js_room_id))
	return ""

## Set state type (for typed state support)
func set_state_type(state_type) -> void:
	_state_type = state_type

## Set the callbacks instance (called by ColyseusWebCallbacks.get_for_room)
func _set_state_callbacks(callbacks) -> void:
	_state_callbacks = callbacks

## Get the room state
## If callbacks are set up (using raw changes), returns the synchronized GDScript state
## Otherwise falls back to JSON parsing from JavaScript
func get_state() -> Variant:
	# If we have callbacks with raw changes sync, use the GDScript state
	if _state_callbacks != null:
		return _state_callbacks.get_state()
	
	# Fallback: fetch state from JavaScript (legacy mode)
	if _js_room_id < 0 or not _colyseus_godot:
		return null
	
	var state_json = str(_colyseus_godot.getState(_js_room_id))
	var state_dict = JSON.parse_string(state_json)
	
	# If state type is set, wrap in GDScript schema
	if _state_type != null and state_dict is Dictionary:
		return _wrap_state_in_schema(state_dict, _state_type)
	
	return state_dict

## Wrap state dictionary in GDScript schema objects
func _wrap_state_in_schema(data: Dictionary, schema_class) -> Variant:
	if schema_class == null or not data is Dictionary:
		return data
	
	# Create schema instance
	var instance = schema_class.new()
	
	# Get field definitions
	var field_defs = schema_class.definition() if schema_class.has_method("definition") else []
	
	# Populate fields
	for field in field_defs:
		if field is Colyseus.Schema.Field:
			var field_name = field.name
			if data.has(field_name):
				var value = data[field_name]
				if field.type == Colyseus.Schema.MAP and field.child_type != null:
					# Wrap map values
					var map = Colyseus.Map.new(field.child_type)
					if value is Dictionary:
						for key in value:
							var child_value = value[key]
							if field.has_schema_child() and child_value is Dictionary:
								map._set_item(key, _wrap_state_in_schema(child_value, field.child_type))
							else:
								map._set_item(key, child_value)
					instance._set_field(field_name, map)
				elif field.type == Colyseus.Schema.ARRAY and field.child_type != null:
					# Wrap array values
					var arr = Colyseus.ArraySchema.new(field.child_type)
					if value is Array:
						for i in range(value.size()):
							var child_value = value[i]
							if field.has_schema_child() and child_value is Dictionary:
								arr._push(_wrap_state_in_schema(child_value, field.child_type))
							else:
								arr._push(child_value)
					instance._set_field(field_name, arr)
				elif field.type == Colyseus.Schema.REF and field.child_type != null:
					# Wrap ref value
					if value is Dictionary:
						instance._set_field(field_name, _wrap_state_in_schema(value, field.child_type))
					else:
						instance._set_field(field_name, value)
				else:
					instance._set_field(field_name, value)
	
	return instance

## Send a message with string type
func send_message(type: String, data: Variant = null) -> void:
	if _js_room_id < 0 or not _colyseus_godot:
		return
	
	var data_json = JSON.stringify(data) if data != null else "null"
	_colyseus_godot.sendMessage(_js_room_id, type, data_json)

## Send a message with integer type
func send_message_int(type: int, data: Variant = null) -> void:
	if _js_room_id < 0 or not _colyseus_godot:
		return
	
	var data_json = JSON.stringify(data) if data != null else "null"
	_colyseus_godot.sendMessageInt(_js_room_id, type, data_json)

## Leave the room
func leave(consented: bool = true) -> void:
	if _js_room_id < 0 or not _colyseus_godot:
		return
	
	_colyseus_godot.leave(_js_room_id, consented)
	_joined = false

## Clean up
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _js_room_id >= 0 and _colyseus_godot:
			_colyseus_godot.disposeRoom(_js_room_id)
		_callbacks.clear()
