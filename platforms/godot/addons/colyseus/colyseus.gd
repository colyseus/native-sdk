class_name Colyseus
extends RefCounted
## Colyseus SDK for Godot
##
## Cross-platform multiplayer client using the GDExtension.
## Works on all platforms including web (requires dlink-enabled export templates).
##
## Usage:
##   var client = Colyseus.Client.new("ws://localhost:2567")
##   var room = client.join_or_create("my_room")
##   var callbacks = Colyseus.Callbacks.of(room)

## @deprecated: Use Colyseus.Client.new("ws://localhost:2567") instead.
static func create_client() -> Client:
	push_warning("Colyseus.create_client() is deprecated. Use Colyseus.Client.new(endpoint) instead.")
	return Client.new()

## Poll the native SDK for network events. Called automatically each frame
## via the internal _Poller node. Only call manually for headless/test usage.
static func poll() -> void:
	if _poll_instance:
		_poll_instance.call(&"poll")

## Internal: a native ColyseusClient instance kept alive for calling static poll()
static var _poll_instance = null

## Internal: singleton polling node added to scene tree
static var _poll_node: Node = null

static func _ensure_polling():
	if _poll_node and is_instance_valid(_poll_node):
		return
	var tree = Engine.get_main_loop() as SceneTree
	if not tree:
		return
	_poll_node = _Poller.new()
	_poll_node.name = &"_ColyseusPoller"
	tree.root.call_deferred(&"add_child", _poll_node)

## @deprecated: Use Colyseus.Callbacks.of(room) instead.
static func callbacks(room) -> Callbacks:
	push_warning("Colyseus.callbacks(room) is deprecated. Use Colyseus.Callbacks.of(room) instead.")
	return Callbacks.of(room)

## Colyseus Schema Definition Library
## 
## This library allows you to define your state schema in GDScript.
## 
## Example:
##   
##   class Player extends Colyseus.Schema:
##       static func definition():
##           return [
##               Colyseus.Schema.Field.new("x", Colyseus.Schema.NUMBER),
##               Colyseus.Schema.Field.new("y", Colyseus.Schema.NUMBER)
##           ]
##   
##   class RoomState extends Colyseus.Schema:
##       static func definition():
##           return [
##               Colyseus.Schema.Field.new("players", Colyseus.Schema.MAP, Player),
##           ]
##   
##   room.set_state_type(RoomState)

## Wraps native ColyseusCallbacks so users can type `var callbacks: Colyseus.Callbacks`.
class Callbacks extends RefCounted:
	var _native

	static func of(room) -> Callbacks:
		var native_room = room._native if room is Room else room
		var class_name_str := &"_ColyseusCallbacks"
		if ClassDB.class_exists(class_name_str):
			var instance = ClassDB.instantiate(class_name_str)
			var native_cb = null
			if instance and instance.has_method(&"_init_with_room"):
				instance._init_with_room(native_room)
				native_cb = instance
			elif instance and instance.has_method(&"get"):
				native_cb = instance.get(native_room)
			if native_cb:
				var cb = Callbacks.new()
				cb._native = native_cb
				return cb
		push_error("Colyseus: ColyseusCallbacks not available. Make sure the GDExtension is properly loaded.")
		return null

	func listen(target, property_or_callback, callback = null) -> int:
		if callback == null:
			return _native.listen(target, property_or_callback)
		return _native.listen(target, property_or_callback, callback)

	func on_add(target, property_or_callback, callback = null) -> int:
		if callback == null:
			return _native.on_add(target, property_or_callback)
		return _native.on_add(target, property_or_callback, callback)

	func on_remove(target, property_or_callback, callback = null) -> int:
		if callback == null:
			return _native.on_remove(target, property_or_callback)
		return _native.on_remove(target, property_or_callback, callback)

	func on_change(target, property_or_callback = null, callback = null) -> int:
		if property_or_callback == null:
			return _native.on_change(target)
		if callback == null:
			return _native.on_change(target, property_or_callback)
		return _native.on_change(target, property_or_callback, callback)

	func remove(handle: int) -> void:
		_native.remove(handle)

# =============================================================================
# Schema Base Class
# =============================================================================

