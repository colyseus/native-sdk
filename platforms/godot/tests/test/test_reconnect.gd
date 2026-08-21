extends GutTest
## Automatic Reconnection Tests
##
## Exercises the drop → reconnect → flush-queued-messages path against the
## sdks-test-server. The server's `force_drop` handler closes the WebSocket
## with code 4010 (MAY_TRY_RECONNECT), which the native SDK treats as a
## recoverable drop. `allowReconnection(client, 10)` on the server side keeps
## the session alive long enough for the worker to come back.

var client: Colyseus.Client
var room: Colyseus.Room

var _joined := false
var _dropped := false
var _reconnected := false
var _left := false
var _left_code := 0
var _echo_received := false
var _echo_payload = null

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func before_each():
	room = null
	_joined = false
	_dropped = false
	_reconnected = false
	_left = false
	_left_code = 0
	_echo_received = false
	_echo_payload = null

func after_each():
	if room and room.connected:
		room.leave()
		var start = Time.get_ticks_msec()
		while not _left and (Time.get_ticks_msec() - start) < 1500:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null

func _on_joined(): _joined = true
func _on_dropped(_code, _reason): _dropped = true
func _on_reconnected(): _reconnected = true
func _on_left(code, _reason):
	_left = true
	_left_code = code
func _on_message(type, data):
	if type == "tagged_echo":
		_echo_received = true
		_echo_payload = data

func _join_and_wait() -> bool:
	room = client.join_or_create("test_room")
	if not room:
		return false
	room.joined.connect(_on_joined)
	room.dropped.connect(_on_dropped)
	room.reconnected.connect(_on_reconnected)
	room.left.connect(_on_left)
	room.message_received.connect(_on_message)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		OS.delay_msec(10)
	return _joined

func _poll_until(predicate: Callable, timeout_ms: int) -> bool:
	var start = Time.get_ticks_msec()
	while not predicate.call() and (Time.get_ticks_msec() - start) < timeout_ms:
		Colyseus.poll()
		OS.delay_msec(10)
	return predicate.call()

# =============================================================================

func test_drop_triggers_dropped_signal_and_automatic_reconnect():
	assert_true(await _join_and_wait(), "Should join test_room")

	# Tighten reconnection so the test runs in a few seconds rather than the
	# default 15-retry backoff window.
	room.set_reconnection_options({
		"min_uptime_ms": 0,
		"min_delay_ms": 100,
		"max_delay_ms": 500,
		"delay_ms": 100,
		"max_retries": 5,
	})

	room.send_message("force_drop")

	var dropped_ok := _poll_until(func(): return _dropped, 5000)
	assert_true(dropped_ok, "dropped signal should fire after server-side close 4010")
	assert_true(room.reconnecting, "room.reconnecting should be true while retrying")

	var reconnected_ok := _poll_until(func(): return _reconnected, 10000)
	assert_true(reconnected_ok, "reconnected signal should fire once the worker re-joins")
	assert_false(room.reconnecting, "room.reconnecting should clear after a successful reconnect")
	assert_false(_left, "left signal must NOT fire on a recoverable drop")

func test_queued_message_flushes_after_reconnect():
	assert_true(await _join_and_wait(), "Should join test_room")

	room.set_reconnection_options({
		"min_uptime_ms": 0,
		"min_delay_ms": 100,
		"max_delay_ms": 500,
		"delay_ms": 100,
		"max_retries": 5,
	})

	room.send_message("force_drop")
	assert_true(_poll_until(func(): return _dropped, 5000), "Should drop")

	# Send while the transport is closed — the SDK should enqueue this and
	# flush it as soon as the JOIN_ROOM completes on the new transport.
	var payload := {"payload": "queued-while-down"}
	var json := JSON.stringify(payload)
	room.send_message("echo", json.to_utf8_buffer())

	assert_true(_poll_until(func(): return _reconnected, 10000), "Should reconnect")
	assert_true(_poll_until(func(): return _echo_received, 5000),
		"tagged_echo from the buffered echo should arrive after reconnect")

func test_disabled_reconnection_routes_drop_to_left():
	assert_true(await _join_and_wait(), "Should join test_room")
	room.set_reconnection_options({"enabled": false})

	room.send_message("force_drop")

	# With reconnection disabled, the close handler should bypass the drop
	# branch entirely and fire `left` directly with the original 4010 code.
	var left_ok := _poll_until(func(): return _left, 5000)
	assert_true(left_ok, "Disabled reconnection should fire 'left' on drop")
	assert_false(_dropped, "'dropped' must not fire when reconnection is disabled")
	assert_false(_reconnected, "'reconnected' must not fire when reconnection is disabled")

func test_manual_reconnect_with_room_token():
	assert_true(await _join_and_wait(), "Should join test_room")
	room.set_reconnection_options({"enabled": false})

	var token := room.get_reconnection_token()
	var session_id := room.get_session_id()
	assert_true(token.contains(":"), "token should be roomId:token, got '%s'" % token)

	room.send_message("force_drop")
	assert_true(_poll_until(func(): return _left, 5000), "Should leave on drop")

	# the server holds the seat for 10s (allowReconnection) — take it back
	_joined = false
	_left = false
	room = client.reconnect(token)
	assert_not_null(room, "reconnect() should return a room")
	room.joined.connect(_on_joined)
	room.left.connect(_on_left)
	assert_true(_poll_until(func(): return _joined, 5000), "Should rejoin with the room's token")
	assert_eq(room.get_session_id(), session_id, "Should resume the same session")
