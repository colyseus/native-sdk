extends GutTest
## Predicted spawns — lab-projectile, live server. Click-to-fire spawns an
## optimistic LOCAL the same frame; when the authoritative entity arrives the
## store CORRELATES the two into one logical entry (same id) and measures the
## shot's input lead. value(id, field) spans the handoff.

const SQRT1_2 := 0.70710678118654752440

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
	room = client.create("lab-projectile")
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
	if state is Dictionary and state.get("players") is Dictionary:
		return state.get("players").get(room.get_session_id())
	return null

func _move_step(ctx, s, cmd) -> void:
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

## shared/projectile.ts — constant-velocity flight with wall bounces.
func _shot_step(local: Dictionary, dt: float) -> void:
	local["x"] = float(local["x"]) + float(local["vx"]) * dt
	local["y"] = float(local["y"]) + float(local["vy"]) * dt
	if float(local["x"]) < 0.0:
		local["x"] = 0.0
		local["vx"] = absf(float(local["vx"]))
	elif float(local["x"]) > 100.0:
		local["x"] = 100.0
		local["vx"] = -absf(float(local["vx"]))
	if float(local["y"]) < 0.0:
		local["y"] = 0.0
		local["vy"] = absf(float(local["vy"]))
	elif float(local["y"]) > 60.0:
		local["y"] = 60.0
		local["vy"] = -absf(float(local["vy"]))

func test_optimistic_spawn_hands_off_to_the_server():
	assert_true(await _join_and_wait(), "should join lab-projectile (is pnpm dev --host 0.0.0.0 up?)")

	var start = Time.get_ticks_msec()
	var me = null
	while me == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		me = _me()
		OS.delay_msec(10)
	assert_not_null(me, "own player should decode")
	if me == null:
		return

	var sid = room.get_session_id()
	var input = room.input()
	var predict = Colyseus.Predict.of(room)
	var spawns = predict.spawns("projectiles", {
		"owned": func(p): return p.owner == sid,
		"spawn_time": func(p): return p.bornMs,
		"step": _shot_step,
	})
	assert_not_null(spawns, "predict.spawns should bind the collection")
	if spawns == null:
		return

	var recon = predict.reconciler(me, {
		"input": input,
		"fields": ["x", "y", "vx", "vy"],
		"smoothing": 15.0,
		"step": _move_step,
	})
	assert_not_null(recon, "reconciler should build")

	# settle in, then fire ONE shot at (50, 55) from the predicted pose
	var fired := false
	var pending_seen := false
	var fired_id := -1
	start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 3000:
		Colyseus.poll()
		var now = Time.get_ticks_msec()
		var steps = predict.tick(float(now))
		for i in steps:
			input.data.moveX = 0
			input.data.moveY = 0
			input.data.aimX = 50.0
			input.data.aimY = 55.0
			var do_fire = not fired and (now - start) > 800
			input.data.fire = 1.0 if do_fire else 0.0
			input.send()
			if do_fire:
				fired = true
				var px = recon.state.x
				var py = recon.state.y
				var dx = 50.0 - px
				var dy = 55.0 - py
				var len = sqrt(dx * dx + dy * dy)
				if len < 1e-9: len = 1.0
				fired_id = spawns.spawn({
					"x": px, "y": py,
					"vx": dx / len * 34.0, "vy": dy / len * 34.0,
				})
		# right after firing there must be a pending local — that IS the feature
		if fired and not pending_seen:
			for e in spawns.entries():
				if e["id"] == fired_id and e["has_local"] and not e["confirmed"]:
					pending_seen = true
					var x = spawns.value(e["id"], "x")
					assert_false(is_nan(x), "pending local must read through value()")
		OS.delay_msec(5)

	assert_true(fired, "the shot should have fired")
	assert_true(pending_seen, "fired but nothing was pending — the optimistic local never appeared")

	# by now the server's entity has arrived and correlated onto the SAME id
	var confirmed := false
	var lead := 0.0
	for e in spawns.entries():
		if e["id"] == fired_id and e["confirmed"]:
			confirmed = true
			lead = e["lead_ms"]
			assert_eq(spawns.server_string(e["id"], "owner"), sid,
				"the correlated server entity should be OURS")
			var x = spawns.value(e["id"], "x")
			assert_false(is_nan(x), "confirmed entry must read through value()")
	assert_true(confirmed, "the server's projectile never correlated")
	assert_gt(lead, 0.0, "no input lead was measured — spawn_time is not wired")
