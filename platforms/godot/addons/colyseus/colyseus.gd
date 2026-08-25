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
		var replies := _Replies.new(_native)
		http = HTTP.new(_native, replies)
		auth = Auth.new(_native, replies)
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

	## Re-take a seat using the token from [method Room.get_reconnection_token]
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
	signal dropped(code: int, reason: String)
	signal reconnected()

	var _native

	func _init(native_room):
		_native = native_room
		_native.joined.connect(func(): joined.emit())
		_native.state_changed.connect(func(): state_changed.emit())
		_native.message_received.connect(func(type, data): message_received.emit(type, data))
		_native.error.connect(func(code, msg): error.emit(code, msg))
		_native.left.connect(func(code, reason): left.emit(code, reason))
		_native.dropped.connect(func(code, reason): dropped.emit(code, reason))
		_native.reconnected.connect(func(): reconnected.emit())

	func send_message(type, data = null):
		# Native method is registered with two required args (type, data) and
		# decoded via call_vararg; always pass both, using a null variant for
		# empty payloads.
		_native.send_message(type, data)

	func leave() -> void:
		_native.leave()

	func get_id() -> String:
		return _native.get_id()

	func get_session_id() -> String:
		return _native.get_session_id()

	## Token for [method Client.reconnect]. Persist it to re-take this seat
	## after the process is killed (the server must [code]allowReconnection()[/code]).
	func get_reconnection_token() -> String:
		return _native.get_reconnection_token()

	func get_name() -> String:
		return _native.get_name()

	var connected: bool:
		get: return _native.is_connected()

	var reconnecting: bool:
		get: return _native.is_reconnecting()

	## Tune automatic reconnection. Pass any subset of the following keys:
	##   enabled: bool, max_retries: int, min_delay_ms: int, max_delay_ms: int,
	##   min_uptime_ms: int, delay_ms: int, max_enqueued_messages: int.
	## Omitted keys keep their current value. Defaults match the @colyseus/sdk
	## TypeScript SDK.
	func set_reconnection_options(options: Dictionary) -> void:
		_native.set_reconnection_options(options)

	func get_state() -> Variant:
		return _native.get_state()

	func set_state_type(state_type) -> void:
		_native.set_state_type(state_type)

	var _input_handle: InputHandle = null
	var _clock: Clock = null

	## The per-room input handle: stage fields on `.data`, then `.send()`.
	## The input schema comes from the server's handshake (INPUT_REFLECTION) —
	## GDScript declares nothing. Returns the same handle on later calls.
	## Null until the room has joined and the server declared defineInput().
	func input() -> InputHandle:
		if _input_handle == null:
			var native_handle = _native.input()
			if native_handle == null:
				return null
			_input_handle = InputHandle.new(native_handle)
		return _input_handle

	## Server-time + RTT estimator readouts (the SDK's room clock).
	var clock: Clock:
		get:
			if _clock == null:
				_clock = Clock.new(_native)
			return _clock

	## Latency injector at the transport seam. Both numbers are ROUND TRIPS,
	## split evenly across the two directions, so `delay_ms` is what
	## clock.smoothed_rtt() converges to — the same meaning the JS SDK's
	## __net() has. Never reorders; the handshake is never delayed (call
	## after join). Call net_pump() once per frame, right after
	## Colyseus.poll(), or delayed packets never deliver.
	func set_latency(delay_ms: float, jitter_ms := 0.0) -> void:
		_native.set_latency(delay_ms, jitter_ms)

	func net_pump() -> void:
		_native.net_pump()

	var net_in_flight: int:
		get: return _native.net_in_flight()

	## Kill the socket UNCLEANLY (close code 4010): the SDK sees a drop, not
	## a leave, and auto-reconnects — `dropped` then `reconnected` fire, the
	## input handle resets (epoch bump -> reconcilers self-reset), and state
	## re-decodes (rebind instances in your reconnect handler). The room must
	## be up past the reconnection min-uptime or the SDK gives up instead.
	## Native only — web has no auto-reconnect. Re-apply set_latency after
	## reconnect: the fresh transport is unwrapped.
	func drop() -> void:
		_native.drop_transport()

# =============================================================================
# Input — the per-room input handle (predict layer, phase 1)
# =============================================================================

## Staged input fields. Assign like plain properties — `input.data.move_x = 1`
## — each assignment lands in the C-side instance the encoder reads at send().
class InputData extends RefCounted:
	var _native

	func _init(native_handle):
		_native = native_handle

	func _set(property: StringName, value) -> bool:
		_native.set_field(String(property), float(value))
		return true

	func _get(property: StringName):
		return _native.get_field(String(property))

