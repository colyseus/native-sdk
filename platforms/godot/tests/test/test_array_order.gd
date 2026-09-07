extends GutTest
## ArraySchema ordering tests against test_room (TestRoom) — issue #30.
##
## The Godot binding surfaces arrays in the decoder's visit order, so the
## visit order IS the array order the user sees. Nothing here reads by index:
## that is what let a full reversal ship green (the suite only ever asserted
## items[0] on a one-element array).

var client: Colyseus.Client
var room: Colyseus.Room
var callbacks

var _joined := false
var _my_session := ""
var _captured_player = null
var _replayed_names: Array = []

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
	_replayed_names = []

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)

func _on_joined(): _joined = true

func _on_player_add(player, key):
	if key == _my_session and _captured_player == null:
		_captured_player = player

func _on_item_add(value, _key):
	_replayed_names.append(str((value as Dictionary).get("name", "?")))

# Pump the client until `done` returns true, or the timeout expires. Returns
# whether it settled, so callers can tell "never arrived" from "arrived wrong".
func _poll_until(done: Callable, timeout_ms := 5000) -> bool:
	var start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < timeout_ms:
		if done.call():
			return true
		Colyseus.poll()
		await get_tree().process_frame
	return done.call()

func _join_test_room() -> bool:
	room = client.join_or_create("test_room")
	if not room:
		return false
	room.joined.connect(_on_joined)
	if not await _poll_until(func(): return _joined):
		return false
	_my_session = room.get_session_id()
	return true

# Our player's item names, in the order get_state() hands them back. Empty
# until our player shows up in the snapshot.
func _my_item_names() -> Array:
	var state = room.get_state()
	if not (state is Dictionary):
		return []
	var players = state.get("players", {})
	if not (players is Dictionary) or not players.has(_my_session):
		return []
	var names := []
	for it in (players[_my_session] as Dictionary).get("items", []):
		names.append(str((it as Dictionary).get("name", "?")))
	return names

# The server pushes "sword" on join, so a settled array is 1 + what we push.
func _push_items_and_settle(names: Array) -> void:
	for n in names:
		room.send_message("add_item", {"name": n})
	await _poll_until(func(): return _my_item_names().size() >= names.size() + 1)

# =============================================================================

func test_get_state_array_keeps_server_push_order():
	if not await _join_test_room():
		fail_test("Failed to join test_room")
		return

	await _push_items_and_settle(["alpha", "beta", "gamma"])

	assert_eq(_my_item_names(), ["sword", "alpha", "beta", "gamma"],
		"get_state() must hand back the array in the order the server holds it")

func test_on_add_immediate_replays_existing_items_in_order():
	if not await _join_test_room():
		fail_test("Failed to join test_room")
		return

	callbacks = Colyseus.Callbacks.of(room)
	callbacks.on_add("players", _on_player_add)
	await _poll_until(func(): return _captured_player != null)
	assert_not_null(_captured_player, "Own player should be captured via on_add")
	if _captured_player == null:
		return

	# Land the pushes BEFORE subscribing, so on_add has a backlog to replay.
	await _push_items_and_settle(["alpha", "beta", "gamma"])

	callbacks.on_add(_captured_player, "items", _on_item_add)
	await _poll_until(func(): return _replayed_names.size() >= 4)

	assert_eq(_replayed_names, ["sword", "alpha", "beta", "gamma"],
		"on_add(immediate) must replay existing items oldest-first, not reversed")
