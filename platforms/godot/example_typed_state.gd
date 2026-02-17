extends Node
## Example script demonstrating typed state with GDScript Schema classes
##
## This example shows how to define your state schema directly in GDScript,
## allowing you to access state properties with type safety and custom methods.

class Item extends ColyseusSchema.Schema:
	static func definition():
		return [
			ColyseusSchema.Field.new("name", ColyseusSchema.STRING),
			ColyseusSchema.Field.new("value", ColyseusSchema.NUMBER),
		]

class Player extends ColyseusSchema.Schema:
	static func definition():
		return [
			ColyseusSchema.Field.new("x", ColyseusSchema.NUMBER),
			ColyseusSchema.Field.new("y", ColyseusSchema.NUMBER),
			ColyseusSchema.Field.new("isBot", ColyseusSchema.BOOLEAN),
			ColyseusSchema.Field.new("disconnected", ColyseusSchema.BOOLEAN),
			ColyseusSchema.Field.new("items", ColyseusSchema.ARRAY, Item),
		]
	func method_name() -> String:
		return "Player(x: %s, y: %s, isBot: %s, disconnected: %s, items: %s)" % [self.x, self.y, self.isBot, self.disconnected, self.items]

class TestRoomState extends ColyseusSchema.Schema:
	static func definition():
		return [
			ColyseusSchema.Field.new("players", ColyseusSchema.MAP, Player),
			ColyseusSchema.Field.new("host", ColyseusSchema.REF, Player),
			ColyseusSchema.Field.new("currentTurn", ColyseusSchema.STRING),
		]

# Client and room references
var client: ColyseusClient
var room: ColyseusRoom
var callbacks: ColyseusCallbacks

func _ready():
	# Create and connect client
	client = ColyseusClient.new()
	client.connect_to("ws://localhost:2567")
	
	print("Connecting to: ", client.get_endpoint())
	
	# Join or create a room
	room = client.join_or_create("test_room")
	
	# Set state type using our GDScript schema class
	if room:
		room.set_state_type(TestRoomState)
		
		# Connect signals
		room.joined.connect(_on_room_joined)
		room.state_changed.connect(_on_state_changed)
		room.error.connect(_on_room_error)
		room.left.connect(_on_room_left)

func _on_room_joined():
	print("Joined room: ", room.get_id())
	
	# Get callbacks container
	callbacks = ColyseusCallbacks.get(room)
	
	# Listen to state changes
	callbacks.listen("currentTurn", _on_turn_change)
	callbacks.on_add("players", _on_player_add)
	callbacks.on_remove("players", _on_player_remove)

func _on_turn_change(current_value, previous_value):
	print("Turn changed: ", previous_value, " -> ", current_value)

# func _on_player_add(player: Player, key: String):
func _on_player_add(player, key: String):
	# Player is now a typed instance!
	print("Player joined: ", player.method_name())  # Uses our custom _to_string()
	# Set up listeners for player properties
	callbacks.on_add(player, "items", _on_item_add)
	callbacks.listen(player, "x", _on_player_position_change)
	callbacks.listen(player, "y", _on_player_position_change)

func _on_item_add(item, key):
	print("Item added: ", item)

func _on_player_remove(player, key):
# func _on_player_remove(player: Player, key: String):
	print("Player left: ", key, " => ", player)

func _on_player_hp_change(current_hp, previous_hp):
	print("HP changed: ", previous_hp, " -> ", current_hp)

func _on_player_position_change(current_pos, previous_pos):
	print("Position changed")

func _on_state_changed():
	# Access the typed state
	var state = room.get_state()
	print("State changed -> ", state)

	print("Room session id: ", room.get_session_id())
	var is_host = state.host == state.players[room.get_session_id()]

func _on_room_error(code: int, message: String):
	printerr("Room error [", code, "]: ", message)

func _on_room_left(code: int, reason: String):
	print("Left room [", code, "]: ", reason)

func _exit_tree():
	if room and room.has_joined():
		room.leave()