## Mutate `.data`, then `send()` — which delta-encodes and transmits one input
## and returns its 1-based seq (0 = nothing sent). See input_handle.h for the
## wire contract.
class InputHandle extends RefCounted:
	var _native
	var data: InputData

	func _init(native_handle):
		_native = native_handle
		data = InputData.new(native_handle)

	func send() -> int:
		return _native.send()

	## Reset encoder + round-trip state (the SDK calls this on reconnect).
	func reset() -> void:
		_native.reset()

	var pending_count: int:
		get: return _native.pending_count()

	var last_processed: int:
		get: return _native.last_processed()

	var sent_count: int:
		get: return _native.sent_count()

	var epoch: int:
		get: return _native.epoch()

	var tick_rate: int:
		get: return _native.tick_rate()

	var patch_rate: int:
		get: return _native.patch_rate()

	## Lag-comp render delay (ms) — the predict layer binds this automatically
	## from its lerp delay; set by hand only when interpolating outside it.
	var render_delay: float:
		get: return _native.render_delay()
		set(value): _native.set_render_delay(value)

	## Stamp lag-comp rewind times ONLY on inputs whose named field is truthy
	## (e.g. "fire") — movement inputs skip the extra wire bytes. Equivalent
	## to the JS SDK's allowRewind option.
	func set_rewind_field(field: String) -> void:
		_native.set_rewind_field(field)

## Room clock readouts — all milliseconds on the axes the SDK maintains.
class Clock extends RefCounted:
	var _native

	func _init(native_room):
		_native = native_room

	func now() -> float: return _native.clock_now()
	func server_now() -> float: return _native.clock_server_now()
	func render_now() -> float: return _native.clock_render_now()
	func rtt() -> float: return _native.clock_rtt()
	func smoothed_rtt() -> float: return _native.clock_smoothed_rtt()
	func jitter() -> float: return _native.clock_jitter()
	func last_server_time() -> float: return _native.clock_last_server_time()
	func patch_interval() -> float: return _native.clock_patch_interval()

# =============================================================================
# Predict — passive smoothing of the server stream (predict layer, phase 2)
# =============================================================================

