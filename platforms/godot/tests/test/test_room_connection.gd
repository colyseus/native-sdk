extends GutTest
## Room Connection & State Sync Tests — connects to sdks-test-server "my_room"

var native_client
var room

# Shared state for signal callbacks (lambdas can't reliably capture locals)
var _joined := false
var _state_changed := false
var _error_received := false
var _error_code := 0
var _left_received := false
var _msg_received := false
var _msg_type := ""
var _msg_data = null
var _join_options_received := false
var _join_options_data = null

func before_all():
	native_client = ClassDB.instantiate(&"ColyseusClient")
	native_client.set_endpoint("ws://127.0.0.1:2567")

func after_all():
	native_client = null

func before_each():
	room = null
	_joined = false
	_state_changed = false
	_error_received = false
	_error_code = 0
	_left_received = false
	_msg_received = false
	_msg_type = ""
	_msg_data = null
	_join_options_received = false
	_join_options_data = null

func after_each():
	if room and room.is_connected():
		room.leave()
		for i in 30:
			ColyseusClient.poll()
			OS.delay_msec(10)
	room = null

func _on_joined(): _joined = true
func _on_state_changed(): _state_changed = true
func _on_error(code, msg): _error_received = true; _error_code = code
func _on_left(code, reason): _left_received = true
func _on_message(type, data):
	if type == "join_options":
		_join_options_received = true
		_join_options_data = data
	# Filter out internal messages
	elif type != "__playground_message_types":
		_msg_received = true
		_msg_type = type
		_msg_data = data

# Helper: join room and poll until joined
func _join_and_wait() -> bool:
	room = native_client.join_or_create("my_room")
	if not room:
		return false
	room.joined.connect(_on_joined)
	room.state_changed.connect(_on_state_changed)
	room.error.connect(_on_error)
	room.left.connect(_on_left)
	room.message_received.connect(_on_message)

	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	return _joined

# Helper: poll until state is available
func _wait_for_state(timeout_ms: int = 3000):
	var start = Time.get_ticks_msec()
	var state = null
	while state == null and (Time.get_ticks_msec() - start) < timeout_ms:
		ColyseusClient.poll()
		state = room.get_state()
		OS.delay_msec(10)
	return state

# =============================================================================
# Connection
# =============================================================================

func test_join_or_create_returns_room():
	room = native_client.join_or_create("my_room")
	assert_not_null(room, "join_or_create should return a room")

func test_join_emits_joined_signal():
	await _join_and_wait()
	assert_true(_joined, "Should receive joined signal")

func test_room_has_id():
	await _join_and_wait()
	assert_gt(room.get_id().length(), 0, "Room should have an ID")

func test_room_has_session_id():
	await _join_and_wait()
	assert_gt(room.get_session_id().length(), 0, "Room should have a session ID")

func test_room_has_name():
	await _join_and_wait()
	assert_eq(room.get_name(), "my_room", "Room name should be my_room")

func test_room_is_connected():
	await _join_and_wait()
	assert_true(room.is_connected(), "Room should be connected")

# =============================================================================
# State
# =============================================================================

func test_state_changed_signal_fires():
	await _join_and_wait()
	# Wait for state_changed signal (state decoding happens internally)
	var start = Time.get_ticks_msec()
	while not _state_changed and (Time.get_ticks_msec() - start) < 3000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_state_changed, "state_changed signal should fire after join")

# =============================================================================
# Messages & State Updates
# =============================================================================

func test_state_changes_on_message():
	await _join_and_wait()
	# Wait for initial state
	var start = Time.get_ticks_msec()
	while not _state_changed and (Time.get_ticks_msec() - start) < 3000:
		ColyseusClient.poll()
		OS.delay_msec(10)

	_state_changed = false
	var msg = {"x": 42, "y": 99}
	var json = JSON.stringify(msg)
	room.send_message("move", json.to_utf8_buffer())

	start = Time.get_ticks_msec()
	while not _state_changed and (Time.get_ticks_msec() - start) < 3000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_state_changed, "State should change after sending move")

func test_receive_broadcast_message():
	await _join_and_wait()

	var start = Time.get_ticks_msec()
	while not _msg_received and (Time.get_ticks_msec() - start) < 6000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_msg_received, "Should receive a broadcast message")
	assert_eq(_msg_type, "weather", "Broadcast should be 'weather' type")

# =============================================================================
# Join with Options
# =============================================================================

func test_join_or_create_with_options():
	room = native_client.join_or_create("my_room", '{"testKey":"hello"}')
	assert_not_null(room, "join_or_create with options should return a room")
	if not room:
		return
	room.joined.connect(_on_joined)
	room.message_received.connect(_on_message)

	var start = Time.get_ticks_msec()
	while (not _joined or not _join_options_received) and (Time.get_ticks_msec() - start) < 5000:
		ColyseusClient.poll()
		OS.delay_msec(10)

	assert_true(_joined, "Should join with options")
	assert_true(_join_options_received, "Should receive join_options echo")
	assert_typeof(_join_options_data, TYPE_DICTIONARY, "Options data should be a Dictionary")
	if _join_options_data is Dictionary:
		assert_eq(_join_options_data.get("testKey"), "hello", "Options should contain testKey=hello")

func test_create_returns_room():
	room = native_client.create("my_room")
	assert_not_null(room, "create should return a room")
	if not room:
		return
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_joined, "Should join via create()")

func test_join_by_id():
	# First create a room to get its ID
	room = native_client.create("my_room")
	assert_not_null(room, "create should return a room")
	if not room:
		return
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_joined, "First room should join")
	var room_id = room.get_id()
	assert_gt(room_id.length(), 0, "Room should have an ID")

	# Leave first room
	room.leave()
	_left_received = false
	room.left.connect(_on_left)
	start = Time.get_ticks_msec()
	while not _left_received and (Time.get_ticks_msec() - start) < 3000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	room = null

	# Now join by ID
	_joined = false
	room = native_client.join_by_id(room_id)
	assert_not_null(room, "join_by_id should return a room")
	if not room:
		return
	room.joined.connect(_on_joined)
	start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_joined, "Should join via join_by_id()")
	assert_eq(room.get_id(), room_id, "Should join the same room")

# =============================================================================
# Error
# =============================================================================

func test_error_on_invalid_room():
	room = native_client.join_or_create("nonexistent_room")
	if not room:
		pass_test("No room returned for invalid name")
		return
	room.error.connect(_on_error)
	var start = Time.get_ticks_msec()
	while not _error_received and (Time.get_ticks_msec() - start) < 5000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_error_received, "Should receive error for invalid room")
	room = null

# =============================================================================
# Leave
# =============================================================================

func test_leave_emits_left_signal():
	await _join_and_wait()
	room.leave()
	var start = Time.get_ticks_msec()
	while not _left_received and (Time.get_ticks_msec() - start) < 3000:
		ColyseusClient.poll()
		OS.delay_msec(10)
	assert_true(_left_received, "Should receive left signal")
	room = null