## Base class for all schema types. Extend this class to define your state structure.
class Schema extends RefCounted:
	
	# =========================================================================
	# Type Constants
	# =========================================================================
	
	## String type
	const STRING = "string"
	## Number type (64-bit float)
	const NUMBER = "number"
	## Boolean type
	const BOOLEAN = "boolean"
	
	## Signed 8-bit integer
	const INT8 = "int8"
	## Unsigned 8-bit integer
	const UINT8 = "uint8"
	## Signed 16-bit integer
	const INT16 = "int16"
	## Unsigned 16-bit integer
	const UINT16 = "uint16"
	## Signed 32-bit integer
	const INT32 = "int32"
	## Unsigned 32-bit integer
	const UINT32 = "uint32"
	## Signed 64-bit integer
	const INT64 = "int64"
	## Unsigned 64-bit integer
	const UINT64 = "uint64"
	## 32-bit float
	const FLOAT32 = "float32"
	## 64-bit float
	const FLOAT64 = "float64"
	
	## Map collection type (key-value pairs)
	const MAP = "map"
	## Array collection type (ordered list)
	const ARRAY = "array"
	## Reference to another schema
	const REF = "ref"
	
	# =========================================================================
	# Field Class (nested inside Schema)
	# =========================================================================
	
	## Describes a single field in a schema
	class Field extends RefCounted:
		## Field name
		var name: String
		## Field type (one of the type constants above)
		var type: String
		## For collections (MAP, ARRAY) or REF: the child type (class reference or primitive type)
		var child_type = null
		## For MAP: the key type (defaults to STRING)
		var key_type: String = Colyseus.Schema.STRING
		
		func _init(field_name: String, field_type: String, child = null, key: String = Colyseus.Schema.STRING):
			name = field_name
			type = field_type
			child_type = child
			key_type = key
		
		## Check if this field holds a primitive type
		func is_primitive() -> bool:
			return type != Colyseus.Schema.MAP and type != Colyseus.Schema.ARRAY and type != Colyseus.Schema.REF
		
		## Check if this field is a collection (MAP or ARRAY)
		func is_collection() -> bool:
			return type == Colyseus.Schema.MAP or type == Colyseus.Schema.ARRAY
		
		## Check if this field is a reference to another schema
		func is_ref() -> bool:
			return type == Colyseus.Schema.REF
		
		## Check if child type is a schema class (vs primitive)
		func has_schema_child() -> bool:
			return child_type != null and typeof(child_type) != TYPE_STRING
	
	# =========================================================================
	# Schema instance members
	# =========================================================================
	## Internal: Reference ID assigned by the decoder
	var __ref_id: int = -1
	## Internal: Stores field values by name
	var __fields: Dictionary = {}
	## Internal: Reference to the schema vtable/definition
	var __vtable = null
	## Internal: Cache of field definitions
	var __field_defs: Array = []
	
	func _init():
		# Initialize fields with default values from definition
		__field_defs = definition()
		for field in __field_defs:
			if field is Field:
				__fields[field.name] = Colyseus.get_default_value(field.type)
	
	## Override this in your subclass to define the schema fields.
	## Returns an array of Field objects.
	static func definition() -> Array:
		return []
	
	## Internal: Called by the decoder to set field values
	func _set_field(field_name: String, value) -> void:
		__fields[field_name] = value
	
	## Internal: Called by the decoder to get field values
	func _get_field(field_name: String):
		return __fields.get(field_name)
	
	## Internal: Check if a field exists
	func _has_field(field_name: String) -> bool:
		return __fields.has(field_name)
	
	## Get all field names
	func get_field_names() -> Array:
		return __fields.keys()
	
	## Convert schema to dictionary (for debugging/serialization)
	func to_dictionary() -> Dictionary:
		var result = {}
		for key in __fields:
			var value = __fields[key]
			if value is Schema:
				result[key] = value.to_dictionary()
			elif value is Map:
				result[key] = value.to_dictionary()
			elif value is ArraySchema:
				result[key] = value.to_array()
			else:
				result[key] = value
		return result
	
	# Property access via _get/_set
	func _get(property: StringName):
		var prop_str = str(property)
		if __fields.has(prop_str):
			return __fields[prop_str]
		# Check if it's a known field from definition and return default
		for field in __field_defs:
			if field is Field and field.name == prop_str:
				return Colyseus.get_default_value(field.type)
		return null
	
	func _set(property: StringName, value) -> bool:
		var prop_str = str(property)
		# Allow setting known fields or internal properties
		if __fields.has(prop_str) or prop_str.begins_with("__"):
			__fields[prop_str] = value
			return true
		# Check if it's a known field from definition
		for field in __field_defs:
			if field is Field and field.name == prop_str:
				__fields[prop_str] = value
				return true
		return false
	
	func _get_property_list() -> Array:
		var properties = []
		for field_name in __fields.keys():
			properties.append({
				"name": field_name,
				"type": typeof(__fields[field_name]),
				"usage": PROPERTY_USAGE_DEFAULT
			})
		return properties

	func _to_string() -> String:
		return JSON.stringify(to_dictionary())

