class_name ColyseusFactory
extends RefCounted
## Colyseus Platform Factory
##
## This provides platform-aware client creation.
## On native platforms, it uses the GDExtension (ColyseusClient).
## On web platform, it uses the JavaScript SDK bridge (ColyseusWebClient).
##
## Usage:
##   var client = ColyseusFactory.create_client()
##   client.set_endpoint("ws://localhost:2567")
##   var room = client.join_or_create("my_room")
##   var callbacks = ColyseusFactory.get_callbacks(room)

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
		push_error("ColyseusFactory: Could not load web client script")
		return null
	else:
		# Native platform - use GDExtension via ClassDB
		var class_name_str := &"ColyseusClient"
		if ClassDB.class_exists(class_name_str):
			return ClassDB.instantiate(class_name_str)
		push_error("ColyseusFactory: Native ColyseusClient not available")
		return null

## Get callbacks for a room (platform-aware)
static func get_callbacks(room) -> Variant:
	if is_web():
		# Web platform - use JavaScript SDK bridge
		var web_callbacks_script = load("res://addons/colyseus/web/colyseus_web_callbacks.gd")
		if web_callbacks_script:
			return web_callbacks_script.get_for_room(room)
		push_error("ColyseusFactory: Could not load web callbacks script")
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
		push_error("ColyseusFactory: Native ColyseusCallbacks not available")
		return null
