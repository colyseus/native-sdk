class_name ColyseusWebCallbacks
extends RefCounted
## Colyseus Web Callbacks - JavaScript SDK Bridge (0.17 API)
##
## Provides state change listening functionality for web exports.
## Uses getRawChanges for efficient schema synchronization.

# Value type constants (must match colyseus_bridge.js)
const VALUE_UNDEFINED = 0
const VALUE_PRIMITIVE = 1
const VALUE_REF = 2
const VALUE_UNKNOWN = 3

# Array indices for change entries (must match colyseus_bridge.js)
const IDX_REF_ID = 0
const IDX_OP = 1
const IDX_FIELD = 2
const IDX_DYNAMIC_INDEX = 3
const IDX_IS_SCHEMA = 4
const IDX_VAL_TYPE = 5
const IDX_VAL_DATA = 6
const IDX_PREV_TYPE = 7
const IDX_PREV_DATA = 8

# Operation constants (from colyseus.js)
const OP_ADD = 128
const OP_REPLACE = 0
const OP_DELETE = 64
const OP_DELETE_AND_ADD = 192  # DELETE | ADD

var _room  # ColyseusWebRoom
var _js_room_id: int = -1
var _colyseus_godot: JavaScriptObject
var _callbacks: Array = []  # Keep JavaScriptObject references alive
var _raw_changes_callback: JavaScriptObject = null

# Schema instance registry: refId -> Schema/Map/ArraySchema instance
var _schema_registry: Dictionary = {}

# Type registry: refId -> schema class (for type inference)
var _type_registry: Dictionary = {}

# Callback registry: refId -> { field_or_op -> [Callable] }
# For schemas: field name -> callbacks for that field
# For collections: OP_ADD/OP_DELETE/OP_REPLACE -> callbacks
var _callback_registry: Dictionary = {}

# Root state type (set via room.set_state_type)
var _state_type = null

# Next handle ID for callback registration
var _next_handle: int = 1

# Handle -> callback info mapping (for remove support)
var _handle_to_callback: Dictionary = {}

## Factory method to get callbacks for a room
static func get_for_room(room) -> ColyseusWebCallbacks:
	var callbacks = ColyseusWebCallbacks.new()
	callbacks._room = room
	callbacks._js_room_id = room._js_room_id
	callbacks._colyseus_godot = JavaScriptBridge.get_interface("ColyseusGodot")
	callbacks._state_type = room._state_type
	callbacks._setup_raw_changes()
	
	# Set reference on room so get_state() can access synchronized state
	if room.has_method("_set_state_callbacks"):
		room._set_state_callbacks(callbacks)
	
	return callbacks

## Setup the raw changes callback with JavaScript
func _setup_raw_changes() -> void:
	if _js_room_id < 0 or not _colyseus_godot:
		push_error("ColyseusWebCallbacks: Room not connected")
		return
	
	# Initialize root state in registry if state type is set
	if _state_type != null:
		var root_state = _state_type.new()
		root_state.__ref_id = 0
		_schema_registry[0] = root_state
		_type_registry[0] = _state_type
		print("[DEBUG] Initialized root state with refId 0, type: ", _state_type)
	
	# Create JavaScript callback for raw changes
	_raw_changes_callback = JavaScriptBridge.create_callback(func(args: Array):
		_on_raw_changes(args)
	)
	_callbacks.append(_raw_changes_callback)
	
	# Register with JavaScript bridge
	_colyseus_godot.setupRawChanges(_js_room_id, _raw_changes_callback)
	print("[DEBUG] Raw changes callback registered")

## Get the root state instance
func get_state():
	return _schema_registry.get(0)

## Get a schema instance by refId
func get_instance(ref_id: int):
	return _schema_registry.get(ref_id)

## Listen to property changes on the root state or an entity
## Usage: callbacks.listen("propertyName", callback) - for root state properties
## Or: callbacks.listen(entity, "propertyName", callback) - for entity properties
func listen(target, property_or_callback, callback = null) -> int:
	var handle = _next_handle
	_next_handle += 1
	
	var ref_id: int
	var field_name: String
	var cb: Callable
	
	if callback == null:
		# listen("property", callback) form - root state property
		ref_id = 0
		field_name = str(target)
		cb = property_or_callback
	else:
		# listen(entity, "property", callback) form - entity property
		field_name = str(property_or_callback)
		cb = callback
		
		# Get refId from entity
		ref_id = _get_ref_id(target)
		if ref_id < 0:
			push_error("ColyseusWebCallbacks: Invalid entity reference")
			return -1
	
	print("[DEBUG] listen() - registering for refId:", ref_id, " field:", field_name)
	
	# Register callback in local registry
	_register_callback(ref_id, field_name, cb, handle)
	
	return handle

