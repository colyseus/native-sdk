extends Node
## Example script demonstrating Colyseus GDExtension usage

var client: ColyseusClient
var room: ColyseusRoom

func _ready():
	# Create and connect client
	client = ColyseusClient.new()
	client.connect_to("ws://localhost:2567")
	
	print("Connecting to: ", client.get_endpoint())
	
	# Join or create a room
	room = client.join_or_create("my_room")
	
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
	
	# Send a message
	var message = "Hello from Godot!".to_utf8_buffer()
	room.send_message("greeting", message)

func _on_state_changed():
	print("↻ Room state changed")

func _on_message_received(data: PackedByteArray):
	var message = data.get_string_from_utf8()
	print("✉ Message received: ", message)

func _on_room_error(code: int, message: String):
	printerr("✗ Room error [", code, "]: ", message)

func _on_room_left(code: int, reason: String):
	print("← Left room [", code, "]: ", reason)

func _exit_tree():
	# Clean up when node is removed
	if room and room.has_joined():
		room.leave()

