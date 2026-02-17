extends Node
## Example script demonstrating Colyseus GDExtension usage

var client: ColyseusClient
var room: ColyseusRoom
var callbacks: ColyseusCallbacks

func _ready():
	# Create and connect client
	client = ColyseusClient.new()
	client.set_endpoint("ws://localhost:2567")

	print("Connecting to: ", client.get_endpoint())

	# Join or create a room
	room = client.join_or_create("test_room")
	# room = client.join_or_create("my_room")

	# # Set state type BEFORE room finishes joining (required for state decoding)
	# # The type name must match a registered vtable in the schema registry
	# if room:
	# 	room.set_state_type("TestRoomState")

	# Connect signals
	if room:
		room.joined.connect(_on_room_joined)
		room.state_changed.connect(_on_state_changed)
		room.message_received.connect(_on_message_received)
		room.error.connect(_on_room_error)
		room.left.connect(_on_room_left)

func _on_room_joined():
	print("✓ Joined room: ", room.get_id())
	print("  Session ID: ", room.get_session_id())
	print("  Room name: ", room.get_name())

	# Get callbacks container for the room
	callbacks = ColyseusCallbacks.get(room)
	
	# Listen to root state property changes
	callbacks.listen("currentTurn", _on_turn_change)
	
	# Listen to collection additions/removals
	callbacks.on_add("players", _on_player_add)
	callbacks.on_remove("players", _on_player_remove)

	# Send a message
	var message = "Hello from Godot!".to_utf8_buffer()
	room.send_message("add_item", {"name": "MY NEW ITEM"})

func _on_turn_change(current_value, previous_value):
	print("↻ Turn changed: ", previous_value, " -> ", current_value)

func _on_player_add(player: Dictionary, key: String):
	print("+ Player joined: ", key)
	# Listen to nested schema properties
	callbacks.listen(player, "hp", _on_player_hp_change)
	# Listen to nested collections
	callbacks.on_add(player, "items", _on_item_add)

func _on_player_remove(player: Dictionary, key: String):
	print("- Player left: ", key)

func _on_player_hp_change(current_hp, previous_hp):
	print("  HP changed: ", previous_hp, " -> ", current_hp)

func _on_item_add(item: Dictionary, index: int):
	print("  Item added at index: ", index, " -> ", item)

	callbacks.listen(item, "name", func(name, _prev): 
		print("  Item name: ", name))

func _on_state_changed():
	print("↻ Room state changed")
	# Access state as Dictionary
	var state = room.get_state()
	if state:
		print("  State: ", state)

func _on_message_received(type, data):
	# type is the message type (String or int for numeric types)
	# data is automatically decoded from msgpack to native Godot types:
	#   - Dictionary for msgpack maps
	#   - Array for msgpack arrays
	#   - String, int, float, bool for primitives
	#   - null for nil
	#   - PackedByteArray for binary data
	print("✉ Message received - type: ", type)

	# Work directly with native Godot types - no manual decoding needed!
	if data is Dictionary:
		print("  Data (Dictionary): ", data)
		# Access fields directly
		if data.has("player_name"):
			print("    Player: ", data["player_name"])
		if data.has("score"):
			print("    Score: ", data["score"])
	elif data is Array:
		print("  Data (Array): ", data)
		for item in data:
			print("    Item: ", item)
	elif data is String:
		print("  Data (String): ", data)
	elif data is int or data is float:
		print("  Data (Number): ", data)
	elif data == null:
		print("  Data: null")
	else:
		print("  Data (other): ", typeof(data), " = ", data)

	# Example: Handle specific message types
	if type == "greeting":
		print("  → Got a greeting message!")
	elif type == "game_update":
		print("  → Got a game update!")
		if data is Dictionary and data.has("players"):
			for player in data["players"]:
				print("    Player update: ", player)

func _on_room_error(code: int, message: String):
	printerr("✗ Room error [", code, "]: ", message)

func _on_room_left(code: int, reason: String):
	print("← Left room [", code, "]: ", reason)

func _exit_tree():
	# Clean up when node is removed
	if room and room.has_joined():
		room.leave()