## Listen to additions on a collection (Map or Array)
## Usage: callbacks.on_add("collectionName", callback) - for root state collections
## Or: callbacks.on_add(entity, "collectionName", callback) - for entity collections
func on_add(target, property_or_callback, callback = null) -> int:
	var handle = _next_handle
	_next_handle += 1
	
	var ref_id: int
	var field_name: String
	var cb: Callable
	
	if callback == null:
		# on_add("collection", callback) form - root state collection
		ref_id = 0
		field_name = str(target)
		cb = property_or_callback
	else:
		# on_add(entity, "collection", callback) form - entity collection
		field_name = str(property_or_callback)
		cb = callback
		
		# Get refId from entity
		ref_id = _get_ref_id(target)
		if ref_id < 0:
			push_error("ColyseusWebCallbacks: Invalid entity reference")
			return -1
	
	print("[DEBUG] on_add() - registering for refId:", ref_id, " field:", field_name, " handle:", handle)
	
	# We need to register on the collection itself, not the parent
	# The collection's refId will be discovered when we process changes
	# For now, store pending registration with parent info
	_register_collection_callback(ref_id, field_name, OP_ADD, cb, handle)
	
	print("[DEBUG] on_add() - callback_registry after registration: ", _callback_registry)
	
	return handle

## Listen to removals on a collection (Map or Array)
## Usage: callbacks.on_remove("collectionName", callback) - for root state collections
## Or: callbacks.on_remove(entity, "collectionName", callback) - for entity collections
func on_remove(target, property_or_callback, callback = null) -> int:
	var handle = _next_handle
	_next_handle += 1
	
	var ref_id: int
	var field_name: String
	var cb: Callable
	
	if callback == null:
		# on_remove("collection", callback) form - root state collection
		ref_id = 0
		field_name = str(target)
		cb = property_or_callback
	else:
		# on_remove(entity, "collection", callback) form - entity collection
		field_name = str(property_or_callback)
		cb = callback
		
		# Get refId from entity
		ref_id = _get_ref_id(target)
		if ref_id < 0:
			push_error("ColyseusWebCallbacks: Invalid entity reference")
			return -1
	
	print("[DEBUG] on_remove() - registering for refId:", ref_id, " field:", field_name)
	
	_register_collection_callback(ref_id, field_name, OP_DELETE, cb, handle)
	
	return handle

## Remove a callback by handle
func remove(handle: int) -> void:
	if _handle_to_callback.has(handle):
		var info = _handle_to_callback[handle]
		var ref_id: int = info["ref_id"]
		var key = info["key"]
		
		if _callback_registry.has(ref_id) and _callback_registry[ref_id].has(key):
			var callbacks_list: Array = _callback_registry[ref_id][key]
			for i in range(callbacks_list.size() - 1, -1, -1):
				if callbacks_list[i]["handle"] == handle:
					callbacks_list.remove_at(i)
					break
		
		_handle_to_callback.erase(handle)

## Extract refId from various entity types
func _get_ref_id(entity) -> int:
	if entity is Dictionary and entity.has("__ref_id"):
		return int(entity["__ref_id"])
	elif entity is ColyseusSchema.Schema:
		return entity.__ref_id
	elif entity is ColyseusSchema.Map:
		return entity.__ref_id
	elif entity is ColyseusSchema.ArraySchema:
		return entity.__ref_id
	return -1

## Register a field callback in the local registry
func _register_callback(ref_id: int, field_name: String, cb: Callable, handle: int) -> void:
	if not _callback_registry.has(ref_id):
		_callback_registry[ref_id] = {}
	
	if not _callback_registry[ref_id].has(field_name):
		_callback_registry[ref_id][field_name] = []
	
	_callback_registry[ref_id][field_name].append({
		"callback": cb,
		"handle": handle
	})
	
	_handle_to_callback[handle] = {
		"ref_id": ref_id,
		"key": field_name
	}

## Register a collection callback (on_add/on_remove)
## These are registered on the parent and transferred to the collection when discovered
func _register_collection_callback(parent_ref_id: int, field_name: String, op: int, cb: Callable, handle: int) -> void:
	# Key format: "field_name:OP" to distinguish from field callbacks
	var key = "%s:%d" % [field_name, op]
	
	if not _callback_registry.has(parent_ref_id):
		_callback_registry[parent_ref_id] = {}
	
	if not _callback_registry[parent_ref_id].has(key):
		_callback_registry[parent_ref_id][key] = []
	
	_callback_registry[parent_ref_id][key].append({
		"callback": cb,
		"handle": handle,
		"op": op,
		"field": field_name
	})
	
	_handle_to_callback[handle] = {
		"ref_id": parent_ref_id,
		"key": key
	}