# =============================================================================
# Map Class
# =============================================================================

## Map collection that holds key-value pairs where values can be schemas or primitives
class Map extends RefCounted:
	## Internal: Stores items by key
	var __items: Dictionary = {}
	## Internal: The child type (class reference for schemas, or primitive type string)
	var __child_type = null
	## Internal: Reference ID
	var __ref_id: int = -1
	
	func _init(child_type = null):
		__child_type = child_type
	
	## Get all keys in the map
	func keys() -> Array:
		return __items.keys()
	
	## Get all values in the map
	func values() -> Array:
		return __items.values()
	
	## Get the number of items in the map
	func size() -> int:
		return __items.size()
	
	## Check if a key exists
	func has(key: String) -> bool:
		return __items.has(key)
	
	## Get a value by key
	func get_item(key: String):
		return __items.get(key)
	
	## Internal: Set a value (called by decoder)
	func _set_item(key: String, value) -> void:
		__items[key] = value
	
	## Internal: Remove an item (called by decoder)
	func _remove_item(key: String) -> void:
		__items.erase(key)
	
	## Internal: Clear all items (called by decoder)
	func _clear() -> void:
		__items.clear()
	
	## Convert to dictionary
	func to_dictionary() -> Dictionary:
		var result = {}
		for key in __items:
			var value = __items[key]
			if value is Schema:
				result[key] = value.to_dictionary()
			elif value is Map:
				result[key] = value.to_dictionary()
			elif value is ArraySchema:
				result[key] = value.to_array()
			else:
				result[key] = value
		return result
	
	# Allow map["key"] access
	func _get(property: StringName):
		var key = str(property)
		if __items.has(key):
			return __items[key]
		return null
	
	# Enable for-in iteration
	func _iter_init(_arg) -> bool:
		return __items.size() > 0
	
	func _iter_next(_arg) -> bool:
		return false  # Only iterate once with keys()
	
	func _iter_get(_arg):
		return keys()

	func _to_string() -> String:
		return JSON.stringify(to_dictionary())

# =============================================================================
# ArraySchema Class
# =============================================================================

## Array collection that holds ordered items (schemas or primitives)
class ArraySchema extends RefCounted:
	## Internal: Stores items in order
	var __items: Array = []
	## Internal: The child type (class reference for schemas, or primitive type string)
	var __child_type = null
	## Internal: Reference ID
	var __ref_id: int = -1
	
	func _init(child_type = null):
		__child_type = child_type
	
	## Get the number of items
	func size() -> int:
		return __items.size()
	
	## Check if array is empty
	func is_empty() -> bool:
		return __items.is_empty()
	
	## Get item at index
	func at(index: int):
		if index >= 0 and index < __items.size():
			return __items[index]
		return null
	
	## Get first item
	func front():
		if __items.size() > 0:
			return __items[0]
		return null
	
	## Get last item
	func back():
		if __items.size() > 0:
			return __items[-1]
		return null
	
	## Internal: Set item at index (called by decoder)
	func _set_at(index: int, value) -> void:
		while __items.size() <= index:
			__items.append(null)
		__items[index] = value
	
	## Internal: Add item (called by decoder)
	func _push(value) -> void:
		__items.append(value)
	
	## Internal: Remove item at index (called by decoder)
	func _remove_at(index: int) -> void:
		if index >= 0 and index < __items.size():
			__items.remove_at(index)
	
	## Internal: Clear all items (called by decoder)
	func _clear() -> void:
		__items.clear()
	
	## Convert to array
	func to_array() -> Array:
		var result = []
		for value in __items:
			if value is Schema:
				result.append(value.to_dictionary())
			elif value is Map:
				result.append(value.to_dictionary())
			elif value is ArraySchema:
				result.append(value.to_array())
			else:
				result.append(value)
		return result
	
	# Allow array[index] access
	func _get(property: StringName):
		var prop_str = str(property)
		if prop_str.is_valid_int():
			var index = int(prop_str)
			if index >= 0 and index < __items.size():
				return __items[index]
		return null
	
	# Enable for-in iteration (iterates over items)
	var __iter_index: int = 0
	
	func _iter_init(_arg) -> bool:
		__iter_index = 0
		return __items.size() > 0
	
	func _iter_next(_arg) -> bool:
		__iter_index += 1
		return __iter_index < __items.size()
	
	func _iter_get(_arg):
		return __items[__iter_index]

	func _to_string() -> String:
		return JSON.stringify(to_array())

