extends GutTest
## Auth Token Tests — tests auth token management on native ColyseusClient

var client: Colyseus.Client

func before_each():
	client = Colyseus.Client.new("http://127.0.0.1:9999")

func after_each():
	client = null

func test_set_and_get_token():
	client.auth.set_token("my-secret-token-123")
	var token = client.auth.get_token()
	assert_eq(token, "my-secret-token-123", "Token should round-trip")

func test_overwrite_token():
	client.auth.set_token("first-token")
	client.auth.set_token("second-token")
	var token = client.auth.get_token()
	assert_eq(token, "second-token", "Token should be overwritten")

func test_get_token_before_set_returns_empty():
	var token = client.auth.get_token()
	assert_eq(token, "", "Token should be empty before set")

func test_set_empty_token():
	client.auth.set_token("some-token")
	client.auth.set_token("")
	var token = client.auth.get_token()
	assert_eq(token, "", "Token should be empty after clearing")
