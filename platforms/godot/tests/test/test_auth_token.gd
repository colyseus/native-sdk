extends GutTest
## Auth Token Tests — tests auth token management on native ColyseusClient

var native_client

func before_each():
	native_client = ClassDB.instantiate(&"ColyseusClient")
	native_client.set_endpoint("http://127.0.0.1:9999")

func after_each():
	native_client = null

func test_set_and_get_token():
	native_client.auth_set_token("my-secret-token-123")
	var token = native_client.auth_get_token()
	assert_eq(token, "my-secret-token-123", "Token should round-trip")

func test_overwrite_token():
	native_client.auth_set_token("first-token")
	native_client.auth_set_token("second-token")
	var token = native_client.auth_get_token()
	assert_eq(token, "second-token", "Token should be overwritten")

func test_get_token_before_set_returns_empty():
	var token = native_client.auth_get_token()
	assert_eq(token, "", "Token should be empty before set")

func test_set_empty_token():
	native_client.auth_set_token("some-token")
	native_client.auth_set_token("")
	var token = native_client.auth_get_token()
	assert_eq(token, "", "Token should be empty after clearing")

func test_wrapper_auth_class():
	var client = Colyseus.create_client()
	assert_not_null(client, "Wrapper client should not be null")
	if client:
		client.set_endpoint("http://127.0.0.1:9999")
		client.auth.set_token("wrapper-token")
		assert_eq(client.auth.get_token(), "wrapper-token", "Wrapper auth should work")
