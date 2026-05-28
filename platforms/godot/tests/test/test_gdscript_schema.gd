extends GutTest
## GDScript schema parsing tests — exercises Room.set_state_type() with a
## user-defined GDScript schema against test_room (TestRoom).
##
## Regression coverage for issue #23: parse_field_from_variant() in
## platforms/godot/src/colyseus_gdscript_schema.c crashed on Android release
## exports while reading GDScript Field properties. No prior test exercised the
## set_state_type() + GDScript-schema decode path at all, so the whole native
## parser (gdscript_schema_context_create -> parse_field_from_variant) was
## untested. The schema below mirrors example-server/src/rooms/TestRoom.ts and
## covers every Field branch in the parser: STRING/NUMBER/BOOLEAN primitives,
## MAP + schema child, ARRAY + schema child, and REF + schema child.

class Item extends Colyseus.Schema:
	static func definition():
		return [
			Colyseus.Schema.Field.new("name", Colyseus.Schema.STRING),
			Colyseus.Schema.Field.new("value", Colyseus.Schema.NUMBER),
		]

class Player extends Colyseus.Schema:
	static func definition():
		return [
			Colyseus.Schema.Field.new("x", Colyseus.Schema.NUMBER),
			Colyseus.Schema.Field.new("y", Colyseus.Schema.NUMBER),
			Colyseus.Schema.Field.new("isBot", Colyseus.Schema.BOOLEAN),
			Colyseus.Schema.Field.new("disconnected", Colyseus.Schema.BOOLEAN),
			Colyseus.Schema.Field.new("items", Colyseus.Schema.ARRAY, Item),
		]

class TestRoomState extends Colyseus.Schema:
	static func definition():
		return [
			Colyseus.Schema.Field.new("players", Colyseus.Schema.MAP, Player),
			Colyseus.Schema.Field.new("host", Colyseus.Schema.REF, Player),
			Colyseus.Schema.Field.new("currentTurn", Colyseus.Schema.STRING),
		]

var client: Colyseus.Client
var room: Colyseus.Room
var callbacks

var _joined := false
var _my_session := ""
var _captured_player = null

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func before_each():
	room = null
	callbacks = null
	_joined = false
	_my_session = ""
	_captured_player = null

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null
	callbacks = null

func _on_joined(): _joined = true

func _on_player_add(player, key):
	if key == _my_session and _captured_player == null:
		_captured_player = player

# Join test_room with the GDScript state type applied before connection settles,
# which forces parse_field_from_variant() to run over the schema above.
func _join_typed_test_room() -> bool:
	room = client.join_or_create("test_room")
	if not room:
		return false
	room.set_state_type(TestRoomState)
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		await get_tree().process_frame
	if _joined:
		_my_session = room.get_session_id()
	return _joined

# =============================================================================
# Schema parsing / typed decode
# =============================================================================

func test_set_state_type_decodes_into_user_gdscript_classes():
	if not await _join_typed_test_room():
		fail_test("Failed to join test_room")
		return

	callbacks = Colyseus.Callbacks.of(room)
	callbacks.on_add("players", _on_player_add)

	# Wait for our own player to arrive as a typed instance. If
	# parse_field_from_variant() failed to register the "players" MAP field (or
	# its Player child type), on_add never fires for a typed instance.
	var start = Time.get_ticks_msec()
	while _captured_player == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		await get_tree().process_frame
	assert_not_null(_captured_player, "Own player should be captured via on_add")
	if _captured_player == null:
		return

	# Strongest signal that the GDScript schema parser ran: the MAP child decoded
	# into an instance of the user-defined Player class, built via the parsed
	# vtable (parse_field_from_variant -> gdscript_create_instance). The schema
	# also forces the parser through the BOOLEAN fields (isBot/disconnected); if
	# any Field read had failed during set_state_type, this typed decode could
	# not happen.
	assert_true(_captured_player is Player, "Map value should be our user-defined Player class")

	# Decoded field values are read from the native schema via the get_state()
	# Dictionary snapshot. Poll until the initial state batch has fully landed:
	# currentTurn assigned and the starting Item pushed into the player's array.
	var state := {}
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		await get_tree().process_frame
		state = room.get_state()
		if _state_ready(state):
			break
	assert_eq(typeof(state), TYPE_DICTIONARY, "get_state() returns a Dictionary snapshot")

	# STRING primitive — server sets currentTurn to the first player's session id.
	assert_true(state.has("currentTurn"), "state should expose the STRING 'currentTurn' field")
	assert_false(str(state["currentTurn"]).is_empty(), "currentTurn should be a non-empty session id")

	# MAP field + NUMBER fields on the child schema.
	assert_true(state.has("players"), "state should expose the MAP 'players' field")
	var players: Dictionary = state["players"]
	assert_true(players.has(_my_session), "players map should contain our session id")
	var me: Dictionary = players[_my_session]
	assert_true(me.has("x") and me.has("y"), "Player should carry its NUMBER fields")
	assert_true(typeof(me["x"]) == TYPE_FLOAT or typeof(me["x"]) == TYPE_INT, "Player.x should decode as a number")

	# ARRAY + schema child — server pushes one Item ("sword") on join.
	assert_true(me.has("items"), "Player should expose the ARRAY 'items' field")
	var items: Array = me["items"]
	assert_gt(items.size(), 0, "Player.items should contain the starting item")
	assert_eq(str((items[0] as Dictionary)["name"]), "sword", "Item.name (STRING) should decode to the server value")

	# REF field — host references the first player and decodes to its own entry.
	assert_true(state.has("host"), "state should expose the REF 'host' field")
	assert_eq(typeof(state["host"]), TYPE_DICTIONARY, "host (REF) should decode to the referenced player")
	assert_true((state["host"] as Dictionary).has("items"), "host should carry the referenced player's fields")

# True once the initial state batch has fully arrived (currentTurn set and the
# starting item pushed into our player's array).
func _state_ready(state) -> bool:
	if typeof(state) != TYPE_DICTIONARY:
		return false
	if str(state.get("currentTurn", "")).is_empty():
		return false
	var players = state.get("players", {})
	if not (players is Dictionary) or not players.has(_my_session):
		return false
	var me = players[_my_session]
	return me is Dictionary and (me.get("items", []) as Array).size() > 0
