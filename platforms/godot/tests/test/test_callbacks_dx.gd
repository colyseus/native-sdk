extends GutTest
## Colyseus.Callbacks: register any time, synchronous delivery in wire order,
## no registration cap, loud failures, and callbacks that may tear things down.

var client: Colyseus.Client
var room: Colyseus.Room
var _callbacks: Colyseus.Callbacks

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func after_each():
	if Colyseus._poll_node and is_instance_valid(Colyseus._poll_node):
		Colyseus._poll_node.process_mode = Node.PROCESS_MODE_INHERIT
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null
	_callbacks = null

func _wait(cond: Callable, timeout_ms := 5000) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > timeout_ms:
			return false
		Colyseus.poll()
		await get_tree().process_frame
	return true

func _pump(ms: int) -> void:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < ms:
		Colyseus.poll()
		await get_tree().process_frame

func test_registrations_made_right_after_create_go_live():
	room = client.create("test_room", {"private": true})
	var callbacks := Colyseus.Callbacks.of(room)
	var added := []
	var turns := []
	assert_gt(callbacks.on_add("players", func(_p, key): added.append(str(key))), 0,
		"a real handle, though the room hasn't joined")
	callbacks.listen("currentTurn", func(value, _prev): turns.append(value))

	assert_true(await _wait(func(): return not added.is_empty() and not turns.is_empty()), "both should fire")
	assert_true(added.has(room.get_session_id()), "on_add replays our own player")
	assert_eq(str(turns.back()), room.get_session_id(), "listen hands over currentTurn")

func test_registrations_made_at_joined_go_live():
	room = client.create("test_room", {"private": true})
	var added := []
	var turns := []
	room.joined.connect(func():
		_callbacks = Colyseus.Callbacks.of(room)
		_callbacks.on_add("players", func(_p, key): added.append(str(key)))
		_callbacks.listen("currentTurn", func(value, _prev): turns.append(value)))

	assert_true(await _wait(func(): return not added.is_empty() and not turns.is_empty()), "both should fire")
	assert_true(added.has(room.get_session_id()), "on_add replays our own player")
	assert_eq(str(turns.back()), room.get_session_id(), "listen hands over currentTurn")

func test_the_first_state_arrives_in_wire_order():
	room = client.create("test_room", {"private": true})
	var events := []
	room.joined.connect(func(): events.append("joined"))
	room.state_changed.connect(func(): events.append("state_changed"))
	var callbacks := Colyseus.Callbacks.of(room)
	callbacks.on_add("players", func(_p, _key): events.append("on_add"))

	assert_true(await _wait(func(): return events.has("state_changed")), "the first state should arrive")
	assert_eq(events.slice(0, 3), ["joined", "on_add", "state_changed"])

func test_callbacks_and_signals_run_inside_poll():
	# no frame poller: every delivery below must come from our own poll() calls
	if Colyseus._poll_node and is_instance_valid(Colyseus._poll_node):
		Colyseus._poll_node.process_mode = Node.PROCESS_MODE_DISABLED
	var in_poll := [false]
	var seen := []
	room = client.create("test_room", {"private": true})
	room.state_changed.connect(func(): seen.append(in_poll[0]))
	var callbacks := Colyseus.Callbacks.of(room)
	callbacks.on_add("players", func(_p, _key): seen.append(in_poll[0]))

	var start := Time.get_ticks_msec()
	var bot_sent := false
	while seen.size() < 4 and Time.get_ticks_msec() - start < 5000:
		in_poll[0] = true
		Colyseus.poll()
		in_poll[0] = false
		if room.connected and not bot_sent:
			room.send_message("add_bot", {})
			bot_sent = true
		await get_tree().process_frame

	assert_gte(seen.size(), 4, "own player, a bot, and their state_changed")
	assert_false(seen.has(false), "nothing was deferred to a later frame")

func test_there_is_no_registration_cap():
	room = client.create("test_room", {"private": true})
	var callbacks := Colyseus.Callbacks.of(room)
	var turns := []
	callbacks.listen("currentTurn", func(value, _prev): turns.append(value))
	assert_true(await _wait(func(): return not turns.is_empty()), "currentTurn should arrive")

	var calls := [0]
	var handles := {}
	for i in 300:
		handles[callbacks.listen("currentTurn", func(_v, _p): calls[0] += 1)] = true
	assert_eq(handles.size(), 300, "300 distinct handles — the old table stopped at 256")
	assert_false(handles.has(-1), "no registration refused")
	assert_eq(calls[0], 300, "each fired right away with the current value")

	for handle in handles:
		callbacks.remove(handle)
	var after := [0]
	callbacks.listen("currentTurn", func(_v, _p): after[0] += 1)
	await _pump(100)
	assert_eq(calls[0], 300, "removed callbacks stay quiet")
	assert_eq(after[0], 1, "a new one still registers")

func test_every_callbacks_of_a_room_is_the_same_registry():
	room = client.create("test_room", {"private": true})
	var one := Colyseus.Callbacks.of(room)
	var two := Colyseus.Callbacks.of(room)
	assert_true(is_same(one._native, two._native), "one core listener per room, however often of() is called")

func test_a_callback_can_remove_itself():
	room = client.create("test_room", {"private": true})
	var callbacks := Colyseus.Callbacks.of(room)
	var fired := [0]
	var handle := [0]
	handle[0] = callbacks.on_add("players", func(_p, _k):
		fired[0] += 1
		callbacks.remove(handle[0]))
	assert_true(await _wait(func(): return room.connected and fired[0] > 0), "own player should arrive")
	room.send_message("add_bot", {})
	room.send_message("add_bot", {})
	await _pump(500)
	assert_eq(fired[0], 1, "removed from inside its own call, it never fires again")

func test_unknown_fields_fail_loudly():
	room = client.create("test_room", {"private": true})
	var callbacks := Colyseus.Callbacks.of(room)
	assert_true(await _wait(func(): return room.connected), "should join")

	assert_eq(callbacks.listen("no_such_field", func(_v, _p): pass), -1, "unknown field")
	assert_engine_error("no_such_field")
	assert_eq(callbacks.on_add("currentTurn", func(_v, _k): pass), -1, "on_add on a non-collection")
	assert_engine_error("not a map or array")

func test_dropping_the_room_from_one_of_its_callbacks_is_safe():
	# the native room: nothing else holds it, so dropping it really frees it
	var holder := {
		"room": client._native.create("test_room", JSON.stringify({"private": true})),
		"callbacks": null,
		"fired": false,
	}
	holder.callbacks = Colyseus.Callbacks.of(holder.room)
	holder.callbacks.on_add("players", func(_p, _k):
		holder.fired = true
		holder.room = null
		holder.callbacks = null)

	assert_true(await _wait(func(): return holder.fired), "own player should arrive")
	await _pump(300)
	assert_null(holder.room, "the room was released mid-decode and polling carried on")
