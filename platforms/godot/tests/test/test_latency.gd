extends GutTest
## Latency API tests — get_latency / select_by_latency against the example-server (#941)

const HEALTHY := "ws://127.0.0.1:2567"
const BLACKHOLE := "ws://10.255.255.1:9999"

var client: Colyseus.Client
var _result: Dictionary

func before_all():
	client = Colyseus.Client.new(HEALTHY)
	client._native._latency_response.connect(_on_response)
	client._native._latency_error.connect(_on_error)
	client._native._latency_selected.connect(_on_selected)

func before_each():
	_result = {done = false, request_id = -1, latency = -1.0, endpoint = "",
		err_code = 0, err_msg = "", best = ""}

func after_all():
	client = null

func _on_response(request_id: int, latency_ms: float, endpoint: String):
	_result.done = true; _result.request_id = request_id
	_result.latency = latency_ms; _result.endpoint = endpoint

func _on_error(request_id: int, code: int, message: String):
	_result.done = true; _result.request_id = request_id
	_result.err_code = code; _result.err_msg = message

func _on_selected(request_id: int, best_endpoint: String, best_latency_ms: float):
	_result.done = true; _result.request_id = request_id
	_result.best = best_endpoint; _result.latency = best_latency_ms

# wait until the callback for `rid` arrives (ignores stray callbacks from earlier tests)
func _poll_until(rid: int, timeout: float = 5.0) -> bool:
	var start = Time.get_ticks_msec()
	while not (_result.done and _result.request_id == rid) and (Time.get_ticks_msec() - start) < timeout * 1000:
		Colyseus.poll()
		await get_tree().process_frame
	for i in 5:
		Colyseus.poll()
		await get_tree().process_frame
	return _result.done and _result.request_id == rid

func test_get_latency_returns_request_id():
	var rid = client._native.get_latency(HEALTHY)
	assert_gt(rid, 0, "should return a positive request id")
	await _poll_until(rid)  # drain so it doesn't leak into the next test

func test_get_latency_healthy_resolves():
	var rid = client._native.get_latency(HEALTHY)
	var done = await _poll_until(rid)
	assert_true(done, "callback should fire")
	assert_eq(_result.err_code, 0, "no error expected, got: " + str(_result.err_msg))
	assert_gte(_result.latency, 0.0, "latency should be >= 0")
	assert_eq(_result.endpoint, HEALTHY, "endpoint echoed back")

func test_get_latency_blackhole_times_out():
	var rid = client._native.get_latency(BLACKHOLE, 600)
	var done = await _poll_until(rid, 3.0)
	assert_true(done, "callback should fire via timeout, not hang")
	assert_ne(_result.err_code, 0, "should report an error/timeout")

func test_select_by_latency_picks_healthy():
	var rid = client._native.select_by_latency([BLACKHOLE, HEALTHY], 600)
	var done = await _poll_until(rid, 3.0)
	assert_true(done, "select callback should fire")
	assert_eq(_result.best, HEALTHY, "should pick the healthy endpoint over the wedged one")
	assert_gte(_result.latency, 0.0, "best latency >= 0")
