// =============================================================================
// Auth API Test Suite — the sign-in flows against the example-server's
// @colyseus/auth routes (cd example-server && npm start).
//
// Every call runs on the HTTP worker thread and comes back through the polled
// event queue, so each one is driven with test_poll_until.
// =============================================================================

suite(function() {

    describe("Auth Flows - Real Server", function() {

        beforeEach(function() {
            test_drain_events();
            global.__test = { done: false, err: undefined, data: undefined };
            global.__test_client = colyseus_client_create("http://127.0.0.1:2567");
        });

        afterEach(function() {
            if (global.__test_client != undefined) {
                // The token is persisted process-wide, so a signed-in test
                // would otherwise hand its session to whatever runs next.
                colyseus_auth_sign_out(global.__test_client);
                colyseus_client_free(global.__test_client);
                global.__test_client = undefined;
            }
        });

        test("anonymous sign-in returns a token and a user", function() {
            colyseus_auth_sign_in_anonymously(global.__test_client, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("token");
            expect(global.__test.data.user).toHaveProperty("anonymous", true);
        });

        test("the token lands on the client", function() {
            colyseus_auth_sign_in_anonymously(global.__test_client, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });

            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(colyseus_auth_get_token(global.__test_client)).toBe(global.__test.data.token);
        });

        // The point of the token: it authenticates the next call.
        test("get_user_data reads back the signed-in user", function() {
            colyseus_auth_sign_in_anonymously(global.__test_client, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);
            expect(global.__test.done).toBeTruthy();

            var _anonymous_id = global.__test.data.user.anonymousId;
            global.__test = { done: false, err: undefined, data: undefined };

            colyseus_auth_get_user_data(global.__test_client, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data.user).toHaveProperty("anonymousId", _anonymous_id);
        });

        test("get_user_data without a token fails", function() {
            colyseus_auth_sign_out(global.__test_client);

            colyseus_auth_get_user_data(global.__test_client, function(_err, _data) {
                global.__test.err = _err;
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(is_struct(global.__test.err)).toBeTruthy();
        });

        test("register then sign in with the same credentials", function() {
            var _email = "gm-" + string(get_timer()) + "@example.com";

            colyseus_auth_register_with_email_and_password(
                global.__test_client, _email, "secret123", function(_err, _data) {
                    global.__test.err = _err;
                    global.__test.data = _data;
                    global.__test.done = true;
                });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data.user).toHaveProperty("email", _email);

            // A second client, so the sign-in stands on its own rather than
            // reading the first one's leftover token.
            var _other = colyseus_client_create("http://127.0.0.1:2567");
            global.__test = { done: false, err: undefined, data: undefined };

            colyseus_auth_sign_in_with_email_and_password(
                _other, _email, "secret123", function(_err, _data) {
                    global.__test.err = _err;
                    global.__test.data = _data;
                    global.__test.done = true;
                });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data.user).toHaveProperty("email", _email);

            colyseus_auth_sign_out(_other);
            colyseus_client_free(_other);
        });

        test("register carries options through", function() {
            var _email = "gm-opt-" + string(get_timer()) + "@example.com";

            colyseus_auth_register_with_email_and_password(
                global.__test_client, _email, "secret123", function(_err, _data) {
                    global.__test.err = _err;
                    global.__test.data = _data;
                    global.__test.done = true;
                }, { displayName: "Endel", level: 3 });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data.user.options).toHaveProperty("displayName", "Endel");
            expect(global.__test.data.user.options).toHaveProperty("level", 3);
        });

        test("signing in with a wrong password fails", function() {
            var _email = "gm-bad-" + string(get_timer()) + "@example.com";

            colyseus_auth_register_with_email_and_password(
                global.__test_client, _email, "secret123", function(_err, _data) {
                    global.__test.done = true;
                });
            test_poll_until(global.__test, 8000);
            expect(global.__test.done).toBeTruthy();

            var _other = colyseus_client_create("http://127.0.0.1:2567");
            global.__test = { done: false, err: undefined, data: undefined };

            colyseus_auth_sign_in_with_email_and_password(
                _other, _email, "nope", function(_err, _data) {
                    global.__test.err = _err;
                    global.__test.done = true;
                });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(is_struct(global.__test.err)).toBeTruthy();

            colyseus_auth_sign_out(_other);
            colyseus_client_free(_other);
        });

        test("a token set by hand authenticates", function() {
            colyseus_auth_sign_in_anonymously(global.__test_client, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);
            expect(global.__test.done).toBeTruthy();

            var _token = global.__test.data.token;
            var _anonymous_id = global.__test.data.user.anonymousId;

            // Why the setter exists: carrying a session across launches.
            var _restored = colyseus_client_create("http://127.0.0.1:2567");
            colyseus_auth_set_token(_restored, _token);
            global.__test = { done: false, err: undefined, data: undefined };

            colyseus_auth_get_user_data(_restored, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data.user).toHaveProperty("anonymousId", _anonymous_id);

            colyseus_auth_sign_out(_restored);
            colyseus_client_free(_restored);
        });

        test("sign_out clears the token", function() {
            colyseus_auth_sign_in_anonymously(global.__test_client, function(_err, _data) {
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);
            expect(global.__test.done).toBeTruthy();
            expect(colyseus_auth_get_token(global.__test_client) != "").toBeTruthy();

            colyseus_auth_sign_out(global.__test_client);
            expect(colyseus_auth_get_token(global.__test_client)).toBe("");
        });

        // auth and http share the client's token, so signing in is enough for
        // a plain request to be authenticated.
        test("the token authenticates a plain http call", function() {
            colyseus_auth_sign_in_anonymously(global.__test_client, function(_err, _data) {
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);
            expect(global.__test.done).toBeTruthy();

            global.__test = { done: false, err: undefined, data: undefined };
            colyseus_http_get(global.__test_client, "/auth/userdata", function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });
            test_poll_until(global.__test, 8000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data.user).toHaveProperty("anonymous", true);
        });

        // example-server's auth_static_room checks the token at matchmaking
        // (Authorization header), auth_instance_room at connect (?_authToken=).
        test("the signed-in token authenticates matchmaking (static onAuth)", function() {
            test_auth_sign_in_with_email(global.__test_client);
            expect(global.__test.err).toBe(undefined);
            expect(colyseus_auth_get_token(global.__test_client) != "").toBeTruthy();

            expect(test_auth_join(global.__test_client, "auth_static_room")).toBeTruthy();
        });

        test("the signed-in token reaches the room's onAuth", function() {
            test_auth_sign_in_with_email(global.__test_client);
            expect(global.__test.err).toBe(undefined);

            expect(test_auth_join(global.__test_client, "auth_instance_room")).toBeTruthy();
        });

        test("both auth rooms refuse a signed-out client", function() {
            colyseus_auth_sign_out(global.__test_client);
            expect(test_auth_join(global.__test_client, "auth_static_room")).toBeFalsy();
            expect(global.__test_join.done).toBeTruthy(); // refused, not timed out
            expect(test_auth_join(global.__test_client, "auth_instance_room")).toBeFalsy();
            expect(global.__test_join.done).toBeTruthy();
        });

        // The close that follows the server's error frame must not report again.
        test("a refused join reports the server's reason, once", function() {
            colyseus_auth_sign_out(global.__test_client);

            test_auth_join(global.__test_client, "auth_static_room");
            expect(global.__test_join.errors).toBe(1);
            expect(global.__test_join.err).toBe("jwt must be provided");

            test_auth_join(global.__test_client, "auth_instance_room");
            expect(global.__test_join.errors).toBe(1);
            expect(global.__test_join.err).toBe("jwt must be provided");
        });
    });
});

