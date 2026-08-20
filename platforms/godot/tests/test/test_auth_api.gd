extends GutTest
## Auth flow tests — client.auth against the example-server's @colyseus/auth
## routes (cd example-server && npm start).
##
## Every call travels the HTTP worker thread and comes back through the polled
## event queue, so each one has to be driven with Colyseus.poll(); a signal
## emitted off-thread never arrives in headless.

var client: Colyseus.Client
var _err
var _data
var _done: bool
var _seen: Dictionary = {}

func before_each():
	client = Colyseus.Client.new("http://127.0.0.1:2567")
	_err = null
	_data = null
	_done = false

func after_each():
	# The token is persisted process-wide in secure storage, so a signed-in
	# test would otherwise hand its session to whatever runs next.
	if client:
		client.auth.sign_out()
	client = null

func _capture(err, data) -> void:
	_err = err
	_data = data
	_done = true

func _await_reply(timeout: float = 8.0) -> bool:
	var start := Time.get_ticks_msec()
	while not _done and (Time.get_ticks_msec() - start) < timeout * 1000:
		Colyseus.poll()
		await get_tree().process_frame
	return _done

func _fresh_email() -> String:
	return "godot-%d@example.com" % Time.get_ticks_usec()

func test_sign_in_anonymously_returns_a_token_and_user():
	client.auth.sign_in_anonymously(_capture)
	assert_true(await _await_reply(), "no reply (is example-server on :2567?)")
	assert_null(_err, "anonymous sign-in failed: %s" % [_err])
	assert_true(_data is Dictionary, "expected a parsed object")
	assert_true(_data.get("token", "") != "", "no token in the reply")
	assert_true(_data.get("user", {}).get("anonymous", false), "user should be anonymous")

func test_the_token_lands_on_the_client():
	client.auth.sign_in_anonymously(_capture)
	assert_true(await _await_reply(), "no reply")
	assert_eq(client.auth.get_token(), _data.get("token", ""),
		"the client should be holding the token it just received")

# The point of the token: it authenticates the next call.
func test_get_user_data_reads_back_the_signed_in_user():
	client.auth.sign_in_anonymously(_capture)
	assert_true(await _await_reply(), "no reply")
	var anonymous_id = _data.get("user", {}).get("anonymousId", "")

	_done = false
	client.auth.get_user_data(_capture)
	assert_true(await _await_reply(), "no reply for get_user_data")
	assert_null(_err, "get_user_data failed: %s" % [_err])
	assert_eq(_data.get("user", {}).get("anonymousId", ""), anonymous_id,
		"should read back the same account")

func test_get_user_data_without_a_token_fails():
	client.auth.sign_out()
	client.auth.get_user_data(_capture)
	assert_true(await _await_reply(), "no reply")
	assert_not_null(_err, "should have failed with no token")

func test_register_then_sign_in():
	var email := _fresh_email()
	client.auth.register_with_email_and_password(email, "secret123", _capture)
	assert_true(await _await_reply(), "no reply for register")
	assert_null(_err, "register failed: %s" % [_err])
	assert_eq(_data.get("user", {}).get("email", ""), email)

	# A second client, so the sign-in stands on its own rather than reading
	# the first one's leftover token.
	var other := Colyseus.Client.new("http://127.0.0.1:2567")
	_done = false
	other.auth.sign_in_with_email_and_password(email, "secret123", _capture)
	assert_true(await _await_reply(), "no reply for sign-in")
	assert_null(_err, "sign-in failed: %s" % [_err])
	assert_eq(_data.get("user", {}).get("email", ""), email)
	other.auth.sign_out()

func test_register_carries_options_through():
	client.auth.register_with_email_and_password(
		_fresh_email(), "secret123", _capture, { "displayName": "Endel", "level": 3 })
	assert_true(await _await_reply(), "no reply")
	assert_null(_err, "register failed: %s" % [_err])
	var options = _data.get("user", {}).get("options", {})
	assert_eq(options.get("displayName", ""), "Endel")
	assert_eq(options.get("level", 0), 3)

func test_sign_in_with_a_wrong_password_fails():
	var email := _fresh_email()
	client.auth.register_with_email_and_password(email, "secret123", _capture)
	assert_true(await _await_reply(), "no reply for register")

	var other := Colyseus.Client.new("http://127.0.0.1:2567")
	_done = false
	other.auth.sign_in_with_email_and_password(email, "nope", _capture)
	assert_true(await _await_reply(), "no reply for sign-in")
	assert_not_null(_err, "a wrong password should fail")
	other.auth.sign_out()

func test_a_token_set_by_hand_authenticates():
	client.auth.sign_in_anonymously(_capture)
	assert_true(await _await_reply(), "no reply")
	var token: String = _data.get("token", "")
	var anonymous_id = _data.get("user", {}).get("anonymousId", "")

	# Why the setter exists: carrying a session across launches.
	var restored := Colyseus.Client.new("http://127.0.0.1:2567")
	restored.auth.set_token(token)
	_done = false
	restored.auth.get_user_data(_capture)
	assert_true(await _await_reply(), "no reply")
	assert_null(_err, "restored token should authenticate: %s" % [_err])
	assert_eq(_data.get("user", {}).get("anonymousId", ""), anonymous_id)
	restored.auth.sign_out()

func test_sign_out_clears_the_token():
	client.auth.sign_in_anonymously(_capture)
	assert_true(await _await_reply(), "no reply")
	assert_true(client.auth.get_token() != "", "should hold a token")

	client.auth.sign_out()
	assert_eq(client.auth.get_token(), "", "sign_out should clear it")

# auth and http share the client's token, so signing in is enough for a plain
# request to be authenticated.
func test_the_token_authenticates_a_plain_http_call():
	client.auth.sign_in_anonymously(_capture)
	assert_true(await _await_reply(), "no reply")

	_done = false
	client.http.get_request("/auth/userdata", _capture)
	assert_true(await _await_reply(), "no reply for the http call")
	assert_null(_err, "http call failed: %s" % [_err])
	assert_true(_data.get("user", {}).get("anonymous", false))

# Both surfaces draw request ids from one counter and answer on one signal, so
# overlapping calls must still land on their own callbacks.
func test_an_http_call_and_an_auth_call_do_not_cross():
	# `_seen` is a member on purpose: a GDScript lambda captures locals by
	# value, so assigning one inside the closure would never reach this scope.
	_seen.clear()
	client.http.get_request("/test", func(_e, d): _seen["http"] = d)
	client.auth.sign_in_anonymously(func(_e, d): _seen["auth"] = d)

	var start := Time.get_ticks_msec()
	while _seen.size() < 2 and (Time.get_ticks_msec() - start) < 8000:
		Colyseus.poll()
		await get_tree().process_frame

	assert_true(_seen.has("http"), "the http call never answered")
	assert_true(_seen.has("auth"), "the auth call never answered")
	assert_true(_seen.get("http", {}).has("things"), "http reply hit the wrong callback")
	assert_true(_seen.get("auth", {}).has("token"), "auth reply hit the wrong callback")
