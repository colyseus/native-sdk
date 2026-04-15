extends GutTest
## StateView callback tests — connects to "view_test_room" (ViewTestRoom).
##
## Mirrors tests/test_view_callbacks.zig and
## platforms/gamemaker/.../TestViewCallbacks.gml so we can diff on_remove/on_add
## counts for splice+push on a view:true array across all bindings.

var client: Colyseus.Client
var room: Colyseus.Room
var callbacks

var _joined := false
var _my_session := ""

var _captured_player = null
var _player_add_count := 0

var _hand_add_count := 0
var _hand_remove_count := 0

var _discard_add_count := 0
var _discard_remove_count := 0

var _round = 0

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func before_each():
	room = null
	callbacks = null
	_joined = false
	_my_session = ""
	_captured_player = null
	_player_add_count = 0
	_hand_add_count = 0
	_hand_remove_count = 0
	_discard_add_count = 0
	_discard_remove_count = 0
	_round = 0

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null
	callbacks = null

func _on_joined(): _joined = true

func _pump(ms: int):
	var start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < ms:
		Colyseus.poll()
		await get_tree().process_frame

func _join_view_room() -> bool:
	room = client.join_or_create("view_test_room")
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

func _on_player_add(player, key):
	_player_add_count += 1
	if key == _my_session and _captured_player == null:
		_captured_player = player

func _on_discard_add(_value, _key):
	_discard_add_count += 1

func _on_discard_remove(_value, _key):
	_discard_remove_count += 1

func _on_hand_add(_value, _key):
	_hand_add_count += 1

func _on_hand_remove(_value, _key):
	_hand_remove_count += 1

func _on_round(value, _prev):
	if value != null:
		_round = value

func _send_reset_hand(count: int):
	room.send_message("reset_hand", {"newCount": count})

func _send_reset_discard(count: int):
	room.send_message("reset_discard", {"newCount": count})

func test_reset_hand_fires_three_removes_and_four_adds():
	if not await _join_view_room():
		fail_test("Failed to join view_test_room")
		return

	# Give initial state time to arrive before registering callbacks (matches Zig).
	await _pump(300)

	callbacks = Colyseus.Callbacks.of(room)
	callbacks.on_add("players", _on_player_add)
	callbacks.on_add("discardPile", _on_discard_add)
	callbacks.on_remove("discardPile", _on_discard_remove)
	callbacks.listen("round", _on_round)

	# Let immediate callbacks fire so we capture our player.
	var start = Time.get_ticks_msec()
	while _captured_player == null and (Time.get_ticks_msec() - start) < 3000:
		Colyseus.poll()
		await get_tree().process_frame
	assert_not_null(_captured_player, "Own player should be captured via on_add")

	assert_gt(_discard_add_count, 1, "Initial discard pile should emit at least 2 adds")

	# Register hand callbacks on the player (view:true array).
	callbacks.on_add(_captured_player, "hand", _on_hand_add)
	callbacks.on_remove(_captured_player, "hand", _on_hand_remove)

	# Let immediate on_add fire for the 3 initial cards.
	await _pump(500)
	var initial_adds := _hand_add_count
	gut.p("initial hand on_add count: %d" % initial_adds)
	assert_gte(initial_adds, 3, "Initial hand on_add should fire at least 3 times")

	# Reset counters before the splice+push bundle.
	_hand_add_count = 0
	_hand_remove_count = 0

	_send_reset_hand(4)

	# Wait for round to tick (same message as the splice+push).
	start = Time.get_ticks_msec()
	while _round < 1 and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		await get_tree().process_frame
	await _pump(2000)

	gut.p("reset_hand: hand_remove=%d (expected 3), hand_add=%d (expected 4)"
		% [_hand_remove_count, _hand_add_count])

	assert_eq(_hand_remove_count, 3,
		"on_remove should fire 3 times for view:true splice+push")
	assert_eq(_hand_add_count, 4,
		"on_add should fire 4 times for view:true splice+push")

func test_reset_discard_fires_removes_and_three_adds():
	if not await _join_view_room():
		fail_test("Failed to join view_test_room")
		return

	await _pump(300)

	callbacks = Colyseus.Callbacks.of(room)
	callbacks.on_add("players", _on_player_add)
	callbacks.on_add("discardPile", _on_discard_add)
	callbacks.on_remove("discardPile", _on_discard_remove)
	callbacks.listen("round", _on_round)

	await _pump(500)
	var initial_discard := _discard_add_count
	assert_gte(initial_discard, 2, "Initial discard pile should have at least 2 cards")

	_discard_add_count = 0
	_discard_remove_count = 0

	_send_reset_discard(3)

	var start := Time.get_ticks_msec()
	while _round < 1 and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		await get_tree().process_frame
	await _pump(500)

	gut.p("reset_discard: discard_remove=%d (expected %d), discard_add=%d (expected 3)"
		% [_discard_remove_count, initial_discard, _discard_add_count])

	assert_gt(_discard_remove_count, 0,
		"on_remove should fire for spliced non-view discard cards")
	assert_eq(_discard_add_count, 3,
		"on_add should fire 3 times for new discard cards")
