extends GutTest
## A removed entity's GDScript object must never read another entity.
##
## The server recycles ref ids. Predict used to resolve an object by its
## __ref_id alone, so an object kept around after removal (a death fade) read
## whatever was decoded under that id next — once a collection, which crashed.
## Now an object only resolves to the instance it IS, the binding resets
## __ref_id to -1 when the instance is released, and value() on a released
## object returns the last value that object received.

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
var callbacks: Colyseus.Callbacks
var bots := {}          # key -> Player, in arrival order
var removed_ids := {}   # key -> __ref_id seen inside on_remove

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func before_each():
	bots = {}
	removed_ids = {}

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null
	callbacks = null

func _wait(cond: Callable, timeout_ms := 5000) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > timeout_ms:
			return false
		Colyseus.poll()
		await get_tree().process_frame
	return true

func _join_typed() -> bool:
	room = client.create("test_room", {"private": true})
	room.set_state_type(TestState)
	callbacks = Colyseus.Callbacks.of(room)
	callbacks.on_add("players", func(player, key):
		if player.isBot:
			bots[str(key)] = player)
	callbacks.on_remove("players", func(player, key): removed_ids[str(key)] = player.__ref_id)
	return await _wait(func(): return room.connected)

func _add_bots(count: int) -> bool:
	for i in count:
		room.send_message("add_bot", {})
	return await _wait(func(): return bots.size() >= count)

func test_released_instance_gives_its_ref_id_back():
	assert_true(await _join_typed(), "should join test_room")
	assert_true(await _add_bots(1), "a bot should arrive")
	if bots.is_empty():
		return
	var key: String = bots.keys()[0]
	var bot = bots[key]
	var ref_id: int = bot.__ref_id
	assert_gt(ref_id, 0, "a decoded instance carries its ref id")

	room.send_message("remove_bot", {})
	assert_true(await _wait(func(): return removed_ids.has(key)), "on_remove should fire")
	assert_eq(removed_ids.get(key), ref_id, "on_remove runs while the instance is still live")
	assert_eq(bot.__ref_id, -1, "the released instance's id is reset — the server will recycle it")

func test_a_stale_ref_id_never_resolves_to_another_entity():
	assert_true(await _join_typed(), "should join test_room")
	assert_true(await _add_bots(2), "two bots should arrive")
	if bots.size() < 2:
		return
	var predict := Colyseus.Predict.of(room)
	predict.attach_all("players", {"x": Colyseus.Predict.RAW})
	var a = bots.values()[0]
	var b = bots.values()[1]
	assert_true(await _wait(func(): return absf(float(a.x) - float(b.x)) > 0.001), "the bots should sit apart")

	# what a recycled id looks like from the stale object's side
	a.__ref_id = b.__ref_id
	var read := predict.value(a, "x")
	assert_almost_eq(read, float(a.x), 0.000001, "an object only reads its own instance")
	assert_ne(read, float(b.x), "never the entity that owns the id now")
	assert_almost_eq(predict.value_at(a, "x", room.clock.server_now()), float(a.x), 0.000001,
		"value_at() resolves the same way")

func test_value_of_a_removed_entity_is_its_last_value():
	assert_true(await _join_typed(), "should join test_room")
	var predict := Colyseus.Predict.of(room)
	predict.attach_all("players", {"x": Colyseus.Predict.LERP})
	assert_true(await _add_bots(1), "a bot should arrive")
	if bots.is_empty():
		return
	var key: String = bots.keys()[0]
	var bot = bots[key]
	room.send_message("remove_bot", {})
	assert_true(await _wait(func(): return removed_ids.has(key)), "on_remove should fire")
	for i in 5:
		Colyseus.poll()
		await get_tree().process_frame

	var read := predict.value(bot, "x")
	assert_false(is_nan(read), "a removed entity still reads (death fades), not NAN")
	assert_almost_eq(read, float(bot.x), 0.000001, "the last value the object received")
	assert_true(is_nan(predict.value(bot, "no_such_field")), "NAN only for a field the object doesn't have")