## Extract result ID from callback args
func _extract_result_id(args: Array) -> int:
	if args.size() == 0:
		return -1
	var arg = args[0]
	if arg is int:
		return arg
	if arg is float:
		return int(arg)
	var str_val = str(arg)
	if str_val.is_valid_int():
		return int(str_val)
	return -1

## Handle raw changes callback from JavaScript
func _on_raw_changes(args: Array) -> void:
	print("[DEBUG] _on_raw_changes called with args: ", args)
	var result_id = _extract_result_id(args)
	print("[DEBUG] Extracted result_id: ", result_id)
	if result_id < 0 or not _colyseus_godot:
		print("[DEBUG] Invalid result_id or no _colyseus_godot")
		return
	
	var json_str = str(_colyseus_godot.getResult(result_id))
	print("[DEBUG] JSON string length: ", json_str.length())
	var changes = JSON.parse_string(json_str)
	
	if changes is Array:
		print("[DEBUG] Processing ", changes.size(), " changes")
		_process_raw_changes(changes)
	else:
		print("[DEBUG] Changes is not an array: ", typeof(changes))

## Process all raw changes from the batch
func _process_raw_changes(changes: Array) -> void:
	print("[DEBUG] _process_raw_changes - schema_registry keys: ", _schema_registry.keys())
	print("[DEBUG] _process_raw_changes - callback_registry: ", _callback_registry)
	
	for entry in changes:
		if not entry is Array or entry.size() < 9:
			print("[DEBUG] Skipping invalid entry: ", entry)
			continue
		
		var ref_id: int = int(entry[IDX_REF_ID])
		var op: int = int(entry[IDX_OP])
		var field = entry[IDX_FIELD]
		var field_str: String = str(field) if field != null else ""
		var dynamic_index = entry[IDX_DYNAMIC_INDEX]
		var is_schema: bool = int(entry[IDX_IS_SCHEMA]) == 1
		var val_type: int = int(entry[IDX_VAL_TYPE])
		var val_data = entry[IDX_VAL_DATA]
		var prev_type: int = int(entry[IDX_PREV_TYPE])
		var prev_data = entry[IDX_PREV_DATA]
		
		print("[DEBUG] Processing change - refId:", ref_id, " op:", op, " field:", field_str, " dynamicIndex:", dynamic_index, " isSchema:", is_schema, " valType:", val_type)
		
		# Get the target instance (parent that owns this field)
		var target = _schema_registry.get(ref_id)
		if target == null:
			print("[DEBUG] Target not found in registry for refId: ", ref_id)
			continue
		
		print("[DEBUG] Found target: ", target)
		
		# If value is a ref, ensure the child instance exists
		if val_type == VALUE_REF and val_data != null:
			var child_ref_id: int = int(val_data)
			if not _schema_registry.has(child_ref_id):
				print("[DEBUG] Creating child instance for refId: ", child_ref_id)
				_create_child_instance(target, field_str, child_ref_id, is_schema)
		
		# Apply the change
		if is_schema:
			_apply_schema_change(target, field_str, op, val_type, val_data, prev_type, prev_data)
		else:
			_apply_collection_change(target, field_str, dynamic_index, op, val_type, val_data, prev_type, prev_data)
		
		# Dispatch callbacks
		_dispatch_callbacks(ref_id, field_str, dynamic_index, op, val_type, val_data, prev_type, prev_data, is_schema)

## Create a child instance based on parent's field definition
func _create_child_instance(parent, field_name: String, child_ref_id: int, parent_is_schema: bool) -> void:
	print("[DEBUG] _create_child_instance - parent:", parent, " field:", field_name, " childRefId:", child_ref_id)
	
	var field_def = _get_field_def(parent, field_name)
	if field_def == null:
		print("[DEBUG] _create_child_instance - field_def is null!")
		return
	
	print("[DEBUG] _create_child_instance - field_def.type:", field_def.type, " child_type:", field_def.child_type)
	
	var child_instance = null
	var child_type = null
	
	if field_def.type == ColyseusSchema.MAP:
		child_instance = ColyseusSchema.Map.new(field_def.child_type)
		child_type = field_def.child_type
		print("[DEBUG] Created Map instance")
	elif field_def.type == ColyseusSchema.ARRAY:
		child_instance = ColyseusSchema.ArraySchema.new(field_def.child_type)
		child_type = field_def.child_type
		print("[DEBUG] Created ArraySchema instance")
	elif field_def.type == ColyseusSchema.REF or field_def.has_schema_child():
		if field_def.child_type != null:
			child_instance = field_def.child_type.new()
			child_type = field_def.child_type
			print("[DEBUG] Created Schema instance of type: ", field_def.child_type)
	
	if child_instance:
		child_instance.__ref_id = child_ref_id
		_schema_registry[child_ref_id] = child_instance
		if child_type:
			_type_registry[child_ref_id] = child_type
		
		# Transfer collection callbacks from parent to the new collection
		if field_def.is_collection():
			_transfer_collection_callbacks(parent, field_name, child_ref_id)

