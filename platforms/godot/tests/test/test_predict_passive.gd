extends GutTest
## Passive predict (attach_all + value) — needs the Prediction Playground dev
## server (`pnpm dev --host 0.0.0.0`). lab-bots runs a server-driven bot at
## the patch rate; the lerp timeline must render it smoothly BETWEEN patches.

var client: Colyseus.Client
var room: Colyseus.Room
var _joined := false

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:5173")

func after_all():
	client = null

func before_each():
	room = null
	_joined = false

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
	if state == null:
		return null
	if state is Dictionary:
		var bots = state.get("bots")
		if bots is Dictionary:
			return bots.get("bot1")
		if bots != null and bots.has_method("get_item"):
			return bots.get_item("bot1")
		return null
	var bots = state.get("bots")
	if bots != null and bots.has_method("get_item"):
		return bots.get_item("bot1")
	return null

func test_lerp_tracks_the_bot_between_patches():
	assert_true(await _join_and_wait(), "should join lab-bots (is pnpm dev --host 0.0.0.0 up?)")

	var predict = Colyseus.Predict.of(room)
	assert_not_null(predict._native, "room.predict() should create a native Predict")
	predict.attach_all("bots", {
		"x": { "mode": Colyseus.Predict.LERP, "delay": 100 },
		"y": { "mode": Colyseus.Predict.LERP, "delay": 100 },
	})

	# Inputs feed the clock: one send per fixed tick = one RTT/offset sample.
	var input = room.input()
	assert_not_null(input, "lab-bots declares defineInput")

	# Wait for the bot entry to decode.
	var start = Time.get_ticks_msec()
	var bot = null
	while bot == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		bot = _bot1()
		OS.delay_msec(10)
	assert_not_null(bot, "bot1 should arrive in state.bots")
	if bot == null:
		return

	# Drive ~1.6 s: poll, send an input per 50 ms tick, tick the predict, and
	# sample the lerp read every frame.
	var samples: Array[float] = []
	var last_send = 0
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 1600:
		Colyseus.poll()
		var now = Time.get_ticks_msec()
		if now - last_send >= 50:
			last_send = now
			input.data.moveX = 0
			input.data.moveY = 0
			input.send()
		predict.tick(float(now))
		samples.append(predict.value(bot, "x"))
		OS.delay_msec(5)

	# The read is live, finite, in-arena, and actually MOVING (the bot drives).
	var moved := 0
	var distinct := {}
	for i in range(1, samples.size()):
		assert_false(is_nan(samples[i]), "lerp read must never be NAN once tracked")
		assert_between(samples[i], -1.0, 101.0, "lerp x stays in the arena")
		if absf(samples[i] - samples[i - 1]) > 0.0001:
			moved += 1
		distinct[snappedf(samples[i], 0.01)] = true
	assert_gt(moved, 20, "the lerp timeline should advance between frames")
	# Smooth means MANY distinct values, not one jump per patch (~30 patches in
	# this window; a raw read would show ~30 plateaus).
	assert_gt(distinct.size(), 60, "lerp should interpolate between patch samples")

	# Unknown fields answer NAN — a typo can't render as a plausible 0.
	assert_true(is_nan(predict.value(bot, "nope")), "unknown field must read NAN")

func test_value_falls_back_to_raw_when_untracked():
	assert_true(await _join_and_wait(), "should join lab-bots")
	var predict = Colyseus.Predict.of(room)

	var start = Time.get_ticks_msec()
	var bot = null
	while bot == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		bot = _bot1()
		OS.delay_msec(10)
	assert_not_null(bot, "bot1 should arrive")
	if bot == null:
		return

	var x = predict.value(bot, "x")
	assert_false(is_nan(x), "untracked declared field reads the decoded value")
	assert_between(x, -1.0, 101.0, "raw fallback x is the decoded position")