/// Registers a fresh account, signs out, then signs back in with it. The
/// sign-in's (err, data) land in global.__test.
function test_auth_sign_in_with_email(_client) {
    var _email = "gm-join-" + string(get_timer()) + "@example.com";
    global.__test = { done: false, err: undefined, data: undefined };
    colyseus_auth_register_with_email_and_password(_client, _email, "secret123", function(_err, _data) {
        global.__test.done = true;
    });
    test_poll_until(global.__test, 8000);
    colyseus_auth_sign_out(_client);

    global.__test = { done: false, err: undefined, data: undefined };
    colyseus_auth_sign_in_with_email_and_password(_client, _email, "secret123", function(_err, _data) {
        global.__test.err = _err;
        global.__test.data = _data;
        global.__test.done = true;
    });
    test_poll_until(global.__test, 8000);
}

/// Joins `_room_name`, then leaves. True when the server admitted the client.
/// global.__test_join keeps the first error and how many arrived.
function test_auth_join(_client, _room_name) {
    global.__test_join = { done: false, joined: false, err: "", errors: 0 };
    var _room = colyseus_client_join_or_create(_client, _room_name, "{}");
    colyseus_on_join(_room, function(_r) {
        global.__test_join.joined = true;
        global.__test_join.done = true;
    });
    colyseus_on_error(_room, function(_code, _msg) {
        if (global.__test_join.errors == 0) global.__test_join.err = _msg;
        global.__test_join.errors += 1;
        global.__test_join.done = true;
    });
    // a refusal at connect time can arrive as a bare close
    colyseus_on_leave(_room, function(_code, _reason) {
        global.__test_join.done = true;
    });
    test_poll_until(global.__test_join, 8000);

    if (global.__test_join.joined) {
        colyseus_room_leave(_room);
        var _start = current_time;
        while (current_time - _start < 500) { colyseus_process(); }
    } else {
        // the server closes right after its error frame; let that land too
        var _settle = current_time;
        while (current_time - _settle < 500) { colyseus_process(); }
        show_debug_message("join " + _room_name + " refused: " + global.__test_join.err);
    }
    colyseus_room_free(_room);
    return global.__test_join.joined;
}