## Smoothed reads over decoded entities you DON'T control. One read idiom:
## `predict.value(instance, "x")` — lerp / damped / extrapolate / raw per
## attached field, raw fallback when untracked, NAN for unknown fields.
##
##   var predict = Colyseus.Predict.of(room)
##   predict.attach_all("players", {
##       "x": Colyseus.Predict.DAMPED,
##       "y": { "mode": Colyseus.Predict.LERP, "delay": 100 },
##   }, room.get_session_id())
##   predict.tick(now_ms)                # once per frame; returns input steps due
##   var x = predict.value(player, "x")
class Predict extends RefCounted:
	const LERP := 0
	const EXTRAPOLATE := 1
	const DAMPED := 2
	const RECKON := 3
	const RAW := 4

	var _native
	var _room_native

	## A FRESH Predict over the room (Predictor.ts's Predict.For) — several can
	## coexist, each with its own smoothing curves.
	static func of(room) -> Predict:
		var p = Predict.new()
		p._native = room._native.predict()
		p._room_native = room._native
		return p

	## Per-field config: a bare mode constant, or a Dictionary with any of
	## mode / delay / smooth_ms / max_extrapolate / snap / angle (0 = default).
	func attach(instance, config: Dictionary) -> void:
		for field in config:
			var o = _opts(config[field])
			_native.attach_field(instance, field, o.mode, o.delay, o.smooth_ms,
				o.max_extrapolate, o.snap, o.angle)

	## Track EVERY entry of a state collection — present now or arriving later —
	## and stop as entries are removed. `except_key` skips one map key (yours).
	func attach_all(collection: String, config: Dictionary, except_key := "") -> void:
		for field in config:
			var o = _opts(config[field])
			_native.attach_all_field(collection, field, o.mode, o.delay, o.smooth_ms,
				o.max_extrapolate, o.snap, o.angle, except_key)

	func detach(instance) -> void:
		_native.detach(instance)

	## Dead-reckon `fields` of one instance through a step SHARED with the
	## server: `step.call(state, dt, elapsed_ms)` forwards a scratch copy from
	## the latest snapshot to the present. Opts: smooth_ms / substep_ms / snap.
	func attach_reckon(instance, fields: Array, step: Callable, opts: Dictionary = {}) -> void:
		_native.attach_reckon(instance, fields, step,
			float(opts.get("smooth_ms", 0.0)),
			float(opts.get("substep_ms", 0.0)),
			float(opts.get("snap", 0.0)))

	## As attach_all, but dead-reckons every entry through the shared step.
	func attach_all_reckon(collection: String, fields: Array, step: Callable, opts: Dictionary = {}) -> void:
		_native.attach_all_reckon(collection, fields, step,
			float(opts.get("smooth_ms", 0.0)),
			float(opts.get("substep_ms", 0.0)),
			float(opts.get("snap", 0.0)))

	## Advance one render frame. RETURNS the fixed input steps due — send
	## exactly one input per returned step to stay on the server's cadence.
	##
	## Leave `now_ms` off to read the SDK clock, which is what the JS reference
	## does with its performance.now() default. Clock readings are never
	## negative, so the sentinel cannot collide with a real timestamp.
	func tick(now_ms: float = -1.0) -> int:
		if now_ms < 0.0:
			now_ms = _room_native.clock_now()
		return _native.tick(now_ms)

	func value(instance, field: String) -> float:
		return _native.value(instance, field)

	## RAW reckoned value at a server-time instant — for lag-comp hit tests.
	func value_at(instance, field: String, time_ms: float) -> float:
		return _native.value_at(instance, field, time_ms)

	## Server-reconciled rollback for the entity YOU control. The step is the
	## same deterministic function the server runs, written in GDScript — it
	## receives (ctx, state, cmd) where `state` is the predicted mirror
	## (mutate it: `state.x += state.vx * ctx.dt`) and `cmd` the input being
	## applied. Options: input (InputHandle), fields (Array[String]),
	## smooth_ms (-1 = default), snap (0 = off), step (Callable).
	func reconciler(instance, opts: Dictionary) -> Reconciler:
		var input = opts.get("input")
		var native = _native.reconciler(
			instance,
			input._native if input != null else null,
			opts.get("fields", []),
			float(opts.get("smooth_ms", -1.0)),
			float(opts.get("snap", 0.0)),
			opts.get("step"))
		if native == null:
			return null
		var r = Reconciler.new()
		r._native = native
		return r

	## The COMPOSITE face: one rollback over a world of named parts, all
	## predicted through your inputs in the server's step order. `world` maps
	## part names to DECODED instances; the step receives the mirrors as
	## `w.<name>` (`w.paddle.x += ...`, `w.puck.vx = ...`). Bound poses read
	## back via predict.value(instance, field); reconciler.value("part.field")
	## is the low-level escape hatch.
	func sim(opts: Dictionary) -> Reconciler:
		var input = opts.get("input")
		var native = _native.sim(
			opts.get("world", {}),
			input._native if input != null else null,
			float(opts.get("smooth_ms", -1.0)),
			float(opts.get("snap", 0.0)),
			opts.get("step"))
		if native == null:
			return null
		var r = Reconciler.new()
		r._native = native
		return r

	## A typed optimistic-event channel: predict from inside a reconciler step
	## (`ctx.predict(channel, "goal")` — live-only, replay-safe) or from UI
	## (`channel.predict("goal")`); confirm on the authoritative signal;
	## unconfirmed sim-born predictions auto-reject after `grace_ticks`.
	## Callbacks receive the event key.
	func define_event(opts: Dictionary = {}) -> EventChannel:
		var native = _native.define_event(
			opts.get("on_predict"),
			opts.get("on_confirm"),
			opts.get("on_reject"),
			int(opts.get("grace_ticks", 0)),
			float(opts.get("ttl_ms", 0.0)),
			float(opts.get("cooldown_ms", 0.0)))
		if native == null:
			return null
		var ch = EventChannel.new()
		ch._native = native
		return ch

	## Predicted spawns for a state collection: optimistic LOCALS (plain
	## Dictionaries) correlate with the server's entities on arrival — one
	## logical entry, one stable id, no visual seam.
	##   opts: owned (Callable(server)->bool), spawn_time (Callable(server)->
	##   born_ms — enables the measured input lead), step (Callable(local, dt)),
	##   ttl_ms (0 = max(2·rtt, 600)),
	##   fields (Array[String]) + reckon_step (Callable(state, dt, elapsed_ms))
	##   — dead-reckon CONFIRMED entities by snapshot age + measured lead, so
	##   the handoff doesn't snap back by lead x velocity.
	func spawns(collection: String, opts: Dictionary = {}) -> Spawns:
		var native = _native.spawns(
			collection,
			opts.get("owned"),
			opts.get("spawn_time"),
			opts.get("step"),
			float(opts.get("ttl_ms", 0.0)),
			opts.get("fields", []),
			opts.get("reckon_step"))
		if native == null:
			return null
		var s = Spawns.new()
		s._native = native
		return s

	class _Opts:
		var mode := 0
		var delay := 0.0
		var smooth_ms := 0.0
		var max_extrapolate := 0.0
		var snap := 0.0
		var angle := false

	static func _opts(entry) -> _Opts:
		var o := _Opts.new()
		if entry is int:
			o.mode = entry
		elif entry is Dictionary:
			o.mode = int(entry.get("mode", LERP))
			o.delay = float(entry.get("delay", 0.0))
			o.smooth_ms = float(entry.get("smooth_ms", 0.0))
			o.max_extrapolate = float(entry.get("max_extrapolate", 0.0))
			o.snap = float(entry.get("snap", 0.0))
			o.angle = bool(entry.get("angle", false))
		return o

