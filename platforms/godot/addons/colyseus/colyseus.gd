class_name Colyseus
extends RefCounted
## Colyseus SDK for Godot
##
## This provides platform-aware client creation.
## On native platforms, it uses the GDExtension (ColyseusClient).
## On web platform, it uses the JavaScript SDK bridge (ColyseusWebClient).
##
## Usage:
##   var client = Colyseus.create_client()
##   client.set_endpoint("ws://localhost:2567")
##   var room = client.join_or_create("my_room")
##   var callbacks = Colyseus.get_callbacks(room)

## Check if running on web platform
static func is_web() -> bool:
	return OS.has_feature("web")

## Create a new Colyseus client (platform-aware)
static func create_client() -> Variant:
	if is_web():
		# Web platform - use JavaScript SDK bridge
		var web_client_script = load("res://addons/colyseus/web/colyseus_web_client.gd")
		if web_client_script:
			return web_client_script.new()
		push_error("Colyseus: Could not load web client script")
		return null
	else:
		# Native platform - use GDExtension via ClassDB
		var class_name_str := &"ColyseusClient"
		if ClassDB.class_exists(class_name_str):
			return ClassDB.instantiate(class_name_str)
		push_error("Colyseus: Native ColyseusClient not available")
		return null

## Get callbacks for a room (platform-aware)
static func callbacks(room) -> Variant:
	if is_web():
		# Web platform - use JavaScript SDK bridge
		var web_callbacks_script = load("res://addons/colyseus/web/colyseus_web_callbacks.gd")
		if web_callbacks_script:
			return web_callbacks_script.get_for_room(room)
		push_error("Colyseus: Could not load web callbacks script")
		return null
	else:
		# Native platform - use GDExtension
		# Call the static get() method via Object.call_static()
		var class_name_str := &"ColyseusCallbacks"
		if ClassDB.class_exists(class_name_str):
			# Create instance and call the static-like factory method
			var instance = ClassDB.instantiate(class_name_str)
			if instance and instance.has_method(&"_init_with_room"):
				instance._init_with_room(room)
				return instance
			# Try calling get as if it were bound to instance
			if instance and instance.has_method(&"get"):
				return instance.get(room)
			# Fallback: return the instance and let user call methods
			return instance
		push_error("Colyseus: Native ColyseusCallbacks not available")
		return null

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