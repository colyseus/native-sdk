extends GutTest
## Decoding, room signals and schema callbacks all run on the main thread.
##
## The websocket used to decode patches on its own thread: typed instances got
## _set_field() calls off the main thread, racing whatever the game read that
## frame, and the game crashed after minutes. Sockets now tick inside
## Colyseus.poll().

class ProbeItem extends Colyseus.Schema:
	static func definition():
		return [
			Colyseus.Schema.Field.new("name", Colyseus.Schema.STRING),
			Colyseus.Schema.Field.new("value", Colyseus.Schema.NUMBER),
		]

class ProbePlayer extends Colyseus.Schema:
	static var set_field_threads := {}

	static func definition():
		return [
			Colyseus.Schema.Field.new("x", Colyseus.Schema.NUMBER),
			Colyseus.Schema.Field.new("y", Colyseus.Schema.NUMBER),
			Colyseus.Schema.Field.new("isBot", Colyseus.Schema.BOOLEAN),
			Colyseus.Schema.Field.new("disconnected", Colyseus.Schema.BOOLEAN),
			Colyseus.Schema.Field.new("items", Colyseus.Schema.ARRAY, ProbeItem),
		]

	func _set_field(field_name: String, value) -> void:
		ProbePlayer.set_field_threads[OS.get_thread_caller_id()] = true
		super._set_field(field_name, value)

class ProbeState extends Colyseus.Schema:
	static func definition():
		return [
			Colyseus.Schema.Field.new("players", Colyseus.Schema.MAP, ProbePlayer),
			Colyseus.Schema.Field.new("host", Colyseus.Schema.REF, ProbePlayer),
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

func test_decode_signals_and_callbacks_run_on_the_main_thread():
	ProbePlayer.set_field_threads.clear()
	var seen := {}
	room = client.create("test_room", {"private": true})
	room.set_state_type(ProbeState)
	room.joined.connect(func(): seen["joined"] = OS.get_thread_caller_id())
	room.state_changed.connect(func(): seen["state_changed"] = OS.get_thread_caller_id())
	room.message_received.connect(func(_type, _data): seen["message_received"] = OS.get_thread_caller_id())

	var callbacks := Colyseus.Callbacks.of(room)
	var bots := []
	callbacks.on_add("players", func(player, _key):
		seen["on_add"] = OS.get_thread_caller_id()
		if player.isBot:
			bots.append(player)
		callbacks.listen(player, "x", func(_value, _prev): seen["listen"] = OS.get_thread_caller_id()))
	callbacks.on_remove("players", func(_player, _key): seen["on_remove"] = OS.get_thread_caller_id())

	assert_true(await _wait(func(): return room.connected), "should join test_room")
	room.send_message("add_bot", {})
	# the bot itself, not just our own player: add+remove in one patch never reaches us
	assert_true(await _wait(func(): return not bots.is_empty() and seen.has("listen")), "a bot should arrive")
	room.send_message("remove_bot", {})
	assert_true(await _wait(func(): return seen.has("on_remove")), "the bot should leave")
	assert_true(await _wait(func(): return seen.has("message_received")), "join_options should arrive")

	var main := OS.get_main_thread_id()
	for label in ["joined", "state_changed", "message_received", "on_add", "listen", "on_remove"]:
		assert_eq(seen.get(label, -1), main, "%s should run on the main thread" % label)
	assert_false(ProbePlayer.set_field_threads.is_empty(), "the decoder should have set fields")
	for thread_id in ProbePlayer.set_field_threads:
		assert_eq(thread_id, main, "the decoder should run on the main thread")
