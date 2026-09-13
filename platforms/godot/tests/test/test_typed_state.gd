extends GutTest
## set_state_type(GDScript class): get_state() is the typed root, and its map
## and array fields are live — the same Dictionary/Array, kept current.

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

class TestState extends Colyseus.Schema:
	static func definition():
		return [
			Colyseus.Schema.Field.new("players", Colyseus.Schema.MAP, Player),
			Colyseus.Schema.Field.new("host", Colyseus.Schema.REF, Player),
			Colyseus.Schema.Field.new("currentTurn", Colyseus.Schema.STRING),
		]

class FixtureState extends Colyseus.Schema:
	static func definition():
		return [
			Colyseus.Schema.Field.new("yaw", Colyseus.Schema.QUANTIZED, {"min": 0.0, "max": TAU, "mode": "wrap"}),
			Colyseus.Schema.Field.new("speed", Colyseus.Schema.NUMBER),
			Colyseus.Schema.Field.new("bytes", Colyseus.Schema.ARRAY, Colyseus.Schema.UINT8),
			Colyseus.Schema.Field.new("scores", Colyseus.Schema.MAP, Colyseus.Schema.NUMBER),
		]

var client: Colyseus.Client
var room: Colyseus.Room

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null

func _wait(cond: Callable, timeout_ms := 5000) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > timeout_ms:
			return false
		Colyseus.poll()
		await get_tree().process_frame
	return true

func _join_test_room() -> bool:
	room = client.create("test_room", {"private": true})
	room.set_state_type(TestState)
	return await _wait(func():
		var s = room.state
		return s != null and s.players is Dictionary and s.players.has(room.get_session_id()))

func _names(items: Array) -> Array:
	return items.map(func(item): return str(item.name))

func test_get_state_is_the_typed_root():
	room = client.create("test_room", {"private": true})
	room.set_state_type(TestState)
	assert_null(room.get_state(), "no root before the room joins")
	assert_true(await _wait(func(): return room.state != null and str(room.state.currentTurn) != ""),
		"the root should decode")

	var state = room.get_state()
	assert_true(state is TestState, "the user's root class")
	assert_true(is_same(state, room.get_state()), "the same object every call")
	assert_true(is_same(state, room.state), "room.state is get_state()")
	assert_eq(str(state.currentTurn), room.get_session_id())

func test_map_fields_are_live():
	assert_true(await _join_test_room(), "should join with our player decoded")
	var players: Dictionary = room.state.players
	assert_true(players[room.get_session_id()] is Player, "values are the user's instances")

	room.send_message("add_bot", {})
	assert_true(await _wait(func(): return players.size() == 2), "the bot shows up in the same Dictionary")
	for key in players:
		assert_true(players[key] is Player)
	room.send_message("remove_bot", {})
	assert_true(await _wait(func(): return players.size() == 1), "and leaves it again")
	assert_true(is_same(players, room.state.players), "never replaced")

func test_array_fields_are_live():
	assert_true(await _join_test_room(), "should join with our player decoded")
	var me = room.state.players[room.get_session_id()]
	var items: Array = me.items
	assert_true(await _wait(func(): return items.size() == 1), "the starting item")
	assert_eq(_names(items), ["sword"])

	room.send_message("add_item", {"name": "shield"})
	assert_true(await _wait(func(): return items.size() == 2), "pushes land in the same Array")
	assert_eq(_names(items), ["sword", "shield"], "in server order")
	room.send_message("reset_items", {})
	assert_true(await _wait(func(): return _names(items) == ["reset_a", "reset_b"]), "splice + push in one patch")
	room.send_message("remove_item", {})
	assert_true(await _wait(func(): return items.size() == 1), "removals too")
	assert_true(is_same(items, me.items), "never replaced")

func test_listen_on_a_collection_hands_over_the_live_container():
	assert_true(await _join_test_room(), "should join with our player decoded")
	var me = room.state.players[room.get_session_id()]
	var got := []
	var callbacks := Colyseus.Callbacks.of(room)
	callbacks.listen(me, "items", func(value, _prev): got.append(value))
	assert_false(got.is_empty(), "fires right away with the current value")
	if not got.is_empty():
		assert_true(is_same(got[0], me.items), "the same live Array the instance holds")

func test_primitive_collections_and_quantized_fields_decode_typed():
	room = client.create("binding_fixture_room", {"private": true})
	room.set_state_type(FixtureState)
	assert_true(await _wait(func(): return room.state != null and room.state.bytes is Array and room.state.bytes.size() == 3),
		"the fixture state should decode (is example-server up with binding_fixture_room?)")
	var state = room.state
	if state == null:
		return
	assert_almost_eq(float(state.yaw), 1.5, 0.001, "quantized field, dequantized")

	var bytes: Array = state.bytes
	assert_eq(bytes, [7, 8, 9])
	assert_typeof(bytes[0], TYPE_INT, "uint8 items are ints")
	room.send_message("push_byte", 10)
	assert_true(await _wait(func(): return bytes == [7, 8, 9, 10]), "a push lands in the same Array")
	room.send_message("shift_byte", {})
	assert_true(await _wait(func(): return bytes == [8, 9, 10]), "a shift re-indexes it")

	var scores: Dictionary = state.scores
	assert_eq(scores, {"a": 1.5})
	room.send_message("set_score", {"key": "b", "value": 2.5})
	assert_true(await _wait(func(): return scores.has("b")), "a set lands in the same Dictionary")
	assert_eq(scores.keys(), ["a", "b"], "in insertion order")
	room.send_message("delete_score", "a")
	assert_true(await _wait(func(): return not scores.has("a")), "a delete too")
	assert_true(is_same(bytes, state.bytes) and is_same(scores, state.scores), "never replaced")