## Transfer collection callbacks (on_add/on_remove) from parent to the actual collection
func _transfer_collection_callbacks(parent, field_name: String, collection_ref_id: int) -> void:
	var parent_ref_id = _get_ref_id(parent)
	if parent_ref_id < 0:
		return
	
	print("[DEBUG] _transfer_collection_callbacks - parent refId:", parent_ref_id, " field:", field_name, " collection refId:", collection_ref_id)
	
	if not _callback_registry.has(parent_ref_id):
		print("[DEBUG] No callbacks on parent")
		return
	
	var parent_registry = _callback_registry[parent_ref_id]
	
	# Check for on_add callbacks registered on parent for this field
	var add_key = "%s:%d" % [field_name, OP_ADD]
	if parent_registry.has(add_key):
		print("[DEBUG] Transferring on_add callbacks from parent to collection refId:", collection_ref_id)
		if not _callback_registry.has(collection_ref_id):
			_callback_registry[collection_ref_id] = {}
		
		# Transfer to collection using empty field name (collection item operations use dynamicIndex)
		var collection_add_key = ":%d" % OP_ADD
		if not _callback_registry[collection_ref_id].has(collection_add_key):
			_callback_registry[collection_ref_id][collection_add_key] = []
		
		for cb_info in parent_registry[add_key]:
			_callback_registry[collection_ref_id][collection_add_key].append(cb_info)
			print("[DEBUG] Transferred callback to collection")
	
	# Check for on_remove callbacks registered on parent for this field
	var remove_key = "%s:%d" % [field_name, OP_DELETE]
	if parent_registry.has(remove_key):
		print("[DEBUG] Transferring on_remove callbacks from parent to collection refId:", collection_ref_id)
		if not _callback_registry.has(collection_ref_id):
			_callback_registry[collection_ref_id] = {}
		
		var collection_remove_key = ":%d" % OP_DELETE
		if not _callback_registry[collection_ref_id].has(collection_remove_key):
			_callback_registry[collection_ref_id][collection_remove_key] = []
		
		for cb_info in parent_registry[remove_key]:
			_callback_registry[collection_ref_id][collection_remove_key].append(cb_info)
	
	print("[DEBUG] callback_registry after transfer: ", _callback_registry)

## Get field definition from parent's schema
func _get_field_def(parent, field_name: String):
	var parent_ref_id = -1
	if parent is ColyseusSchema.Schema:
		parent_ref_id = parent.__ref_id
	elif parent is ColyseusSchema.Map:
		parent_ref_id = parent.__ref_id
	elif parent is ColyseusSchema.ArraySchema:
		parent_ref_id = parent.__ref_id
	
	if parent_ref_id < 0:
		return null
	
	var parent_type = _type_registry.get(parent_ref_id)
	if parent_type == null:
		return null
	
	# For collections, the type registry stores the child type
	if parent is ColyseusSchema.Map or parent is ColyseusSchema.ArraySchema:
		# The child type is stored directly
		return ColyseusSchema.Field.new(field_name, ColyseusSchema.REF, parent_type)
	
	# For schemas, look up the field definition
	if parent_type.has_method("definition"):
		for field_def in parent_type.definition():
			if field_def is ColyseusSchema.Field and field_def.name == field_name:
				return field_def
	
	return null

## Apply a change to a schema instance
func _apply_schema_change(target, field_name: String, op: int, val_type: int, val_data, prev_type: int, prev_data) -> void:
	if not target is ColyseusSchema.Schema:
		return
	
	var value = _resolve_value(val_type, val_data)
	target._set_field(field_name, value)

