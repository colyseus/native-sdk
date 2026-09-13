extends GutTest
## Colyseus.Callbacks keep firing after a Predict is created on the same room.
## The decoder had a single change hook: Predict's own callbacks took it over,
## and the app's callbacks went silent after the initial state.

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

func _join_typed() -> bool:
	room = client.create("test_room", {"private": true})
	room.set_state_type(TestState)
	return await _wait(func(): return room.connected)

func _attach_predict():
	var predict := Colyseus.Predict.of(room)
	predict.attach_all("players", {"x": Colyseus.Predict.LERP, "y": Colyseus.Predict.LERP})
	return predict

func _assert_moves_reach(xs: Array) -> void:
	for target in [11.0, 22.0, 33.0]:
		room.send_message("move", {"x": target, "y": 1.0})
		assert_true(await _wait(func(): return _num(xs.back()) == target),
			"listen should fire for x=%s" % target)

func test_callbacks_registered_before_a_predict_keep_firing():
	assert_true(await _join_typed(), "should join test_room")
	var callbacks := Colyseus.Callbacks.of(room)
	var xs := []
	var added := []
	callbacks.on_add("players", func(player, key):
		added.append(str(key))
		if str(key) == room.get_session_id():
			callbacks.listen(player, "x", func(value, _prev): xs.append(value)))
	assert_true(await _wait(func(): return not xs.is_empty()), "own player should arrive")

	var predict = _attach_predict()
	await _assert_moves_reach(xs)

	var before := added.size()
	room.send_message("add_bot", {})
	assert_true(await _wait(func(): return added.size() > before), "on_add should still fire")
	assert_not_null(predict)

func test_callbacks_registered_after_a_predict_fire():
	assert_true(await _join_typed(), "should join test_room")
	var predict = _attach_predict()
	var callbacks := Colyseus.Callbacks.of(room)
	var xs := []
	callbacks.on_add("players", func(player, key):
		if str(key) == room.get_session_id():
			callbacks.listen(player, "x", func(value, _prev): xs.append(value)))
	assert_true(await _wait(func(): return not xs.is_empty()), "own player should arrive")
	await _assert_moves_reach(xs)
	assert_not_null(predict)
