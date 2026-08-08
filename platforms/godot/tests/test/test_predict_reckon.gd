extends GutTest
## Dead reckoning with a GDScript step — lab-bots, live server. The no-op
## step proves the binding machinery (Callable fires per substep over the
## scratch, value()/value_at() read it back); the real mover port arrives
## with the playground app.

var client: Colyseus.Client
var room: Colyseus.Room
var _joined := false
var _step_calls := 0
var _last_dt := 0.0
var _last_elapsed := 0.0

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:5173")

func after_all():
	client = null

func before_each():
	room = null
	_joined = false
	_step_calls = 0
	_last_dt = 0.0
	_last_elapsed = 0.0

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null

func _on_joined(): _joined = true

func _join_and_wait() -> bool:
	room = client.create("lab-bots")
	if not room:
		return false
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		OS.delay_msec(10)
	return _joined

func _bot1():
	var state = room.get_state()
	if state is Dictionary and state.get("bots") is Dictionary:
		return state.get("bots").get("bot1")
	return null

## A holding-still mover: the scratch keeps its snapshot values, so the
## reckoned present must equal the decoded snapshot exactly.
func _noop_step(s, dt: float, elapsed_ms: float) -> void:
	_step_calls += 1
	_last_dt = dt
	_last_elapsed = elapsed_ms
	var _touch = s.x   # reads go through the view into the scratch

func test_reckon_step_drives_the_scratch():
	assert_true(await _join_and_wait(), "should join lab-bots (is pnpm dev --host 0.0.0.0 up?)")

	var predict = Colyseus.Predict.of(room)
	predict.attach_all_reckon("bots", ["x", "y"], _noop_step, { "smoothing": 0.0 })

	var input = room.input()   # inputs feed the clock (reckon horizon needs it)
	assert_not_null(input, "lab-bots declares defineInput")

	var start = Time.get_ticks_msec()
	var bot = null
	while bot == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		bot = _bot1()
		OS.delay_msec(10)
	assert_not_null(bot, "bot1 should arrive")
	if bot == null:
		return

	# Drive ~1.2 s so the clock syncs and reckon reads happen per frame.
	var last_send = 0
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 2000:
		Colyseus.poll()
		var now = Time.get_ticks_msec()
		if now - last_send >= 50:
			last_send = now
			input.data.moveX = 0
			input.data.moveY = 0
			input.send()
		predict.tick(float(now))
		var _x = predict.value(bot, "x")
		OS.delay_msec(5)

	assert_gt(_step_calls, 10, "the GDScript step should run per reckon substep")
	assert_gt(_last_dt, 0.0, "dt reaches the step")
	assert_gt(_last_elapsed, 0.0, "elapsed_ms reaches the step")

	# A holding-still mover reckons to exactly the snapshot.
	var raw := 0.0
	var fresh = room.get_state()
	if fresh is Dictionary and fresh.get("bots") is Dictionary:
		raw = float(fresh.get("bots").get("bot1").get("x", 0.0))
	var reckoned = predict.value(bot, "x")
	assert_false(is_nan(reckoned), "reckoned read must not be NAN")
	assert_almost_eq(reckoned, raw, 1.5, "no-op reckon equals the decoded snapshot")

	# value_at at the snapshot instant is the snapshot itself.
	var at_stamp = predict.value_at(bot, "x", room.clock.last_server_time())
	assert_almost_eq(at_stamp, raw, 1.5, "value_at(last stamp) is the snapshot")
