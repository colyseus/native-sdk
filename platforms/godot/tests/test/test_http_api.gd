extends GutTest
## HTTP API Tests — tests HTTP methods against the sdks-test-server

var native_client
var _result: Dictionary

func before_all():
	native_client = ClassDB.instantiate(&"ColyseusClient")
	native_client.set_endpoint("http://127.0.0.1:2567")
	native_client._http_response.connect(_on_http_response)
	native_client._http_error.connect(_on_http_error)

func before_each():
	_result = {done = false, request_id = -1, status = 0, body = "", err_code = 0, err_msg = ""}

func after_all():
	native_client = null

func _on_http_response(request_id: int, status_code: int, body: String):
	_result.done = true
	_result.request_id = request_id
	_result.status = status_code
	_result.body = body

func _on_http_error(request_id: int, code: int, message: String):
	_result.done = true
	_result.request_id = request_id
	_result.err_code = code
	_result.err_msg = message

func _poll_until_done(timeout: float = 5.0) -> bool:
	var start = Time.get_ticks_msec()
	while not _result.done and (Time.get_ticks_msec() - start) < timeout * 1000:
		ColyseusClient.poll()
		await get_tree().process_frame
	# Process remaining deferred calls after result received
	for i in 5:
		ColyseusClient.poll()
		await get_tree().process_frame
	return _result.done

# =============================================================================
# HTTP GET
# =============================================================================

func test_http_get_returns_request_id():
	var rid = native_client.http_get("/test")
	assert_gt(rid, 0, "Should return a positive request ID")

func test_http_get_response():
	native_client.http_get("/test")
	await _poll_until_done()

	assert_true(_result.done, "Should receive response")
	assert_eq(_result.status, 200, "Status should be 200")
	# Parse JSON body
	var json = JSON.new()
	assert_eq(json.parse(_result.body), OK, "Body should be valid JSON")
	assert_has(json.data, "things", "Response should have 'things'")

# =============================================================================
# HTTP POST
# =============================================================================

func test_http_post_echoes_method():
	native_client.http_post("/test", '{"name":"foo"}')
	await _poll_until_done()

	assert_true(_result.done, "Should receive response")
	var json = JSON.new()
	json.parse(_result.body)
	assert_eq(json.data.method, "POST", "Should echo POST method")

# =============================================================================
# HTTP PUT
# =============================================================================

func test_http_put_echoes_method():
	native_client.http_put("/test", '{"val":1}')
	await _poll_until_done()

	assert_true(_result.done, "Should receive response")
	var json = JSON.new()
	json.parse(_result.body)
	assert_eq(json.data.method, "PUT", "Should echo PUT method")

# =============================================================================
# HTTP DELETE
# =============================================================================

func test_http_delete_echoes_method():
	native_client.http_delete("/test")
	await _poll_until_done()

	assert_true(_result.done, "Should receive response")
	var json = JSON.new()
	json.parse(_result.body)
	assert_eq(json.data.method, "DELETE", "Should echo DELETE method")

# =============================================================================
# HTTP PATCH
# =============================================================================

func test_http_patch_echoes_method():
	native_client.http_patch("/test", '{"val":2}')
	await _poll_until_done()

	assert_true(_result.done, "Should receive response")
	var json = JSON.new()
	json.parse(_result.body)
	assert_eq(json.data.method, "PATCH", "Should echo PATCH method")

# =============================================================================
# Error
# =============================================================================

func test_http_error_on_invalid_path():
	native_client.http_get("/nonexistent_path")
	await _poll_until_done()

	assert_true(_result.done, "Should receive error response")
	assert_gt(_result.err_code, 0, "Error code should be > 0")
