extends GutTest
## Drop → auto-reconnect → predict-stack recovery — lab-move, live server.
## room.drop() kills the socket uncleanly (4010): the SDK must treat it as a
## DROP (dropped signal, not left), auto-reconnect (reconnected signal), and
## reset the input handle — the epoch bump makes reconcilers self-reset, so
## after rebinding the re-decoded player the drift must re-converge.

const SQRT1_2 := 0.70710678118654752440

var client: Colyseus.Client
var room: Colyseus.Room
var _joined := false
var _dropped := false
var _reconnected := false
var _left := false

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:5173")

func after_all():
	client = null

func before_each():
	room = null
	_joined = false
	_dropped = false
	_reconnected = false
	_left = false

func after_each():
	if room and room.connected:
		room.set_latency(0.0)
		for i in 40:
			Colyseus.poll()
			room.net_pump()
			OS.delay_msec(10)
		room.leave()
		for i in 40:
			Colyseus.poll()
			room.net_pump()
			OS.delay_msec(10)
	room = null

func _join_and_wait() -> bool:
	room = client.create("lab-move")
	if not room:
		return false
	room.joined.connect(func(): _joined = true)
	room.dropped.connect(func(_code, _reason): _dropped = true)
	room.reconnected.connect(func(): _reconnected = true)
	room.left.connect(func(_code, _reason): _left = true)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		OS.delay_msec(10)
	if _joined:
		# fast reconnection for the test — defaults gate on 5 s of uptime
		room.set_reconnection_options({
			"min_uptime_ms": 500, "min_delay_ms": 100, "max_delay_ms": 500,
		})
	return _joined

func _me():
	var state = room.get_state()
	if state is Dictionary and state.get("players") is Dictionary:
		return state.get("players").get(room.get_session_id())
	return null

func _wait_me(timeout_ms: int = 5000):
	var start = Time.get_ticks_msec()
	var me = null
	while me == null and (Time.get_ticks_msec() - start) < timeout_ms:
		Colyseus.poll()
		room.net_pump()
		me = _me()
		OS.delay_msec(10)
	return me

func _step(ctx, s, cmd) -> void:
	var ax := float(cmd.moveX)
	var ay := float(cmd.moveY)
	if ax != 0.0 and ay != 0.0:
		ax *= SQRT1_2
		ay *= SQRT1_2
	if ax != 0.0 or ay != 0.0:
		s.vx += ax * 220.0 * ctx.dt
		s.vy += ay * 220.0 * ctx.dt
	else:
		s.vx *= 0.72
		s.vy *= 0.72
		if s.vx > -0.05 and s.vx < 0.05: s.vx = 0.0
		if s.vy > -0.05 and s.vy < 0.05: s.vy = 0.0
	var sq = s.vx * s.vx + s.vy * s.vy
	if sq > 34.0 * 34.0:
		var sc = 34.0 / sqrt(sq)
		s.vx *= sc
		s.vy *= sc
	s.x += s.vx * ctx.dt
	s.y += s.vy * ctx.dt
	if s.x < 1.6:
		s.x = 1.6
		if s.vx < 0.0: s.vx = 0.0
	elif s.x > 98.4:
		s.x = 98.4
		if s.vx > 0.0: s.vx = 0.0
	if s.y < 1.6:
		s.y = 1.6
		if s.vy < 0.0: s.vy = 0.0
	elif s.y > 58.4:
		s.y = 58.4
		if s.vy > 0.0: s.vy = 0.0

func _build_recon(predict, input, me):
	return predict.reconciler(me, {
		"input": input,
		"fields": ["x", "y", "vx", "vy"],
		"smoothing": 15.0,
		"step": _step,
	})

func _drive(predict, input, ms: int, mx: int) -> void:
	var start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < ms:
		Colyseus.poll()
		room.net_pump()
		var steps = predict.tick(float(Time.get_ticks_msec()))
		for i in steps:
			input.data.moveX = mx
			input.data.moveY = 0
			input.send()
		OS.delay_msec(5)

func _wait_flag(getter: Callable, timeout_ms: int) -> bool:
	var start = Time.get_ticks_msec()
	while not getter.call() and (Time.get_ticks_msec() - start) < timeout_ms:
		Colyseus.poll()
		room.net_pump()
		OS.delay_msec(10)
	return getter.call()

func _run_drop_cycle(latency_ms: float) -> void:
	assert_true(await _join_and_wait(), "should join lab-move (is pnpm dev --host 0.0.0.0 up?)")
	var me = _wait_me()
	assert_not_null(me, "own player should decode")
	if me == null:
		return

	var input = room.input()
	var predict = Colyseus.Predict.of(room)
	if latency_ms > 0.0:
		room.set_latency(latency_ms)
	var recon = _build_recon(predict, input, me)
	assert_not_null(recon, "reconciler should build")

	# settle in past min-uptime, predicting cleanly
	_drive(predict, input, 1500, 1)
	assert_lt(recon.drift_ema, 0.01, "pre-drop drift should be at wire precision")
	var epoch_before: int = input.epoch

	# the unclean kill: a DROP, not a leave
	room.drop()
	assert_true(_wait_flag(func(): return _dropped, 5000), "dropped signal should fire")
	assert_false(_left, "an injected drop must not read as a consented leave")

	# ...and the SDK reconnects on its own
	assert_true(_wait_flag(func(): return _reconnected, 15000),
		"auto-reconnect should succeed (reconnected signal)")
	assert_gt(input.epoch, epoch_before,
		"the input handle must reset on reconnect (epoch bump -> reconcilers self-reset)")

	# state re-decoded: REBIND the fresh instance and rebuild, like every
	# other lane's on_reconnect. The fresh transport is unwrapped — re-apply
	# the latency preset.
	if latency_ms > 0.0:
		room.set_latency(latency_ms)
	var me2 = _wait_me()
	assert_not_null(me2, "player should re-decode after reconnect")
	if me2 == null:
		return
	var recon2 = _build_recon(predict, input, me2)
	assert_not_null(recon2, "reconciler should rebuild over the re-decoded player")

	# and the stack must be healthy again: inputs flow, acks reconcile,
	# drift sits back at wire precision with NO stale-backlog replay.
	_drive(predict, input, 2500, -1)
	assert_gt(recon2.reconcile_seq, 5, "acks should drive reconciles after reconnect")
	assert_lt(recon2.drift_ema, 0.01,
		"post-reconnect drift %f — stale pre-drop inputs are replaying" % recon2.drift_ema)

func test_drop_then_reconnect_recovers_the_predict_stack():
	await _run_drop_cycle(0.0)

func test_drop_recovers_under_injected_latency():
	await _run_drop_cycle(200.0)
