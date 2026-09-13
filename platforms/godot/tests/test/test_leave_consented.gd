extends GutTest
## room.leave() is a consented leave, like the TS SDK's leave() default.
## Before, it only closed the socket: the server saw a drop, held the seat for
## allowReconnection(), and the client got 1000 instead of 4000.

var client: Colyseus.Client
var rooms: Array = []

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func after_each():
	for r in rooms:
		if r and r.connected:
			r.leave()
	for i in 30:
		Colyseus.poll()
		OS.delay_msec(10)
	rooms.clear()

func _wait(cond: Callable, timeout_ms := 5000) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > timeout_ms:
			return false
		Colyseus.poll()
		await get_tree().process_frame
	return true

func test_leave_is_consented():
	var a: Colyseus.Room = client.create("test_room", {"private": true})
	rooms.append(a)
	assert_true(await _wait(func(): return a.connected), "A should join")
	if not a.connected:
		return

	var b: Colyseus.Room = client.join_by_id(a.get_id())
	rooms.append(b)
	assert_true(await _wait(func(): return b.connected), "B should join A's room")
	if not b.connected:
		return

	var a_session := a.get_session_id()
	var present := {}
	var removed := []
	var b_callbacks := Colyseus.Callbacks.of(b)
	b_callbacks.on_add("players", func(_p, key): present[str(key)] = true)
	b_callbacks.on_remove("players", func(_p, key): removed.append(str(key)))
	assert_true(await _wait(func(): return present.has(a_session)), "B should see A")

	var codes := []
	a.left.connect(func(code, _reason): codes.append(code))
	a.leave()

	assert_true(await _wait(func(): return not codes.is_empty(), 3000), "A should get `left`")
	assert_eq(codes[0] if not codes.is_empty() else -1, 4000, "consented leave closes with CLOSE_CONSENTED (4000)")
	assert_true(await _wait(func(): return removed.has(a_session), 3000),
		"the server should run onLeave now — a drop would hold A's seat for allowReconnection(10s)")
