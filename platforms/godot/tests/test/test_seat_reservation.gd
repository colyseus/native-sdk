extends GutTest
## client.consume_seat_reservation() — joins with a seat example-server's
## POST /reserve_seat reserved through matchMaker.joinOrCreate().

var client: Colyseus.Client
var room: Colyseus.Room
# The room borrows its client's settings, so the client outlives it.
var dead_client: Colyseus.Client

var _seat = null
var _seat_received := false
var _joined := false
var _error_received := false
var _error_message := ""

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func before_each():
	room = null
	_seat = null
	_seat_received = false
	_joined = false
	_error_received = false
	_error_message = ""

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null
	dead_client = null

func _on_seat(err, seat):
	_seat = seat if err == null else null
	_seat_received = true

func _on_joined(): _joined = true
func _on_error(_code, message): _error_received = true; _error_message = message

func _poll_until(predicate: Callable, timeout_ms: int = 5000) -> bool:
	var start = Time.get_ticks_msec()
	while not predicate.call() and (Time.get_ticks_msec() - start) < timeout_ms:
		Colyseus.poll()
		OS.delay_msec(10)
	return predicate.call()

func _reserve_seat() -> Dictionary:
	client.http.post("/reserve_seat", { "roomName": "my_room", "options": { "private": true } }, _on_seat)
	_poll_until(func(): return _seat_received)
	return _seat if _seat is Dictionary else {}

func _consume(reservation) -> void:
	room = client.consume_seat_reservation(reservation)
	room.joined.connect(_on_joined)
	room.error.connect(_on_error)

func test_consumes_a_dictionary_reservation():
	var seat := _reserve_seat()
	assert_true(seat.has("sessionId"), "server should reserve a seat")

	_consume(seat)
	assert_not_null(room, "consume_seat_reservation should return a room")
	assert_true(_poll_until(func(): return _joined), "should join the reserved room")
	assert_eq(room.get_session_id(), seat.sessionId, "session id is the reserved one")
	assert_eq(room.get_id(), seat.roomId, "room id is the reserved one")
	assert_eq(room.get_name(), "my_room")
	assert_false(_error_received)

func test_consumes_a_json_string_reservation():
	var seat := _reserve_seat()
	_consume(JSON.stringify(seat))
	assert_true(_poll_until(func(): return _joined), "should join from the JSON form")
	assert_eq(room.get_session_id(), seat.sessionId)

func test_connects_to_the_reservations_public_address():
	var seat := _reserve_seat()
	# nothing listens on this client's own endpoint
	dead_client = Colyseus.Client.new("ws://127.0.0.1:1")
	seat["publicAddress"] = "127.0.0.1:2567"

	room = dead_client.consume_seat_reservation(seat)
	room.joined.connect(_on_joined)
	room.error.connect(_on_error)
	assert_true(_poll_until(func(): return _joined), "should join through publicAddress")
	assert_eq(room.get_session_id(), seat.sessionId)
	assert_false(_error_received)

func test_invalid_reservation_emits_error():
	_consume({ "roomId": "nope" })
	assert_true(_poll_until(func(): return _error_received), "should emit error")
	assert_eq(_error_message, "Invalid seat reservation: missing name")
	assert_false(_joined)
