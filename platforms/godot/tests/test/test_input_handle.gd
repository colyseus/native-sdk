extends GutTest
## Input handle + room clock (predict layer, phase 1) — needs the Prediction
## Playground dev server: `pnpm dev --host 0.0.0.0` (ws://127.0.0.1:5173).
## The lab-move room declares defineInput(), so the handle's schema arrives
## via INPUT_REFLECTION — nothing is declared on this side.

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
	room = client.create("lab-move")   # private room — no other players
	if not room:
		return false
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		OS.delay_msec(10)
	return _joined

## Drive the room for `ms`, sending one input per 50 ms tick with the given axes.
func _drive(input, ms: int, move_x: int, move_y: int) -> void:
	var start = Time.get_ticks_msec()
	var last_send = 0
	while (Time.get_ticks_msec() - start) < ms:
		Colyseus.poll()
		var now = Time.get_ticks_msec()
		if now - last_send >= 50:
			last_send = now
			input.data.moveX = move_x
			input.data.moveY = move_y
			input.send()
		OS.delay_msec(5)

func test_input_handle_round_trip():
	assert_true(await _join_and_wait(), "should join lab-move (is pnpm dev --host 0.0.0.0 up?)")

	var input = room.input()
	assert_not_null(input, "room.input() should synthesize a handle from INPUT_REFLECTION")
	if input == null:
		return

	# The server advertises its fixed-step rates in the handshake.
	assert_eq(input.tick_rate, 20, "lab-move advertises a 20 Hz tick")

	# Seqs are 1-based and monotonically increasing.
	input.data.moveX = 1
	input.data.moveY = 0
	var seq1 = input.send()
	assert_eq(seq1, 1, "first send should be seq 1")
	assert_eq(input.data.moveX, 1.0, "staged field should read back")

	_drive(input, 1200, 1, 0)

	# Acks flow back on the TIMED prefix: pending drains, the clock syncs.
	assert_gt(input.sent_count, 5, "sends should accumulate at the tick cadence")
	assert_gt(input.last_processed, 0, "server acks should advance last_processed")
	assert_lt(input.pending_count, input.sent_count, "acks should drain the pending window")
	assert_gt(room.clock.rtt(), 0.0, "the ack round trip should produce an RTT sample")
	assert_gt(room.clock.last_server_time(), 0.0, "patches should carry the server stamp")
	assert_gt(room.clock.patch_interval(), 0.0, "patch cadence should be advertised")
	assert_gt(room.clock.server_now(), room.clock.last_server_time() - 1.0,
		"serverNow extrapolates forward from the last stamp")

	# And the input actually moved us: lab-move applies moveX=1 as +x drive.
	var state = room.get_state()
	assert_not_null(state, "state should have decoded")
	var sid = room.get_session_id()
	var me = _player_of(state, sid)
	assert_not_null(me, "own player should be in state.players")
	if me != null:
		assert_gt(_x_of(me), 10.0, "driving right for 1.2 s should move x past spawn")

func test_same_handle_on_later_calls():
	assert_true(await _join_and_wait(), "should join lab-move")
	var a = room.input()
	var b = room.input()
	assert_not_null(a, "handle should exist")
	assert_eq(a, b, "input() must return the same handle (options: first call wins)")

# --- state shape helpers: reflection state may surface as Dictionary or object

func _player_of(state, sid: String):
	if state is Dictionary:
		var players = state.get("players")
		if players is Dictionary:
			return players.get(sid)
		if players != null and players.has_method("get_item"):
			return players.get_item(sid)
		return null
	var players = state.get("players") if state.has_method("get") else null
	if players != null and players.has_method("get_item"):
		return players.get_item(sid)
	return null

func _x_of(player) -> float:
	if player is Dictionary:
		return float(player.get("x", 0.0))
	return float(player.x)