## Predicted-spawn store — born from Colyseus.Predict.spawns().
class Spawns extends RefCounted:
	var _native

	## Record an optimistic local (a Dictionary); returns its stable id.
	func spawn(local: Dictionary) -> int:
		return _native.spawn(local)

	## Render value across the handoff: the local's field while pending, the
	## authoritative instance's after correlation.
	func value(id: int, field: String) -> float:
		return _native.value(id, field)

	## A string field off the CONFIRMED server instance ("" while pending).
	func server_string(id: int, field: String) -> String:
		return _native.server_string(id, field)

	## Entries in insertion order: [{id, confirmed, lead_ms, has_local}].
	func entries() -> Array:
		return _native.entries()

	var size: int:
		get: return _native.size()

	func clear() -> void:
		_native.clear()

## Optimistic events — born from Colyseus.Predict.define_event().
class EventChannel extends RefCounted:
	var _native

	## UI-born prediction (wall-clock TTL settlement). False when dropped.
	func predict(key: String) -> bool:
		return _native.predict_ui(key)

	## The server agreed: settle `key` ("" = every pending). Returns the count.
	func confirm(key := "") -> int:
		return _native.confirm(key)

	## The server overruled ("" = every pending).
	func reject(key := "") -> int:
		return _native.reject(key)

	var pending_count: int:
		get: return _native.pending_count()

	func clear() -> void:
		_native.clear()

## The rollback controller for the entity you control — born from
## Colyseus.Predict.reconciler(). See that method for the step contract.
class Reconciler extends RefCounted:
	var _native

	## Rendered value: predicted state + the decaying correction offset.
	func value(field: String) -> float:
		return _native.value(field)

	## The TRUE predicted state (the mirror view) — read for game logic.
	var state: Variant:
		get: return _native.state()

	## The composite face's part views (`world.paddle`); null on the flat face.
	var world: Variant:
		get: return _native.world()

	var pending_count: int:
		get: return _native.pending_count()

	var reconcile_seq: int:
		get: return _native.reconcile_seq()

	var last_correction_mag: float:
		get: return _native.last_correction_mag()

	var drift_ema: float:
		get: return _native.drift_ema()

	## Re-seed from the authoritative instance; drops offsets and the
	## in-flight window. Call from on_reconnect.
	func reset() -> void:
		_native.reset()

# =============================================================================
# HTTP — callback-based HTTP requests
# =============================================================================

## HTTP client for making requests to the Colyseus server.
## Note: "get" is renamed to "get_request" because Object.get() is reserved in Godot.
## Usage:
##   client.http.get_request("/test", func(err, data): print(data))
##   client.http.post("/save", {"key": "val"}, func(err, data): print(data))
## Routes `_http_response` / `_http_error` back to the Callable that started the
## request.
##
## HTTP and Auth share ONE of these per client: both dispatch through the same
## native queue and draw their request ids from the same counter, so a second
## router would receive — and have to ignore — the other's replies.
class _Replies extends RefCounted:
	var _callbacks: Dictionary = {}  # request_id -> Callable

	func _init(native):
		if native:
			native._http_response.connect(_on_response)
			native._http_error.connect(_on_error)

	## Remembers `callback` for `request_id`, and hands the id straight back so
	## a dispatch reads as one line.
	func track(request_id: int, callback: Callable) -> int:
		if request_id != 0 and callback.is_valid():
			_callbacks[request_id] = callback
		return request_id

	func _take(request_id: int) -> Callable:
		if not _callbacks.has(request_id):
			return Callable()
		var callback: Callable = _callbacks[request_id]
		_callbacks.erase(request_id)
		return callback

	func _on_response(request_id: int, _status_code: int, body: String) -> void:
		var callback := _take(request_id)
		if not callback.is_valid():
			return
		var json := JSON.new()
		callback.call(null, json.data if json.parse(body) == OK else body)

	func _on_error(request_id: int, code: int, message: String) -> void:
		var callback := _take(request_id)
		if callback.is_valid():
			callback.call({ "code": code, "message": message }, null)


