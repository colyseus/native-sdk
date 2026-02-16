extends Node
## Example script demonstrating typed state with GDScript Schema classes
##
## This example shows how to define your state schema directly in GDScript,
## allowing you to access state properties with type safety and custom methods.

# Load the Colyseus schema library
#const colyseus = preload("res://addons/colyseus/schema.gd")


# Define your schema classes
class Player extends ColyseusSchema.Schema:
	## Define the schema fields
	static func definition():
		return [
			ColyseusSchema.Field.new("x", ColyseusSchema.NUMBER),
			ColyseusSchema.Field.new("y", ColyseusSchema.NUMBER),
			ColyseusSchema.Field.new("name", ColyseusSchema.STRING),
			ColyseusSchema.Field.new("hp", ColyseusSchema.NUMBER),
		]
	
	## Custom method: nice string representation
	func _to_string() -> String:
		return str("Player(", self.name, " at ", self.x, ",", self.y, " hp:", self.hp, ")")
	
	## Custom method: calculate distance to another player
	func distance_to(other: Player) -> float:
		var dx = self.x - other.x
		var dy = self.y - other.y
		return sqrt(dx * dx + dy * dy)

class Item extends ColyseusSchema.Schema:
	static func definition():
		return [
			ColyseusSchema.Field.new("id", ColyseusSchema.STRING),
			ColyseusSchema.Field.new("name", ColyseusSchema.STRING),
			ColyseusSchema.Field.new("quantity", ColyseusSchema.NUMBER),
		]
	
	func _to_string() -> String:
		return str("Item(", self.name, " x", self.quantity, ")")

class RoomState extends ColyseusSchema.Schema:
	static func definition():
		return [
			ColyseusSchema.Field.new("currentTurn", ColyseusSchema.STRING),
			ColyseusSchema.Field.new("players", ColyseusSchema.MAP, Player),
			ColyseusSchema.Field.new("items", ColyseusSchema.ARRAY, Item),
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
	room = client.join_or_create("game_room")
	
	# Set state type using our GDScript schema class
	if room:
		room.set_state_type(RoomState)
		
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

func _on_player_add(player: Player, key: String):
	# Player is now a typed instance!
	print("Player joined: ", player)  # Uses our custom _to_string()
	print("  Position: ", player.x, ", ", player.y)
	
	# Set up listeners for player properties
	callbacks.listen(player, "hp", _on_player_hp_change)
	callbacks.listen(player, "x", _on_player_position_change)
	callbacks.listen(player, "y", _on_player_position_change)

func _on_player_remove(player: Player, key: String):
	print("Player left: ", player.name)

func _on_player_hp_change(current_hp, previous_hp):
	print("HP changed: ", previous_hp, " -> ", current_hp)

func _on_player_position_change(current_pos, previous_pos):
	print("Position changed")

func _on_state_changed():
	# Access the typed state
	var state: RoomState = room.get_state()
	if state:
		print("Current turn: ", state.currentTurn)
		
		# Iterate over players (Map)
		if state.players:
			for player_id in state.players.keys():
				var player: Player = state.players[player_id]
				print("  Player ", player_id, ": ", player)
		
		# Iterate over items (Array)
		if state.items:
			for item in state.items:
				print("  Item: ", item)

func _on_room_error(code: int, message: String):
	printerr("Room error [", code, "]: ", message)

func _on_room_left(code: int, reason: String):
	print("Left room [", code, "]: ", reason)

func _exit_tree():
	if room and room.has_joined():
		room.leave()
