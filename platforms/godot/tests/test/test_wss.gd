extends GutTest
## WSS (TLS) end-to-end test — joins example-server's "my_room" over wss://
## through the self-signed TLS proxy (tls-proxy.mjs on :2568 -> :2567).
##
## Exercises the full secure path that ws:// tests don't:
##   - the binding loading network/tls/certificate_bundle_override (res:// -> file
##     via ProjectSettings.globalize_path)
##   - HTTPS matchmaking trusting that override (http.zig setupCaBundle)
##   - the WSS mbedTLS handshake verifying against it (ws_tls_init merge)
##
## Requires: example-server on 2567, tls-proxy.mjs on 2568, and certs from
## tests/tls/gen-certs.sh. Run via run-tests.sh, which sets these up.

var client: Colyseus.Client
var room: Colyseus.Room

var _joined := false
var _error := false
var _error_msg := ""

func before_all():
	# Use the hostname (not 127.0.0.1): HTTPS matchmaking verifies the DNS-name
	# SAN, and the test cert's IP SAN isn't honored by std.http's verifier.
	client = Colyseus.Client.new("wss://localhost:2568")

func after_all():
	client = null

func before_each():
	room = null
	_joined = false
	_error = false
	_error_msg = ""

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll()
			OS.delay_msec(10)
	room = null

func _on_joined(): _joined = true
func _on_error(code, msg): _error = true; _error_msg = str(msg)

func test_wss_join_over_tls():
	room = client.join_or_create("my_room")
	assert_not_null(room, "join_or_create should return a room over wss://")
	if not room:
		return
	room.joined.connect(_on_joined)
	room.error.connect(_on_error)

	var start := Time.get_ticks_msec()
	while not _joined and not _error and (Time.get_ticks_msec() - start) < 8000:
		Colyseus.poll()
		OS.delay_msec(10)

	assert_false(_error, "Should not error over wss:// (%s)" % _error_msg)
	assert_true(_joined, "Should join my_room over a verified wss:// connection")

func test_wss_room_is_connected():
	room = client.join_or_create("my_room")
	if not room:
		fail_test("no room returned")
		return
	room.joined.connect(_on_joined)
	var start := Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 8000:
		Colyseus.poll()
		OS.delay_msec(10)
	assert_true(room.connected, "Room should report connected over wss://")