class HTTP extends RefCounted:
	var _native
	var _replies: _Replies

	func _init(native_client, replies: _Replies):
		_native = native_client
		_replies = replies

	## Set the auth token (sent as Bearer header on all requests)
	var auth_token: String:
		get: return _native.auth_get_token() if _native else ""
		set(value):
			if _native:
				_native.auth_set_token(value)

	## GET request (named get_request to avoid conflict with Object.get)
	func get_request(path: String, callback: Callable) -> int:
		return _replies.track(_native.http_get(path), callback)

	## POST request (body auto-converted to JSON if Dictionary/Array)
	func post(path: String, body, callback: Callable) -> int:
		return _replies.track(_native.http_post(path, _json(body)), callback)

	## PUT request
	func put(path: String, body, callback: Callable) -> int:
		return _replies.track(_native.http_put(path, _json(body)), callback)

	## DELETE request
	func delete(path: String, callback: Callable) -> int:
		return _replies.track(_native.http_delete(path), callback)

	## PATCH request
	func patch(path: String, body, callback: Callable) -> int:
		return _replies.track(_native.http_patch(path, _json(body)), callback)

	## Dictionaries and Arrays are encoded; anything else goes as its string
	## form, so a caller can pass a pre-built JSON body verbatim.
	func _json(body) -> String:
		return JSON.stringify(body) if (body is Dictionary or body is Array) else str(body)

# =============================================================================
# Auth — token management
# =============================================================================

## Auth module for managing authentication tokens.
## Usage:
##   client.auth.set_token("my-jwt-token")
##   var token = client.auth.get_token()
class Auth extends RefCounted:
	## Mirrors gdext_auth_op_t in src/godot_colyseus.h — the order is the ABI.
	enum _Op { GET_USER_DATA = 0, REGISTER = 1, SIGN_IN = 2, SIGN_IN_ANONYMOUS = 3, SEND_PASSWORD_RESET = 4 }

	var _native
	var _replies: _Replies

	func _init(native_client, replies: _Replies):
		_native = native_client
		_replies = replies

	## Set the auth token (sent as Bearer header on every later request)
	func set_token(token: String) -> void:
		_native.auth_set_token(token)

	## Get the current auth token, or "" when signed out
	func get_token() -> String:
		return _native.auth_get_token()

	## Sign in without credentials. The token still identifies the player, so
	## keep it if you want them back on the same account next launch.
	func sign_in_anonymously(callback: Callable, options: Dictionary = {}) -> int:
		return _request(_Op.SIGN_IN_ANONYMOUS, "", "", callback, options)

	## Create an account. `options` is merged into the request body.
	func register_with_email_and_password(email: String, password: String,
			callback: Callable, options: Dictionary = {}) -> int:
		return _request(_Op.REGISTER, email, password, callback, options)

	func sign_in_with_email_and_password(email: String, password: String,
			callback: Callable) -> int:
		return _request(_Op.SIGN_IN, email, password, callback)

	## The user record behind the current token. Fails when there is none.
	func get_user_data(callback: Callable) -> int:
		return _request(_Op.GET_USER_DATA, "", "", callback)

	func send_password_reset_email(email: String, callback: Callable) -> int:
		return _request(_Op.SEND_PASSWORD_RESET, email, "", callback)

	## Drop the token locally and clear it from secure storage. No request.
	func sign_out() -> void:
		_native.auth_signout()

	## Every call answers the same way an HTTP one does — `callback(err, data)`,
	## where a successful `data` is `{ "user": {...}, "token": "..." }`, the
	## shape the server replied with.
	func _request(op: int, email: String, password: String, callback: Callable,
			options: Dictionary = {}) -> int:
		var options_json := JSON.stringify(options) if not options.is_empty() else ""
		return _replies.track(
			_native.auth_request(op, email, password, options_json), callback)