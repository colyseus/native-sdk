extends GutTest
## Latency injector — lab-move, live server. The RTT the clock reports must
## track the injected round trip, and packets must actually queue.

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
		room.set_latency(0.0)
		# drain whatever is still queued so leave() completes
		for i in 60:
			Colyseus.poll()
			room.net_pump()
			OS.delay_msec(10)
		room.leave()
		for i in 60:
			Colyseus.poll()
			room.net_pump()
			OS.delay_msec(10)
	room = null

func _on_joined(): _joined = true

func _join_and_wait() -> bool:
	room = client.create("lab-move")
	if not room:
		return false
	room.joined.connect(_on_joined)
	var start = Time.get_ticks_msec()
	while not _joined and (Time.get_ticks_msec() - start) < 5000:
		Colyseus.poll()
		OS.delay_msec(10)
	return _joined

func _drive(input, ms: int) -> void:
	var last_send = 0
	var start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < ms:
		Colyseus.poll()
		room.net_pump()
		var now = Time.get_ticks_msec()
		if now - last_send >= 50:
			last_send = now
			input.data.moveX = 1
			input.data.moveY = 0
			input.send()
		OS.delay_msec(5)

func test_injected_latency_shows_up_in_the_rtt():
	assert_true(await _join_and_wait(), "should join lab-move (is pnpm dev --host 0.0.0.0 up?)")
	var input = room.input()
	assert_not_null(input, "input handle should exist")

	# baseline: localhost round trip is a handful of ms
	_drive(input, 1200)
	var base_rtt = room.clock.smoothed_rtt()
	assert_between(base_rtt, 0.1, 100.0, "baseline rtt should be a localhost round trip")

	# inject 150 ms each way -> the ack round trip must grow by ~300 ms
	room.set_latency(150.0)
	var saw_queue := false
	var last_send = 0
	var start = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start) < 3000:
		Colyseus.poll()
		room.net_pump()
		var now = Time.get_ticks_msec()
		if now - last_send >= 50:
			last_send = now
			input.data.moveX = 1
			input.send()
		if room.net_in_flight > 0:
			saw_queue = true
		OS.delay_msec(5)

	assert_true(saw_queue, "packets should sit in the injector queues")
	assert_gt(room.clock.rtt(), 250.0,
		"rtt %f ms — the injector is not in the path" % room.clock.rtt())

	# back to zero: the rtt estimate must come back down
	room.set_latency(0.0)
	_drive(input, 2500)
	assert_lt(room.clock.rtt(), 120.0,
		"rtt %f ms after clearing the delay — queues not draining" % room.clock.rtt())