## Apply a change to a collection instance
func _apply_collection_change(target, field_name: String, dynamic_index, op: int, val_type: int, val_data, prev_type: int, prev_data) -> void:
	var key = dynamic_index if dynamic_index != null else field_name
	
	if target is ColyseusSchema.Map:
		var key_str = str(key)
		if (op & OP_DELETE) == OP_DELETE:
			target._remove_item(key_str)
		if (op & OP_ADD) == OP_ADD or op == OP_REPLACE:
			var value = _resolve_value(val_type, val_data)
			target._set_item(key_str, value)
	
	elif target is ColyseusSchema.ArraySchema:
		var index = int(key) if str(key).is_valid_int() else -1
		if index < 0:
			return
		
		if (op & OP_DELETE) == OP_DELETE:
			target._remove_at(index)
		if (op & OP_ADD) == OP_ADD or op == OP_REPLACE:
			var value = _resolve_value(val_type, val_data)
			target._set_at(index, value)

## Resolve a value from type and data
func _resolve_value(val_type: int, val_data):
	if val_type == VALUE_UNDEFINED:
		return null
	elif val_type == VALUE_PRIMITIVE:
		return val_data
	elif val_type == VALUE_REF:
		if val_data != null:
			return _schema_registry.get(int(val_data))
		return null
	return null

## Dispatch callbacks for a change
func _dispatch_callbacks(ref_id: int, field_name: String, dynamic_index, op: int, val_type: int, val_data, prev_type: int, prev_data, is_schema: bool) -> void:
	print("[DEBUG] _dispatch_callbacks - refId:", ref_id, " field:", field_name, " op:", op, " isSchema:", is_schema)
	print("[DEBUG] _dispatch_callbacks - callback_registry has refId? ", _callback_registry.has(ref_id))
	
	if not _callback_registry.has(ref_id):
		print("[DEBUG] No callbacks registered for refId: ", ref_id)
		return
	
	var registry = _callback_registry[ref_id]
	print("[DEBUG] Registry keys for refId ", ref_id, ": ", registry.keys())
	
	if is_schema:
		# Schema field change - dispatch field callbacks
		print("[DEBUG] Schema change - looking for field callback: ", field_name)
		if registry.has(field_name):
			var current_value = _resolve_value(val_type, val_data)
			var previous_value = _resolve_value(prev_type, prev_data)
			print("[DEBUG] Dispatching field callback for: ", field_name)
			
			for cb_info in registry[field_name]:
				var cb: Callable = cb_info["callback"]
				cb.call(current_value, previous_value)
	else:
		# Collection change - dispatch operation callbacks
		var key = dynamic_index if dynamic_index != null else field_name
		var value = _resolve_value(val_type, val_data)
		var prev_value = _resolve_value(prev_type, prev_data)
		
		print("[DEBUG] Collection change - op:", op, " OP_ADD:", OP_ADD, " (op & OP_ADD):", (op & OP_ADD))
		
		# Check for on_add callbacks
		if (op & OP_ADD) == OP_ADD:
			# First try with field name (for parent-based registration)
			var add_key = "%s:%d" % [field_name, OP_ADD]
			# Also try empty field name (for collection-based registration after transfer)
			var collection_add_key = ":%d" % OP_ADD
			
			print("[DEBUG] Looking for add_key: '", add_key, "' or collection_add_key: '", collection_add_key, "' in registry keys: ", registry.keys())
			
			var found_callbacks = false
			if registry.has(add_key):
				print("[DEBUG] Found on_add callbacks (field key), dispatching with value:", value, " key:", key)
				for cb_info in registry[add_key]:
					var cb: Callable = cb_info["callback"]
					cb.call(value, key)
				found_callbacks = true
			
			if registry.has(collection_add_key):
				print("[DEBUG] Found on_add callbacks (collection key), dispatching with value:", value, " key:", key)
				for cb_info in registry[collection_add_key]:
					var cb: Callable = cb_info["callback"]
					cb.call(value, key)
				found_callbacks = true
			
			if not found_callbacks:
				print("[DEBUG] No on_add callback found for either key")
		
		# Check for on_remove callbacks
		if (op & OP_DELETE) == OP_DELETE:
			var remove_key = "%s:%d" % [field_name, OP_DELETE]
			var collection_remove_key = ":%d" % OP_DELETE
			
			print("[DEBUG] Looking for remove_key: '", remove_key, "' or collection_remove_key: '", collection_remove_key, "'")
			
			if registry.has(remove_key):
				print("[DEBUG] Found on_remove callbacks (field key), dispatching")
				for cb_info in registry[remove_key]:
					var cb: Callable = cb_info["callback"]
					cb.call(prev_value, key)
			
			if registry.has(collection_remove_key):
				print("[DEBUG] Found on_remove callbacks (collection key), dispatching")
				for cb_info in registry[collection_remove_key]:
					var cb: Callable = cb_info["callback"]
					cb.call(prev_value, key)

## Clean up
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_callbacks.clear()
		_callback_registry.clear()
		_schema_registry.clear()
		_type_registry.clear()
		_handle_to_callback.clear()
