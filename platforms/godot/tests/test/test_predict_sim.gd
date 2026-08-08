extends GutTest
## SimReconciler (composite face) from GDScript — lab-hockey, live server.
## One rollback over three parts: my paddle, the puck, AND the AI paddle,
## stepped in the server's exact order. shared/hockey.ts transliterated below.
## The scenario-C shape: bound mirrors adopt truth every reconcile, poses come
## back as predict.value(instance, field) and "part.field".

const SQRT1_2 := 0.70710678118654752440
const ACCEL := 220.0
const MAX_SPEED := 34.0
const FRICTION := 0.72
const HALF := 1.6
const ARENA_W := 100.0
const ARENA_H := 60.0
const PADDLE_R := 2.2
const PUCK_R := 1.4
const PUCK_FRICTION := 0.985
const PUCK_RESTITUTION := 0.92
const PUCK_PUSH_MIN := 14.0

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
	room = client.create("lab-hockey")
	if not room:
		return false
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		OS.delay_msec(10)
	return _joined

func _state_bits() -> Array:
	var state = room.get_state()
	if state == null or not (state is Dictionary):
		return [null, null, null]
	var players = state.get("players")
	var puck = state.get("puck")
	if not (players is Dictionary):
		return [null, null, null]
	return [players.get(room.get_session_id()), puck, players.get("bot")]

func _step_paddle(p, mx: float, my: float, dt: float) -> void:
	var ax := mx
	var ay := my
	if ax != 0.0 and ay != 0.0:
		ax *= SQRT1_2
		ay *= SQRT1_2
	if ax != 0.0 or ay != 0.0:
		p.vx += ax * ACCEL * dt
		p.vy += ay * ACCEL * dt
	else:
		p.vx *= FRICTION
		p.vy *= FRICTION
		if p.vx > -0.05 and p.vx < 0.05: p.vx = 0.0
		if p.vy > -0.05 and p.vy < 0.05: p.vy = 0.0
	var sq = p.vx * p.vx + p.vy * p.vy
	if sq > MAX_SPEED * MAX_SPEED:
		var sc = MAX_SPEED / sqrt(sq)
		p.vx *= sc
		p.vy *= sc
	p.x += p.vx * dt
	p.y += p.vy * dt
	if p.x < HALF:
		p.x = HALF
		if p.vx < 0.0: p.vx = 0.0
	elif p.x > ARENA_W - HALF:
		p.x = ARENA_W - HALF
		if p.vx > 0.0: p.vx = 0.0
	if p.y < HALF:
		p.y = HALF
		if p.vy < 0.0: p.vy = 0.0
	elif p.y > ARENA_H - HALF:
		p.y = ARENA_H - HALF
		if p.vy > 0.0: p.vy = 0.0

func _step_puck(k, dt: float) -> void:
	k.vx *= PUCK_FRICTION
	k.vy *= PUCK_FRICTION
	k.x += k.vx * dt
	k.y += k.vy * dt
	if k.x < PUCK_R:
		k.x = PUCK_R
		k.vx = absf(k.vx) * PUCK_RESTITUTION
	elif k.x > ARENA_W - PUCK_R:
		k.x = ARENA_W - PUCK_R
		k.vx = -absf(k.vx) * PUCK_RESTITUTION
	if k.y < PUCK_R:
		k.y = PUCK_R
		k.vy = absf(k.vy) * PUCK_RESTITUTION
	elif k.y > ARENA_H - PUCK_R:
		k.y = ARENA_H - PUCK_R
		k.vy = -absf(k.vy) * PUCK_RESTITUTION

func _collide(px: float, py: float, pvx: float, pvy: float, k) -> void:
	var dx = k.x - px
	var dy = k.y - py
	var r := PADDLE_R + PUCK_R
	var d2 = dx * dx + dy * dy
	if d2 >= r * r:
		return
	var d = sqrt(d2)
	if d == 0.0: d = 1e-6
	var nx = dx / d
	var ny = dy / d
	k.x = px + nx * r
	k.y = py + ny * r
	var along = pvx * nx + pvy * ny
	var speed = along if along > PUCK_PUSH_MIN else PUCK_PUSH_MIN
	k.vx = nx * speed + pvx * 0.35
	k.vy = ny * speed + pvy * 0.35
	if k.x < PUCK_R:
		k.x = PUCK_R
		k.vx = absf(k.vx) * PUCK_RESTITUTION
	elif k.x > ARENA_W - PUCK_R:
		k.x = ARENA_W - PUCK_R
		k.vx = -absf(k.vx) * PUCK_RESTITUTION
	if k.y < PUCK_R:
		k.y = PUCK_R
		k.vy = absf(k.vy) * PUCK_RESTITUTION
	elif k.y > ARENA_H - PUCK_R:
		k.y = ARENA_H - PUCK_R
		k.vy = -absf(k.vy) * PUCK_RESTITUTION