# =============================================================================
# Internal Polling Node — auto-added to scene tree, calls poll() every frame
# =============================================================================

class _Poller extends Node:
	func _process(_delta):
		Colyseus.poll()

# =============================================================================
# Utility Functions
# =============================================================================

## Check if a type string represents a primitive type
static func is_primitive_type(type_str: String) -> bool:
	return type_str in [Schema.STRING, Schema.NUMBER, Schema.BOOLEAN, Schema.INT8, Schema.UINT8, Schema.INT16, Schema.UINT16, Schema.INT32, Schema.UINT32, Schema.INT64, Schema.UINT64, Schema.FLOAT32, Schema.FLOAT64]

## Check if a type string represents a collection type
static func is_collection_type(type_str: String) -> bool:
	return type_str in [Schema.MAP, Schema.ARRAY]

## Get the default value for a primitive type
static func get_default_value(type_str: String):
	match type_str:
		Schema.STRING:
			return ""
		Schema.NUMBER, Schema.FLOAT32, Schema.FLOAT64:
			return 0.0
		Schema.BOOLEAN:
			return false
		Schema.INT8, Schema.UINT8, Schema.INT16, Schema.UINT16, Schema.INT32, Schema.UINT32, Schema.INT64, Schema.UINT64:
			return 0
		_:
			return null

# =============================================================================
# Client Wrapper — exposes .http and .auth sub-objects
# =============================================================================

## Wraps the native ColyseusClient to provide .http and .auth accessors
## matching the TypeScript SDK structure.
class Client extends RefCounted:
	## The native ColyseusClient GDExtension object
	var _native
	## HTTP sub-object for making HTTP requests
	var http: HTTP
	## Auth sub-object for token management
	var auth: Auth

	func _init(endpoint: String = ""):
		var class_name_str := &"_ColyseusClient"
		if ClassDB.class_exists(class_name_str):
			_native = ClassDB.instantiate(class_name_str)
		if not _native:
			push_error("Colyseus: ColyseusClient not available. Make sure the GDExtension is properly loaded.")
			return
		http = HTTP.new(_native)
		auth = Auth.new(_native)
		if endpoint != "":
			_native.set_endpoint(endpoint)
		if not Colyseus._poll_instance:
			Colyseus._poll_instance = _native
		Colyseus._ensure_polling()

	## Set the server endpoint (e.g., "ws://localhost:2567")
	func set_endpoint(endpoint: String) -> void:
		_native.set_endpoint(endpoint)
		# Reconnect signal handlers after endpoint change
		http._connected = false

	## Get the server endpoint
	func get_endpoint() -> String:
		return _native.get_endpoint()

	## Join or create a room
	func join_or_create(room_name: String, options: Dictionary = {}):
		var native_room = _native.join_or_create(room_name, JSON.stringify(options))
		return Room.new(native_room) if native_room else null

	## Create a new room
	func create(room_name: String, options: Dictionary = {}):
		var native_room = _native.create(room_name, JSON.stringify(options))
		return Room.new(native_room) if native_room else null

	## Join an existing room by name
	func join(room_name: String, options: Dictionary = {}):
		var native_room = _native.join(room_name, JSON.stringify(options))
		return Room.new(native_room) if native_room else null

	## Join a room by its ID
	func join_by_id(room_id: String, options: Dictionary = {}):
		var native_room = _native.join_by_id(room_id, JSON.stringify(options))
		return Room.new(native_room) if native_room else null

	## Reconnect to a room using a reconnection token
	func reconnect(reconnection_token: String):
		var native_room = _native.reconnect(reconnection_token)
		return Room.new(native_room) if native_room else null

# =============================================================================
# Room Wrapper — exposes signals and methods from native ColyseusRoom
# =============================================================================

