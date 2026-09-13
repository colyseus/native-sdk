extends GutTest
## listen() hands over `number` and quantized values. Both used to arrive as
## null: the value conversion only knew float32/float64.

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

func _num(v) -> float:
	return float(v) if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT else NAN

func test_listen_delivers_number_and_quantized_root_fields():
	room = client.create("binding_fixture_room", {"private": true})
	var callbacks := Colyseus.Callbacks.of(room)
	var speeds := []
	var yaws := []
	callbacks.listen("speed", func(value, _prev): speeds.append(value))
	callbacks.listen("yaw", func(value, _prev): yaws.append(value))

	assert_true(await _wait(func(): return not speeds.is_empty() and not yaws.is_empty()),
		"initial values should arrive (is example-server up with binding_fixture_room?)")
	if speeds.is_empty() or yaws.is_empty():
		return
	assert_typeof(speeds[0], TYPE_FLOAT, "number field")
	assert_almost_eq(_num(speeds[0]), 2.5, 0.0001)
	assert_typeof(yaws[0], TYPE_FLOAT, "quantized field, dequantized")
	assert_almost_eq(_num(yaws[0]), 1.5, 0.001)

	room.send_message("set", {"speed": -4.25, "yaw": 3.0})
	assert_true(await _wait(func(): return _num(speeds.back()) == -4.25), "number change should arrive")
	assert_true(await _wait(func(): return absf(_num(yaws.back()) - 3.0) < 0.001), "quantized change should arrive")

func test_listen_delivers_a_nested_number_field():
	room = client.create("test_room", {"private": true})
	room.set_state_type(TestState)
	var callbacks := Colyseus.Callbacks.of(room)
	var xs := []
	callbacks.on_add("players", func(player, key):
		if str(key) == room.get_session_id():
			callbacks.listen(player, "x", func(value, _prev): xs.append(value)))

	assert_true(await _wait(func(): return not xs.is_empty()), "listen should fire with the current x")
	if xs.is_empty():
		return
	assert_typeof(xs[0], TYPE_FLOAT, "number field on a nested instance")

	room.send_message("move", {"x": 42.5, "y": 7.0})
	assert_true(await _wait(func(): return _num(xs.back()) == 42.5), "the moved x should arrive as a float")