## The server's step order, reproduced: paddles (bot from PRE-step puck) →
## puck → contacts in players-map order (bot joined first).
func _sim_step(ctx, w, cmd) -> void:
	var pre_px: float = w.puck.x
	var pre_py: float = w.puck.y

	# bot steering: pure function of synced state; bot is DISABLED in this
	# test (we send bot:off) so it homes to (50, 12).
	var tx := ARENA_W / 2.0
	var ty := ARENA_H * 0.2
	var bmx := 1.0 if tx - w.bot.x > 1.0 else (-1.0 if tx - w.bot.x < -1.0 else 0.0)
	var bmy := 1.0 if ty - w.bot.y > 1.0 else (-1.0 if ty - w.bot.y < -1.0 else 0.0)

	_step_paddle(w.paddle, float(cmd.moveX), float(cmd.moveY), ctx.dt)
	_step_paddle(w.bot, bmx, bmy, ctx.dt)
	_step_puck(w.puck, ctx.dt)
	_collide(w.bot.x, w.bot.y, w.bot.vx, w.bot.vy, w.puck)
	_collide(w.paddle.x, w.paddle.y, w.paddle.vx, w.paddle.vy, w.puck)

func test_sim_predicts_the_puck_through_own_inputs():
	assert_true(await _join_and_wait(), "should join lab-hockey (is pnpm dev --host 0.0.0.0 up?)")

	var start = Time.get_ticks_msec()
	var me = null
	var puck = null
	var bot = null
	while (me == null or puck == null or bot == null) and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		var bits = _state_bits()
		me = bits[0]
		puck = bits[1]
		bot = bits[2]
		OS.delay_msec(10)
	assert_not_null(me, "own paddle should decode")
	assert_not_null(puck, "puck should decode")
	assert_not_null(bot, "bot paddle should decode")
	if me == null or puck == null or bot == null:
		return

	room.send_message("bot", {"on": false})   # isolate OUR step

	var input = room.input()
	var predict = Colyseus.Predict.of(room)
	var sim = predict.sim({
		"input": input,
		"world": { "paddle": me, "puck": puck, "bot": bot },
		"smoothing": 15.0,
		"step": _sim_step,
	})
	assert_not_null(sim, "predict.sim should build over paddle+puck+bot")
	if sim == null:
		return

	# Seek/retreat on a fixed schedule (chasing without release pins the puck
	# against a wall and a frozen world reads as perfect agreement).
	var mags: Array[float] = []
	var seq := 0
	var peak_lead := 0.0
	var max_pending := 0
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 9000:
		Colyseus.poll()
		var now = Time.get_ticks_msec()
		var retreat := int(now - start) % 2100 > 1500
		var kx = predict.value(puck, "x")
		var ky = predict.value(puck, "y")
		var mx = predict.value(me, "x")
		var my = predict.value(me, "y")
		var tx = (ARENA_W / 2.0) if retreat else kx
		var ty = (ARENA_H * 0.75) if retreat else ky
		var steps = predict.tick(float(now))
		for i in steps:
			input.data.moveX = 1 if tx - mx > 0.4 else (-1 if tx - mx < -0.4 else 0)
			input.data.moveY = 1 if ty - my > 0.4 else (-1 if ty - my < -0.4 else 0)
			input.send()
		max_pending = maxi(max_pending, sim.pending_count)
		if sim.reconcile_seq != seq:
			seq = sim.reconcile_seq
			mags.append(sim.last_correction_mag)
		var fresh = room.get_state()
		if fresh is Dictionary and fresh.get("puck") is Dictionary:
			var sp = fresh.get("puck")
			var dx = kx - float(sp.get("x", 0.0))
			var dy = ky - float(sp.get("y", 0.0))
			peak_lead = maxf(peak_lead, sqrt(dx * dx + dy * dy))
		OS.delay_msec(5)

	assert_gt(max_pending, 0, "inputs should be predicted while unacked")
	assert_gt(mags.size(), 20, "acks should drive reconciles")

	# The composite point: the puck is predicted THROUGH our inputs, so it
	# must run ahead of the authoritative one around strikes.
	assert_gt(peak_lead, 0.3, "predicted puck never led the server's")

	# The MEDIAN reconcile stays small — the GDScript composite step agrees
	# with the server's (0.5 is the gross-divergence ceiling; wrong puck
	# friction lands at 1.78).
	mags.sort()
	var median: float = mags[(mags.size() - 1) / 2]
	assert_lt(median, 0.5, "median correction %f — composite step disagrees" % median)

	# Bound poses: the overlay read and the pose-key escape hatch agree.
	var via_overlay = predict.value(puck, "x")
	var via_pose_key = sim.value("puck.x")
	assert_almost_eq(via_overlay, via_pose_key, 3.0,
		"predict.value(puck) and sim.value(\"puck.x\") should be the same pose")

	# The world view reads like plain objects outside the step too.
	var w = sim.world
	assert_not_null(w, "sim.world should expose the part views")
	if w != null:
		assert_between(float(w.puck.x), -1.0, 101.0, "w.puck.x reads the mirror")
