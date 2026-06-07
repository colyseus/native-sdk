extends GutTest
## Schema Callbacks Tests — on_change (instance + collection) against test_room (TestRoom)

var client: Colyseus.Client
var room: Colyseus.Room
var callbacks

# Shared state for callback closures
var _joined := false
var _my_session := ""
var _player_captured := false
var _captured_player = null
var _instance_change_count := 0
var _collection_change_count := 0
var _collection_change_key := ""
var _collection_change_value = null

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func before_each():
	room = null
	callbacks = null
	_joined = false
	_my_session = ""
	_player_captured = false
	_captured_player = null
	_instance_change_count = 0
	_collection_change_count = 0
	_collection_change_key = ""
	_collection_change_value = null

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null
	callbacks = null

func _on_joined(): _joined = true

func _join_test_room() -> bool:
	room = client.join_or_create("test_room")
	if not room:
		return false
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		await get_tree().process_frame
	if _joined:
		_my_session = room.get_session_id()
	return _joined

func _pump(ms: int):
	var start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < ms:
		Colyseus.poll()
		await get_tree().process_frame

func _on_player_add(player, key):
	# Only capture the player matching our own session
	if key != _my_session or _player_captured:
		return
	_player_captured = true
	_captured_player = player
	callbacks.on_change(player, _on_instance_change)

func _on_instance_change():
	_instance_change_count += 1

func _on_collection_change(key, value):
	_collection_change_count += 1
	_collection_change_key = str(key)
	_collection_change_value = value

func _send_move(x: float, y: float):
	var json = JSON.stringify({"x": x, "y": y})
	room.send_message("move", json.to_utf8_buffer())

func _send_add_bot():
	room.send_message("add_bot", "true".to_utf8_buffer())

# =============================================================================
# Instance onChange
# =============================================================================

func test_on_change_instance_fires_on_property_change():
	if not await _join_test_room():
		fail_test("Failed to join test_room")
		return

	callbacks = Colyseus.Callbacks.of(room)
	callbacks.on_add("players", _on_player_add)

	# Wait for initial on_add to capture our own player
	var start = Time.get_ticks_msec()
	while not _player_captured and (Time.get_ticks_msec() - start) < 3000:
		Colyseus.poll()
		await get_tree().process_frame
	assert_true(_player_captured, "Own player should be captured via on_add")

	# Send a move — instance onChange should fire on the resulting state patch
	_send_move(42.0, 99.0)
	start = Time.get_ticks_msec()
	while _instance_change_count < 1 and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		await get_tree().process_frame
	assert_gt(_instance_change_count, 0, "Instance onChange should fire after move")

# =============================================================================
# Collection onChange
# =============================================================================

func test_on_change_collection_fires_with_key_and_value():
	if not await _join_test_room():
		fail_test("Failed to join test_room")
		return

	callbacks = Colyseus.Callbacks.of(room)
	callbacks.on_change("players", _on_collection_change)

	# Give on_change registration a frame to settle, then trigger a collection change
	_pump(200)
	_send_add_bot()

	var start = Time.get_ticks_msec()
	while _collection_change_count < 1 and (Time.get_ticks_msec() - start) < 3000:
		Colyseus.poll()
		await get_tree().process_frame

	assert_gt(_collection_change_count, 0, "Collection onChange should fire after add_bot")
	assert_gt(_collection_change_key.length(), 0, "Collection onChange should receive a non-empty key")
	assert_not_null(_collection_change_value, "Collection onChange should receive a value")
