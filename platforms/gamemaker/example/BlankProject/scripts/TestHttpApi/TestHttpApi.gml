// =============================================================================
// HTTP API Test Suite
// =============================================================================

// Shared test state — GML closures inside test() can't capture local vars,
// so we use a global struct that both the test body and callbacks can access.
global.__test = { done: false, err: undefined, data: undefined };
global.__test_client = undefined;
global.__test_auth_client = undefined;

suite(function() {

    // =========================================================================
    // Section 1: HTTP Response Dispatch (unit tests)
    // =========================================================================
    describe("HTTP Response Dispatch", function() {

        beforeEach(function() {
            test_drain_events();
            global.__test = { done: false, err: undefined, data: undefined };
        });

        test("Success callback receives parsed JSON struct", function() {
            test_register_http_handler(9001, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_response(9001, 200, "{\"name\":\"test\",\"score\":42}");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("name", "test");
            expect(global.__test.data).toHaveProperty("score", 42);
        });

        test("Success callback receives raw string for non-JSON body", function() {
            test_register_http_handler(9002, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_response(9002, 200, "plain text response");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toBe("plain text response");
        });

        test("Success callback handles empty body", function() {
            test_register_http_handler(9003, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_response(9003, 200, "");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toBe("");
        });

        test("Success callback receives parsed JSON array", function() {
            test_register_http_handler(9004, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_response(9004, 200, "[1,2,3]");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(is_array(global.__test.data)).toBeTruthy();
            expect(global.__test.data).toHaveLength(3);
        });

        test("Success callback receives parsed number", function() {
            test_register_http_handler(9005, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_response(9005, 200, "42");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toBe(42);
        });

        test("Handler is removed after invocation (one-shot)", function() {
            test_register_http_handler(9006, function(_err, _data) {});

            expect(test_http_handler_exists(9006)).toBeTruthy();

            __colyseus_gm_http_push_response(9006, 200, "{}");
            colyseus_process();

            expect(test_http_handler_exists(9006)).toBeFalsy();
        });

        test("Duplicate event for same ID fires callback only once", function() {
            global.__test.count = 0;

            test_register_http_handler(9007, function(_err, _data) {
                global.__test.count++;
            });

            __colyseus_gm_http_push_response(9007, 200, "{}");
            __colyseus_gm_http_push_response(9007, 200, "{}");
            colyseus_process();

            expect(global.__test.count).toBe(1);
        });
    });

    // =========================================================================
    // Section 2: HTTP Error Dispatch (unit tests)
    // =========================================================================
    describe("HTTP Error Dispatch", function() {

        beforeEach(function() {
            test_drain_events();
            global.__test = { done: false, err: undefined, data: undefined };
        });

        test("Error callback receives {code, message} and undefined data", function() {
            test_register_http_handler(9101, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_error(9101, 404, "Not Found");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toBe(undefined);
            expect(global.__test.err).toHaveProperty("code", 404);
            expect(global.__test.err).toHaveProperty("message", "Not Found");
        });

        test("Network error has code 0", function() {
            test_register_http_handler(9102, function(_err, _data) {
                global.__test.err = _err;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_error(9102, 0, "Connection refused");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toHaveProperty("code", 0);
            expect(global.__test.err).toHaveProperty("message", "Connection refused");
        });

        test("Error handler is removed after invocation", function() {
            test_register_http_handler(9103, function(_err, _data) {});

            __colyseus_gm_http_push_error(9103, 500, "Server Error");
            colyseus_process();

            expect(test_http_handler_exists(9103)).toBeFalsy();
        });

        test("Error with empty message", function() {
            test_register_http_handler(9104, function(_err, _data) {
                global.__test.err = _err;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_error(9104, 500, "");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toHaveProperty("code", 500);
        });
    });

    // =========================================================================
    // Section 3: Concurrent Requests (unit tests)
    // =========================================================================
    describe("Concurrent Requests", function() {

        beforeEach(function() {
            test_drain_events();
            global.__test = { done: false, err: undefined, data: undefined };
        });

        test("Two responses dispatched to correct handlers", function() {
            global.__test.data_a = undefined;
            global.__test.data_b = undefined;

            test_register_http_handler(9201, function(_err, _data) {
                global.__test.data_a = _data;
            });
            test_register_http_handler(9202, function(_err, _data) {
                global.__test.data_b = _data;
            });

            __colyseus_gm_http_push_response(9201, 200, "{\"who\":\"a\"}");
            __colyseus_gm_http_push_response(9202, 200, "{\"who\":\"b\"}");
            colyseus_process();

            expect(global.__test.data_a).toHaveProperty("who", "a");
            expect(global.__test.data_b).toHaveProperty("who", "b");
        });

        test("Mixed success and error dispatched correctly", function() {
            global.__test.success_data = undefined;
            global.__test.error_err = undefined;

            test_register_http_handler(9203, function(_err, _data) {
                global.__test.success_data = _data;
            });
            test_register_http_handler(9204, function(_err, _data) {
                global.__test.error_err = _err;
            });

            __colyseus_gm_http_push_response(9203, 200, "{\"ok\":true}");
            __colyseus_gm_http_push_error(9204, 403, "Forbidden");
            colyseus_process();

            expect(global.__test.success_data).toHaveProperty("ok");
            expect(global.__test.error_err).toHaveProperty("code", 403);
        });

        test("All handlers cleaned up after dispatch", function() {
            test_register_http_handler(9205, function(_e, _d) {});
            test_register_http_handler(9206, function(_e, _d) {});
            test_register_http_handler(9207, function(_e, _d) {});

            __colyseus_gm_http_push_response(9205, 200, "{}");
            __colyseus_gm_http_push_error(9206, 500, "fail");
            __colyseus_gm_http_push_response(9207, 200, "{}");
            colyseus_process();

            expect(test_http_handler_exists(9205)).toBeFalsy();
            expect(test_http_handler_exists(9206)).toBeFalsy();
            expect(test_http_handler_exists(9207)).toBeFalsy();
        });
    });

    // =========================================================================
    // Section 4: Edge Cases (unit tests)
    // =========================================================================
    describe("Edge Cases", function() {

        beforeEach(function() {
            test_drain_events();
            global.__test = { done: false, err: undefined, data: undefined };
        });

        test("Unregistered request ID does not crash", function() {
            __colyseus_gm_http_push_response(99999, 200, "{\"orphan\":true}");
            colyseus_process();

            expect(true).toBeTruthy();
        });

        test("Deeply nested JSON parsed correctly", function() {
            test_register_http_handler(9301, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_response(9301, 200, "{\"level1\":{\"level2\":{\"value\":\"deep\"}}}");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toHaveProperty("level1");
            expect(global.__test.data.level1).toHaveProperty("level2");
            expect(global.__test.data.level1.level2).toHaveProperty("value", "deep");
        });

        test("Boolean JSON body parsed correctly", function() {
            test_register_http_handler(9302, function(_err, _data) {
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_http_push_response(9302, 200, "true");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toBeTruthy();
        });
    });

    // =========================================================================
    // Section 5: Integration — Real Server (requires sdks-test-server running)
    // =========================================================================
    describe("Integration - Real Server", function() {

        beforeEach(function() {
            test_drain_events();
            global.__test = { done: false, err: undefined, data: undefined };
            global.__test_client = colyseus_client_create("http://127.0.0.1:2567");
        });

        afterEach(function() {
            if (global.__test_client != undefined) {
                colyseus_client_free(global.__test_client);
                global.__test_client = undefined;
            }
        });

        test("GET /test returns expected data", function() {
            colyseus_http_get(global.__test_client, "/test", function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            test_poll_until(global.__test, 5000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("things");
            expect(global.__test.data.things).toHaveLength(6);
        });

        test("POST /test echoes body", function() {
            colyseus_http_post(global.__test_client, "/test", { name: "foo", value: 123 }, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            test_poll_until(global.__test, 5000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("method", "POST");
        });

        test("PUT /test echoes body", function() {
            colyseus_http_put(global.__test_client, "/test", { val: 1 }, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            test_poll_until(global.__test, 5000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("method", "PUT");
        });

        test("DELETE /test succeeds", function() {
            colyseus_http_delete(global.__test_client, "/test", function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            test_poll_until(global.__test, 5000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("method", "DELETE");
        });

        test("PATCH /test echoes body", function() {
            colyseus_http_patch(global.__test_client, "/test", { val: 2 }, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            test_poll_until(global.__test, 5000);

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("method", "PATCH");
        });
    });

    // =========================================================================
    // Section 6: Auth Token (unit tests)
    // =========================================================================
    describe("Auth Token", function() {

        beforeEach(function() {
            // Clean persisted token before each test
            if (file_exists(__COLYSEUS_AUTH_FILE)) {
                file_delete(__COLYSEUS_AUTH_FILE);
            }
            global.__test_auth_client = colyseus_client_create("http://127.0.0.1:9999");
        });

        afterEach(function() {
            colyseus_client_free(global.__test_auth_client);
            global.__test_auth_client = undefined;
            // Clean up persisted token
            if (file_exists(__COLYSEUS_AUTH_FILE)) {
                file_delete(__COLYSEUS_AUTH_FILE);
            }
        });

        test("Set and get auth token round-trip", function() {
            colyseus_auth_set_token(global.__test_auth_client, "my-secret-token-123");
            var _token = colyseus_auth_get_token(global.__test_auth_client);

            expect(_token).toBe("my-secret-token-123");
        });

        test("Overwrite auth token", function() {
            colyseus_auth_set_token(global.__test_auth_client, "first-token");
            colyseus_auth_set_token(global.__test_auth_client, "second-token");
            var _token = colyseus_auth_get_token(global.__test_auth_client);

            expect(_token).toBe("second-token");
        });

        test("Token is persisted and restored on new client", function() {
            colyseus_auth_set_token(global.__test_auth_client, "persisted-token");

            // Create a new client — should auto-restore the saved token
            var _new_client = colyseus_client_create("http://127.0.0.1:9999");
            var _token = colyseus_auth_get_token(_new_client);

            expect(_token).toBe("persisted-token");

            colyseus_client_free(_new_client);
        });

        test("Clear auth token removes persisted file", function() {
            colyseus_auth_set_token(global.__test_auth_client, "to-be-cleared");
            expect(file_exists(__COLYSEUS_AUTH_FILE)).toBeTruthy();

            colyseus_auth_clear_token(global.__test_auth_client);

            expect(file_exists(__COLYSEUS_AUTH_FILE)).toBeFalsy();
            expect(colyseus_auth_get_token(global.__test_auth_client)).toBe("");

            // New client should not restore anything
            var _new_client = colyseus_client_create("http://127.0.0.1:9999");
            expect(colyseus_auth_get_token(_new_client)).toBe("");
            colyseus_client_free(_new_client);
        });

        test("New client without prior token starts empty", function() {
            var _token = colyseus_auth_get_token(global.__test_auth_client);
            expect(_token).toBe("");
        });
    });
});
