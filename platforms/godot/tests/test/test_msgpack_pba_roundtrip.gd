extends GutTest
## Attempt to TRIGGER a bug in encode_packed_byte_array (msgpack_encoder.c):
## it indexes a Variant* cast to PackedByteArray*. We verify byte fidelity by
## echoing a PackedByteArray through the server (echo -> tagged_echo), which
## round-trips through our encoder, the server's canonical msgpack, and our
## decoder. If the cast reads wrong memory, the bytes won't survive.

var client: Colyseus.Client
var room: Colyseus.Room
var _joined := false
var _echo_data = null
var _got_echo := false

func before_all():
	client = Colyseus.Client.new("ws://127.0.0.1:2567")

func after_all():
	client = null

func before_each():
	room = null; _joined = false; _echo_data = null; _got_echo = false

func after_each():
	if room and room.connected:
		room.leave()
		for i in 30:
			Colyseus.poll(); OS.delay_msec(10)
	room = null

func _on_joined(): _joined = true

func _on_msg(type, data):
	if str(type) == "tagged_echo":
		_echo_data = data
		_got_echo = true

func _join() -> bool:
	room = client.join_or_create("test_room")
	if not room: return false
	room.joined.connect(_on_joined)
	room.message_received.connect(_on_msg)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll(); await get_tree().process_frame
	return _joined

func _echo_roundtrip(payload):
	_echo_data = null; _got_echo = false
	room.send_message("echo", payload)
	var start = Time.get_ticks_msec()
	while not _got_echo and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll(); await get_tree().process_frame
	return _echo_data

func test_pba_bytes_survive_roundtrip_nested_in_dictionary():
	if not await _join():
		fail_test("join failed"); return
	var blob := PackedByteArray([1, 2, 3, 250, 0, 127, 99])
	var got = await _echo_roundtrip({"blob": blob, "n": 7})
	assert_true(_got_echo, "should receive tagged_echo")
	gut.p("nested echo got: %s" % str(got))
	assert_eq(typeof(got), TYPE_DICTIONARY, "payload should decode to a Dictionary")
	assert_true(got.has("blob"), "echo should carry 'blob'")
	assert_eq(typeof(got["blob"]), TYPE_PACKED_BYTE_ARRAY, "blob should decode as PackedByteArray")
	assert_eq(got["blob"], blob, "blob bytes must survive the round-trip intact")
	assert_eq(int(got.get("n", -1)), 7, "sibling int field should survive too")

func test_pba_bytes_survive_roundtrip_toplevel():
	if not await _join():
		fail_test("join failed"); return
	var blob := PackedByteArray([10, 20, 30, 200, 255, 1])
	var got = await _echo_roundtrip(blob)
	assert_true(_got_echo, "should receive tagged_echo")
	gut.p("toplevel echo got: %s" % str(got))
	assert_eq(typeof(got), TYPE_PACKED_BYTE_ARRAY, "top-level blob should decode as PackedByteArray")
	assert_eq(got, blob, "top-level blob bytes must survive the round-trip intact")

func test_pba_bytes_survive_roundtrip_nested_in_array():
	if not await _join():
		fail_test("join failed"); return
	var blob := PackedByteArray([5, 6, 7, 8])
	var got = await _echo_roundtrip([blob, 42])
	assert_true(_got_echo, "should receive tagged_echo")
	gut.p("array echo got: %s" % str(got))
	assert_eq(typeof(got), TYPE_ARRAY, "payload should decode to an Array")
	assert_gt(got.size(), 0, "array should be non-empty")
	assert_eq(typeof(got[0]), TYPE_PACKED_BYTE_ARRAY, "array[0] should decode as PackedByteArray")
	assert_eq(got[0], blob, "array blob bytes must survive the round-trip intact")
