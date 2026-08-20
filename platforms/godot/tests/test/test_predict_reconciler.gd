extends GutTest
## Reconciler (rollback) from GDScript — needs the Prediction Playground dev
## server (`pnpm dev --host 0.0.0.0`). The step below is the shared movement
## sim (movement.ts) transliterated to GDScript: same op order, same
## constants, f64 throughout. The server runs the original; steady-state
## corrections must sit at wire precision, and a server-side impulse must
## produce a visible correction that decays.

const SQRT1_2 := 0.70710678118654752440
const ACCEL := 220.0
const MAX_SPEED := 34.0
const FRICTION := 0.72
const HALF := 1.6
const ARENA_W := 100.0
const ARENA_H := 60.0

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
	room = client.create("lab-move")
	if not room:
		return false
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		OS.delay_msec(10)
	return _joined

func _me():
	var state = room.get_state()
	if state == null:
		return null
	var players = state.get("players") if state is Dictionary else null
	if players is Dictionary:
		return players.get(room.get_session_id())
	return null

## shared/movement.ts stepEntity — the deterministic step both sides run.
func _step(ctx, s, _cmd) -> void:
	var ax := float(_cmd.moveX)
	var ay := float(_cmd.moveY)
	if ax != 0.0 and ay != 0.0:
		ax *= SQRT1_2
		ay *= SQRT1_2
	if ax != 0.0 or ay != 0.0:
		s.vx += ax * ACCEL * ctx.dt
		s.vy += ay * ACCEL * ctx.dt
	else:
		s.vx *= FRICTION
		s.vy *= FRICTION
		if s.vx > -0.05 and s.vx < 0.05: s.vx = 0.0
		if s.vy > -0.05 and s.vy < 0.05: s.vy = 0.0
	var sq = s.vx * s.vx + s.vy * s.vy
	if sq > MAX_SPEED * MAX_SPEED:
		var sc = MAX_SPEED / sqrt(sq)
		s.vx *= sc
		s.vy *= sc
	s.x += s.vx * ctx.dt
	s.y += s.vy * ctx.dt
	if s.x < HALF:
		s.x = HALF
		if s.vx < 0.0: s.vx = 0.0
	elif s.x > ARENA_W - HALF:
		s.x = ARENA_W - HALF
		if s.vx > 0.0: s.vx = 0.0
	if s.y < HALF:
		s.y = HALF
		if s.vy < 0.0: s.vy = 0.0
	elif s.y > ARENA_H - HALF:
		s.y = ARENA_H - HALF
		if s.vy > 0.0: s.vy = 0.0

func test_reconciler_predicts_and_absorbs_an_impulse():
	assert_true(await _join_and_wait(), "should join lab-move (is pnpm dev --host 0.0.0.0 up?)")

	# Wait for our player entry.
	var start = Time.get_ticks_msec()
	var me = null
	while me == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		me = _me()
		OS.delay_msec(10)
	assert_not_null(me, "own player should decode into state.players")
	if me == null:
		return

	var input = room.input()
	var predict = Colyseus.Predict.of(room)
	var recon = predict.reconciler(me, {
		"input": input,
		"fields": ["x", "y", "vx", "vy"],
		"smooth_ms": 66.67,
		"step": _step,
	})
	assert_not_null(recon, "predict.reconciler should build over the decoded player")
	if recon == null:
		return

	# Drive right for ~2.5 s. predict.tick paces the sends: one input per
	# fixed step, exactly like every other port's shell.
	var max_pending := 0
	var start_x: float = recon.value("x")
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 2500:
		Colyseus.poll()
		var steps = predict.tick(float(Time.get_ticks_msec()))
		for i in steps:
			input.data.moveX = 1
			input.data.moveY = 0
			input.send()
		max_pending = maxi(max_pending, recon.pending_count)
		OS.delay_msec(5)

	# Predicted while inputs are in flight, reconciled against acks, and the
	# GDScript step agrees with the server's at wire precision.
	assert_gt(max_pending, 0, "inputs should be predicted while unacked")
	assert_gt(recon.reconcile_seq, 10, "acks should drive reconciles")
	assert_gt(recon.value("x"), start_x + 5.0, "driving right must move the prediction")
	assert_lt(recon.drift_ema, 0.01,
		"drift ema %f — the GDScript step disagrees with the server's" % recon.drift_ema)
	assert_lt(recon.last_correction_mag, 0.05, "steady state should be correction-free")

	# state view: the mirror reads like a plain object.
	var s = recon.state
	assert_not_null(s, "state view should exist")
	assert_almost_eq(float(s.x), recon.value("x"), 2.0, "mirror x tracks the rendered value")

	# A server-side shove the client cannot see coming MUST mispredict...
	room.send_message("impulse", null)
	var peak := 0.0
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 1500:
		Colyseus.poll()
		var steps = predict.tick(float(Time.get_ticks_msec()))
		for i in steps:
			input.data.moveX = 0
			input.data.moveY = 0
			input.send()
		peak = maxf(peak, recon.last_correction_mag)
		OS.delay_msec(5)
	assert_gt(peak, 0.05, "the impulse produced no visible correction")

	# ...and then decay back to steady state.
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 4000:
		Colyseus.poll()
		var steps = predict.tick(float(Time.get_ticks_msec()))
		for i in steps:
			input.data.moveX = 1
			input.data.moveY = 0
			input.send()
		OS.delay_msec(5)
	assert_lt(recon.last_correction_mag, 0.05,
		"corrections still %f after 4 s — not converging" % recon.last_correction_mag)

func test_tick_without_a_timestamp_drives_from_the_room_clock():
	assert_true(await _join_and_wait(), "should join lab-move (is pnpm dev --host 0.0.0.0 up?)")

	var start = Time.get_ticks_msec()
	var me = null
	while me == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		me = _me()
		OS.delay_msec(10)
	assert_not_null(me, "own player should decode into state.players")
	if me == null:
		return

	var input = room.input()
	var predict = Colyseus.Predict.of(room)
	var recon = predict.reconciler(me, {
		"input": input,
		"fields": ["x", "y", "vx", "vy"],
		"smooth_ms": 66.67,
		"step": _step,
	})
	assert_not_null(recon, "predict.reconciler should build over the decoded player")
	if recon == null:
		return

	# The same drive loop, minus the timestamp. An omitted now_ms has to come
	# back on the room clock's axis, or the step budget stops matching the
	# server's cadence and the prediction drifts off it.
	var start_x: float = recon.value("x")
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 2500:
		Colyseus.poll()
		var steps = predict.tick()
		for i in steps:
			input.data.moveX = 1
			input.data.moveY = 0
			input.send()
		OS.delay_msec(5)

	assert_gt(recon.reconcile_seq, 10, "acks should drive reconciles")
	assert_gt(recon.value("x"), start_x + 5.0, "driving right must move the prediction")
	assert_lt(recon.drift_ema, 0.01,
		"drift ema %f — the defaulted tick is off-axis" % recon.drift_ema)
