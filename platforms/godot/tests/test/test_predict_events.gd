extends GutTest
## Optimistic events (define_event + ctx.predict) — lab-goal, live server.
## The GOAL fires the instant the PREDICTED square crosses the line (sim-born,
## live-step-only), then settles: server broadcast -> confirm; at a 100 % deny
## rate the grace-tick auto-reject retracts it.

const SQRT1_2 := 0.70710678118654752440
const GOAL_X := 92.0
const GOAL_Y := 21.0
const GOAL_H := 18.0
const COOLDOWN_TICKS := 50

var client: Colyseus.Client
var room: Colyseus.Room
var _joined := false
var _predicted := 0
var _confirmed := 0
var _rejected := 0
var _goals   # EventChannel — the step callable reaches it through self

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:5173")

func after_all():
	client = null

func before_each():
	room = null
	_joined = false
	_predicted = 0
	_confirmed = 0
	_rejected = 0
	_goals = null

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null

func _on_joined(): _joined = true

func _join_and_wait() -> bool:
	room = client.create("lab-goal")
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

## stepEntity + the shared score gate, with the sim-born event.
func _goal_step(ctx, s, cmd) -> void:
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

	# shared/goal.ts stepScoreGate over the reconciled tick field.
	var ticks := int(s.scoreTicks)
	if ticks > 0:
		s.scoreTicks = float(ticks - 1)
	elif s.x >= GOAL_X and s.y >= GOAL_Y and s.y <= GOAL_Y + GOAL_H:
		s.scoreTicks = float(COOLDOWN_TICKS)
		ctx.predict(_goals, "goal")   # live-only; replays never re-fire

func _drive(predict, input, recon, ms: int) -> void:
	var start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < ms:
		Colyseus.poll()
		var now = Time.get_ticks_msec()
		var y = recon.value("y")
		var steps = predict.tick(float(now))
		for i in steps:
			input.data.moveX = 1
			input.data.moveY = 1 if 30.0 - y > 2.0 else (-1 if 30.0 - y < -2.0 else 0)
			input.send()
		OS.delay_msec(5)

func test_events_fire_instantly_then_settle():
	assert_true(await _join_and_wait(), "should join lab-goal (is pnpm dev --host 0.0.0.0 up?)")

	var start = Time.get_ticks_msec()
	var me = null
	while me == null and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		me = _me()
		OS.delay_msec(10)
	assert_not_null(me, "own player should decode")
	if me == null:
		return

	var input = room.input()
	var predict = Colyseus.Predict.of(room)
	_goals = predict.define_event({
		"on_predict": func(_key): _predicted += 1,
		"on_confirm": func(_key): _confirmed += 1,
		"on_reject": func(_key): _rejected += 1,
	})
	assert_not_null(_goals, "define_event should create a channel")

	# The server's goal broadcast is the authoritative confirm signal.
	room.message_received.connect(func(type, data):
		if type == "goal" and data is Dictionary and data.get("sid") == room.get_session_id():
			_goals.confirm())

	var recon = predict.reconciler(me, {
		"input": input,
		"fields": ["x", "y", "vx", "vy", "scoreTicks"],
		"smooth_ms": 66.67,
		"step": _goal_step,
	})
	assert_not_null(recon, "reconciler should build")
	if recon == null:
		return

	# Deny nothing: every optimistic banner must be confirmed.
	room.send_message("denyRate", {"rate": 0})
	_drive(predict, input, recon, 7000)
	assert_gt(_predicted, 0, "never entered the goal zone")
	assert_gt(_confirmed, 0, "no optimistic goal was ever confirmed")
	assert_eq(_rejected, 0, "goals rejected at a 0 % deny rate")
	var clean_run := _predicted

	# Deny everything: the banner still fires instantly, then retracts via
	# the grace-tick auto-reject.
	room.send_message("denyRate", {"rate": 100})
	_drive(predict, input, recon, 9000)
	assert_gt(_predicted, clean_run, "the optimistic prediction stopped firing under denies")
	assert_gt(_rejected, 0, "server denied every goal but nothing was rejected")