## Wraps the native ColyseusRoom so users can type `var room: Colyseus.Room`.
class Room extends RefCounted:
	signal joined()
	signal state_changed()
	signal message_received(type: Variant, data: Variant)
	signal error(code: int, message: String)
	signal left(code: int, reason: String)

	var _native

	func _init(native_room):
		_native = native_room
		_native.joined.connect(func(): joined.emit())
		_native.state_changed.connect(func(): state_changed.emit())
		_native.message_received.connect(func(type, data): message_received.emit(type, data))
		_native.error.connect(func(code, msg): error.emit(code, msg))
		_native.left.connect(func(code, reason): left.emit(code, reason))

	func send_message(type, data = null):
		if data == null:
			_native.send_message(type)
		else:
			_native.send_message(type, data)

	func leave() -> void:
		_native.leave()

	func get_id() -> String:
		return _native.get_id()

	func get_session_id() -> String:
		return _native.get_session_id()

	func get_name() -> String:
		return _native.get_name()

	var connected: bool:
		get: return _native.is_connected()

	func get_state() -> Variant:
		return _native.get_state()

	func set_state_type(state_type) -> void:
		_native.set_state_type(state_type)

# =============================================================================
# HTTP — callback-based HTTP requests
# =============================================================================

## HTTP client for making requests to the Colyseus server.
## Note: "get" is renamed to "get_request" because Object.get() is reserved in Godot.
## Usage:
##   client.http.get_request("/test", func(err, data): print(data))
##   client.http.post("/save", {"key": "val"}, func(err, data): print(data))
class HTTP extends RefCounted:
	var _native
	var _callbacks: Dictionary = {}  # request_id -> Callable
	var _connected: bool = false

	func _init(native_client):
		_native = native_client

	func _ensure_signals():
		if not _connected and _native:
			_native._http_response.connect(_on_response)
			_native._http_error.connect(_on_error)
			_connected = true

	## Set the auth token (sent as Bearer header on all requests)
	var auth_token: String:
		get: return _native.auth_get_token() if _native else ""
		set(value):
			if _native:
				_native.auth_set_token(value)

	## GET request (named get_request to avoid conflict with Object.get)
	func get_request(path: String, callback: Callable) -> int:
		_ensure_signals()
		var rid = _native.http_get(path)
		_callbacks[rid] = callback
		return rid

	## POST request (body auto-converted to JSON if Dictionary/Array)
	func post(path: String, body, callback: Callable) -> int:
		_ensure_signals()
		var json_body = JSON.stringify(body) if (body is Dictionary or body is Array) else str(body)
		var rid = _native.http_post(path, json_body)
		_callbacks[rid] = callback
		return rid

	## PUT request
	func put(path: String, body, callback: Callable) -> int:
		_ensure_signals()
		var json_body = JSON.stringify(body) if (body is Dictionary or body is Array) else str(body)
		var rid = _native.http_put(path, json_body)
		_callbacks[rid] = callback
		return rid

	## DELETE request
	func delete(path: String, callback: Callable) -> int:
		_ensure_signals()
		var rid = _native.http_delete(path)
		_callbacks[rid] = callback
		return rid

	## PATCH request
	func patch(path: String, body, callback: Callable) -> int:
		_ensure_signals()
		var json_body = JSON.stringify(body) if (body is Dictionary or body is Array) else str(body)
		var rid = _native.http_patch(path, json_body)
		_callbacks[rid] = callback
		return rid

	func _on_response(request_id: int, status_code: int, body: String):
		if not _callbacks.has(request_id):
			return
		var callback = _callbacks[request_id]
		_callbacks.erase(request_id)
		# Parse JSON body
		var data = null
		var json = JSON.new()
		if json.parse(body) == OK:
			data = json.data
		else:
			data = body
		callback.call(null, data)

	func _on_error(request_id: int, code: int, message: String):
		if not _callbacks.has(request_id):
			return
		var callback = _callbacks[request_id]
		_callbacks.erase(request_id)
		callback.call({"code": code, "message": message}, null)

# =============================================================================
# Auth — token management
# =============================================================================

## Auth module for managing authentication tokens.
## Usage:
##   client.auth.set_token("my-jwt-token")
##   var token = client.auth.get_token()
class Auth extends RefCounted:
	var _native

	func _init(native_client):
		_native = native_client

	## Set the auth token (sent as Bearer header)
	func set_token(token: String) -> void:
		_native.auth_set_token(token)

	## Get the current auth token
	func get_token() -> String:
		return _native.auth_get_token()