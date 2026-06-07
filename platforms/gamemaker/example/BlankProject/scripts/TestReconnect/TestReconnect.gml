// =============================================================================
// Reconnect Tests — exercise the drop → automatic reconnect → flush path
// against sdks-test-server "my_room". The server's force_drop handler closes
// the WebSocket with code 4010 (MAY_TRY_RECONNECT); allowReconnection(client,
// 10) gives the worker time to come back.
// =============================================================================

global.__rc = {
    done: false,
    room: -1,
    client: -1,
    joined: false,
    dropped: false,
    reconnected: false,
    left: false,
    left_code: 0,
    echo_received: false,
    echo_data: undefined,
};

function _rc_poll(_ms) {
    var _start = current_time;
    while (current_time - _start < _ms) {
        colyseus_process();
    }
}

function _rc_poll_until(_predicate, _ms) {
    var _start = current_time;
    while (!_predicate() && (current_time - _start < _ms)) {
        colyseus_process();
    }
    return _predicate();
}

suite(function() {

    describe("Reconnect", function() {

        beforeEach(function() {
            test_drain_events();
            global.__rc = {
                done: false,
                room: -1,
                client: -1,
                joined: false,
                dropped: false,
                reconnected: false,
                left: false,
                left_code: 0,
                echo_received: false,
                echo_data: undefined,
            };
            global.__rc.client = colyseus_client_create("http://127.0.0.1:2567");
            global.__rc.room = colyseus_client_join_or_create(global.__rc.client, "my_room", "{}");

            colyseus_on_join(global.__rc.room, function(_room) {
                global.__rc.joined = true;
                global.__rc.done = true;  // beforeEach completion gate
            });
            colyseus_on_drop(global.__rc.room, function(_code, _reason) {
                global.__rc.dropped = true;
            });
            colyseus_on_reconnect(global.__rc.room, function() {
                global.__rc.reconnected = true;
            });
            colyseus_on_leave(global.__rc.room, function(_code, _reason) {
                global.__rc.left = true;
                global.__rc.left_code = _code;
            });
            colyseus_on_message(global.__rc.room, function(_room, _type, _data) {
                if (_type == "tagged_echo") {
                    global.__rc.echo_received = true;
                    global.__rc.echo_data = _data;
                }
            });

            test_poll_until(global.__rc, 5000);
            expect(global.__rc.joined).toBeTruthy();
        });

        afterEach(function() {
            if (global.__rc.room != -1) {
                colyseus_room_leave(global.__rc.room);
                _rc_poll(500);
                colyseus_room_free(global.__rc.room);
                global.__rc.room = -1;
            }
            if (global.__rc.client != -1) {
                colyseus_client_free(global.__rc.client);
                global.__rc.client = -1;
            }
            test_drain_events();
        });

        test("force_drop triggers on_drop and automatic reconnect", function() {
            // Tight retry budget so the test doesn't take half a minute.
            // (room, enabled, max_retries, min_delay_ms, max_delay_ms,
            //  min_uptime_ms, delay_ms, max_enqueued_messages)
            colyseus_room_set_reconnection_options(global.__rc.room,
                1,    // enabled
                5,    // max_retries
                100,  // min_delay_ms
                500,  // max_delay_ms
                0,    // min_uptime_ms (allow immediate reconnect)
                100,  // delay_ms
                -1    // keep current max_enqueued_messages
            );

            colyseus_send(global.__rc.room, "force_drop", {});

            var _dropped = _rc_poll_until(function() {
                return global.__rc.dropped;
            }, 5000);
            expect(_dropped).toBeTruthy();
            expect(colyseus_room_is_reconnecting(global.__rc.room)).toBeTruthy();

            var _reconnected = _rc_poll_until(function() {
                return global.__rc.reconnected;
            }, 10000);
            expect(_reconnected).toBeTruthy();
            expect(colyseus_room_is_reconnecting(global.__rc.room)).toBeFalsy();
            expect(global.__rc.left).toBeFalsy();
        });

        test("messages sent while dropped flush after reconnect", function() {
            colyseus_room_set_reconnection_options(global.__rc.room,
                1, 5, 100, 500, 0, 100, -1);

            colyseus_send(global.__rc.room, "force_drop", {});

            var _dropped = _rc_poll_until(function() {
                return global.__rc.dropped;
            }, 5000);
            expect(_dropped).toBeTruthy();

            // Send while the socket is closed — the SDK should enqueue this
            // and flush it as soon as the JOIN_ROOM arrives on the new
            // transport. The server's echo handler replies with
            // "tagged_echo".
            colyseus_send(global.__rc.room, "echo", { payload: "queued-while-down" });

            var _reconnected = _rc_poll_until(function() {
                return global.__rc.reconnected;
            }, 10000);
            expect(_reconnected).toBeTruthy();

            var _echoed = _rc_poll_until(function() {
                return global.__rc.echo_received;
            }, 5000);
            expect(_echoed).toBeTruthy();
            expect(global.__rc.echo_data).toHaveProperty("payload");
        });

        test("disabled reconnection routes drop to on_leave with original code", function() {
            colyseus_room_set_reconnection_options(global.__rc.room,
                0,    // enabled = false
                -1, -1, -1, -1, -1, -1);

            colyseus_send(global.__rc.room, "force_drop", {});

            var _left = _rc_poll_until(function() {
                return global.__rc.left;
            }, 5000);
            expect(_left).toBeTruthy();
            expect(global.__rc.left_code).toBe(4010);
            expect(global.__rc.dropped).toBeFalsy();
            expect(global.__rc.reconnected).toBeFalsy();

            global.__rc.room = -1;  // already gone
        });
    });
});
