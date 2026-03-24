// =============================================================================
// Room API Test Suite — connects to sdks-test-server "my_room"
// =============================================================================

// Shared test state for room tests
global.__rt = { done: false, room: -1, client: -1, callbacks: -1 };

suite(function() {

    // =========================================================================
    // Section 1: Room Connection
    // =========================================================================
    describe("Room Connection", function() {

        beforeEach(function() {
            test_drain_events();
            global.__rt = { done: false, room: -1, client: -1, callbacks: -1 };
            global.__rt.client = colyseus_client_create("http://127.0.0.1:2567");
        });

        afterEach(function() {
            if (global.__rt.callbacks != -1) {
                colyseus_callbacks_free(global.__rt.callbacks);
                global.__rt.callbacks = -1;
            }
            if (global.__rt.room != -1) {
                colyseus_room_leave(global.__rt.room);
                // Poll to process the leave
                var _start = current_time;
                while (current_time - _start < 500) { colyseus_process(); }
                colyseus_room_free(global.__rt.room);
                global.__rt.room = -1;
            }
            if (global.__rt.client != -1) {
                colyseus_client_free(global.__rt.client);
                global.__rt.client = -1;
            }
            test_drain_events();
        });

        test("join_or_create connects to my_room", function() {
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "my_room", "{}");
            expect(global.__rt.room).toBeGreaterThan(0);

            global.__rt.done = false;
            colyseus_on_join(global.__rt.room, function(_room) {
                global.__rt.done = true;
            });

            test_poll_until(global.__rt, 5000);
            expect(global.__rt.done).toBeTruthy();

            var _id = colyseus_room_get_id(global.__rt.room);
            expect(string_length(_id)).toBeGreaterThan(0);

            var _session_id = colyseus_room_get_session_id(global.__rt.room);
            expect(string_length(_session_id)).toBeGreaterThan(0);

            expect(colyseus_room_is_connected(global.__rt.room)).toBeTruthy();
        });

        test("room has name 'my_room'", function() {
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "my_room", "{}");
            global.__rt.done = false;
            colyseus_on_join(global.__rt.room, function(_room) {
                global.__rt.done = true;
            });
            test_poll_until(global.__rt, 5000);

            var _name = colyseus_room_get_name(global.__rt.room);
            expect(_name).toBe("my_room");
        });

        test("on_error fires for invalid room name", function() {
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "nonexistent_room", "{}");
            global.__rt.done = false;
            global.__rt.error_code = 0;

            colyseus_on_error(global.__rt.room, function(_code, _msg) {
                global.__rt.error_code = _code;
                global.__rt.done = true;
            });

            test_poll_until(global.__rt, 5000);
            expect(global.__rt.done).toBeTruthy();
            expect(global.__rt.error_code).toBeGreaterThan(0);
            // Room ref is released on error, mark as freed
            global.__rt.room = -1;
        });
    });

    // =========================================================================
    // Section 2: State Access
    // =========================================================================
    describe("State Access", function() {

        beforeEach(function() {
            test_drain_events();
            global.__rt = { done: false, room: -1, client: -1, callbacks: -1 };
            global.__rt.client = colyseus_client_create("http://127.0.0.1:2567");
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "my_room", "{}");

            // Wait for join + first state change
            global.__rt.state_received = false;
            colyseus_on_join(global.__rt.room, function(_room) {
                global.__rt.done = true;
            });
            colyseus_on_state_change(global.__rt.room, function(_room) {
                global.__rt.state_received = true;
            });
            test_poll_until(global.__rt, 5000);
            // Poll a bit more to ensure state arrives
            var _start = current_time;
            while (!global.__rt.state_received && current_time - _start < 2000) {
                colyseus_process();
            }
        });

        afterEach(function() {
            if (global.__rt.callbacks != -1) {
                colyseus_callbacks_free(global.__rt.callbacks);
                global.__rt.callbacks = -1;
            }
            if (global.__rt.room != -1) {
                colyseus_room_leave(global.__rt.room);
                var _start = current_time;
                while (current_time - _start < 500) { colyseus_process(); }
                colyseus_room_free(global.__rt.room);
                global.__rt.room = -1;
            }
            if (global.__rt.client != -1) {
                colyseus_client_free(global.__rt.client);
                global.__rt.client = -1;
            }
            test_drain_events();
        });

        test("get_state returns valid struct", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            expect(is_struct(_state)).toBe(true);
        });

        test("state has currentTurn string field", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            var _type = colyseus_schema_get_field_type(_state, "currentTurn");
            expect(_type).toBe(COLYSEUS_TYPE_STRING);

            var _turn = colyseus_schema_get(_state, "currentTurn");
            // currentTurn is set to joining player's sessionId
            expect(string_length(_turn)).toBeGreaterThan(0);
        });

        test("state has players map field", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            var _type = colyseus_schema_get_field_type(_state, "players");
            expect(_type).toBe(COLYSEUS_TYPE_MAP);
        });

        test("player exists in players map with session id as key", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            var _session_id = colyseus_room_get_session_id(global.__rt.room);
            var _player = colyseus_map_get(_state, "players", _session_id);
            expect(is_struct(_player)).toBe(true);
        });

        test("player has x, y number fields", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            var _session_id = colyseus_room_get_session_id(global.__rt.room);
            var _player = colyseus_map_get(_state, "players", _session_id);

            var _x_type = colyseus_schema_get_field_type(_player, "x");
            var _y_type = colyseus_schema_get_field_type(_player, "y");
            expect(_x_type).toBe(COLYSEUS_TYPE_NUMBER);
            expect(_y_type).toBe(COLYSEUS_TYPE_NUMBER);
        });

        test("host ref points to a player", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            var _host = colyseus_schema_get(_state, "host");
            // host is a Player ref — should be a struct with fields
            expect(is_struct(_host)).toBe(true);
        });
    });

    // =========================================================================
    // Section 2b: Schema Structs (dot access, inline sync)
    // =========================================================================
    describe("Schema Structs", function() {

        beforeEach(function() {
            test_drain_events();
            global.__rt = { done: false, room: -1, client: -1, callbacks: -1 };
            global.__rt.client = colyseus_client_create("http://127.0.0.1:2567");
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "my_room", "{}");

            global.__rt.state_received = false;
            colyseus_on_join(global.__rt.room, function(_room) {
                global.__rt.done = true;
            });
            colyseus_on_state_change(global.__rt.room, function(_room) {
                global.__rt.state_received = true;
            });
            test_poll_until(global.__rt, 5000);
            var _start = current_time;
            while (!global.__rt.state_received && current_time - _start < 2000) {
                colyseus_process();
            }
        });

        afterEach(function() {
            if (global.__rt.callbacks != -1) {
                colyseus_callbacks_free(global.__rt.callbacks);
                global.__rt.callbacks = -1;
            }
            if (global.__rt.room != -1) {
                colyseus_room_leave(global.__rt.room);
                var _start = current_time;
                while (current_time - _start < 500) { colyseus_process(); }
                colyseus_room_free(global.__rt.room);
                global.__rt.room = -1;
            }
            if (global.__rt.client != -1) {
                colyseus_client_free(global.__rt.client);
                global.__rt.client = -1;
            }
            test_drain_events();
        });

        test("state struct has currentTurn accessible via dot notation", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            expect(variable_struct_exists(_state, "currentTurn")).toBe(true);
            expect(string_length(_state.currentTurn)).toBeGreaterThan(0);
        });

        test("state.host is a nested struct with x and y fields", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            expect(is_struct(_state.host)).toBe(true);
            expect(variable_struct_exists(_state.host, "x")).toBe(true);
            expect(variable_struct_exists(_state.host, "y")).toBe(true);
        });

        test("colyseus_map_get returns struct with fields", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            var _session_id = colyseus_room_get_session_id(global.__rt.room);
            var _player = colyseus_map_get(_state, "players", _session_id);
            expect(is_struct(_player)).toBe(true);
            expect(variable_struct_exists(_player, "x")).toBe(true);
            expect(variable_struct_exists(_player, "y")).toBe(true);
        });

        test("same C handle returns same struct reference", function() {
            var _state = colyseus_room_get_state(global.__rt.room);
            var _state2 = colyseus_room_get_state(global.__rt.room);
            expect(_state).toBe(_state2);
        });

        test("on_add delivers struct instances", function() {
            global.__rt.callbacks = colyseus_callbacks_create(global.__rt.room);
            global.__rt.add_instance = undefined;
            global.__rt.add_done = false;

            colyseus_on_add(global.__rt.callbacks, "players", function(_instance, _key) {
                global.__rt.add_instance = _instance;
                global.__rt.add_done = true;
            });

            var _start = current_time;
            while (!global.__rt.add_done && current_time - _start < 2000) {
                colyseus_process();
            }

            expect(global.__rt.add_done).toBeTruthy();
            expect(is_struct(global.__rt.add_instance)).toBe(true);
            expect(variable_struct_exists(global.__rt.add_instance, "x")).toBe(true);
        });

        test("struct field updates inline when listener fires", function() {
            global.__rt.callbacks = colyseus_callbacks_create(global.__rt.room);
            global.__rt.player_struct = undefined;
            global.__rt.move_done = false;

            colyseus_on_add(global.__rt.callbacks, "players", function(_instance, _key) {
                global.__rt.player_struct = _instance;
                colyseus_listen(global.__rt.callbacks, _instance, "x", function(_val, _prev) {
                    if (_val == 77) {
                        global.__rt.move_done = true;
                    }
                });
            });

            // Let on_add fire
            var _start = current_time;
            while (global.__rt.player_struct == undefined && current_time - _start < 2000) {
                colyseus_process();
            }
            expect(is_struct(global.__rt.player_struct)).toBe(true);

            // Send move and wait for listener
            colyseus_send(global.__rt.room, "move", { x: 77, y: 88 });

            _start = current_time;
            while (!global.__rt.move_done && current_time - _start < 3000) {
                colyseus_process();
            }

            expect(global.__rt.move_done).toBeTruthy();
            // The struct should have been updated inline
            expect(global.__rt.player_struct.x).toBe(77);
        });
    });

    // =========================================================================
    // Section 3: Schema Callbacks (listen, on_add, on_remove)
    // =========================================================================
    describe("Schema Callbacks", function() {

        beforeEach(function() {
            test_drain_events();
            global.__rt = { done: false, room: -1, client: -1, callbacks: -1 };
            global.__rt.client = colyseus_client_create("http://127.0.0.1:2567");
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "my_room", "{}");

            global.__rt.done = false;
            colyseus_on_join(global.__rt.room, function(_room) {
                global.__rt.done = true;
            });
            test_poll_until(global.__rt, 5000);

            global.__rt.callbacks = colyseus_callbacks_create(global.__rt.room);
        });

        afterEach(function() {
            if (global.__rt.callbacks != -1) {
                colyseus_callbacks_free(global.__rt.callbacks);
                global.__rt.callbacks = -1;
            }
            if (global.__rt.room != -1) {
                colyseus_room_leave(global.__rt.room);
                var _start = current_time;
                while (current_time - _start < 500) { colyseus_process(); }
                colyseus_room_free(global.__rt.room);
                global.__rt.room = -1;
            }
            if (global.__rt.client != -1) {
                colyseus_client_free(global.__rt.client);
                global.__rt.client = -1;
            }
            test_drain_events();
        });

        test("on_add fires for initial player in players map", function() {
            global.__rt.add_key = "";
            global.__rt.add_done = false;

            colyseus_on_add(global.__rt.callbacks, "players", function(_instance, _key) {
                global.__rt.add_key = _key;
                global.__rt.add_done = true;
            });

            // on_add with immediate=true fires for existing items
            // Process a few frames to receive the callback
            var _start = current_time;
            while (!global.__rt.add_done && current_time - _start < 2000) {
                colyseus_process();
            }

            expect(global.__rt.add_done).toBeTruthy();
            // Key should be the session id
            expect(global.__rt.add_key).toBe(colyseus_room_get_session_id(global.__rt.room));
        });

        test("listen detects player position change after move message", function() {
            global.__rt.move_detected = false;

            // Listen for players being added, then attach x listener to the player
            colyseus_on_add(global.__rt.callbacks, "players", function(_instance, _key) {
                colyseus_listen(global.__rt.callbacks, _instance, "x", function(_val, _prev) {
                    // Only count as detected if value changed from default (0)
                    if (_val != 0) {
                        global.__rt.move_detected = true;
                    }
                });
            });

            // Process to let on_add fire for existing player
            var _start = current_time;
            while (current_time - _start < 500) { colyseus_process(); }

            // Send a move message
            colyseus_send(global.__rt.room, "move", { x: 42, y: 99 });

            // Wait for the listen callback
            _start = current_time;
            while (!global.__rt.move_detected && current_time - _start < 3000) {
                colyseus_process();
            }

            expect(global.__rt.move_detected).toBeTruthy();
        });

        test("listen detects currentTurn change on root state", function() {
            global.__rt.turn_changed = false;
            global.__rt.turn_value = "";

            colyseus_listen(global.__rt.callbacks, "currentTurn", function(_val, _prev) {
                global.__rt.turn_value = _val;
                global.__rt.turn_changed = true;
            });

            // currentTurn changes every 2 seconds on the server
            var _start = current_time;
            while (!global.__rt.turn_changed && current_time - _start < 4000) {
                colyseus_process();
            }

            expect(global.__rt.turn_changed).toBeTruthy();
            expect(string_length(global.__rt.turn_value)).toBeGreaterThan(0);
        });
    });

    // =========================================================================
    // Section 4: Messages
    // =========================================================================
    describe("Messages", function() {

        beforeEach(function() {
            test_drain_events();
            global.__rt = { done: false, room: -1, client: -1, callbacks: -1 };
            global.__rt.client = colyseus_client_create("http://127.0.0.1:2567");
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "my_room", "{}");

            global.__rt.done = false;
            colyseus_on_join(global.__rt.room, function(_room) {
                global.__rt.done = true;
            });
            test_poll_until(global.__rt, 5000);
        });

        afterEach(function() {
            if (global.__rt.callbacks != -1) {
                colyseus_callbacks_free(global.__rt.callbacks);
                global.__rt.callbacks = -1;
            }
            if (global.__rt.room != -1) {
                colyseus_room_leave(global.__rt.room);
                var _start = current_time;
                while (current_time - _start < 500) { colyseus_process(); }
                colyseus_room_free(global.__rt.room);
                global.__rt.room = -1;
            }
            if (global.__rt.client != -1) {
                colyseus_client_free(global.__rt.client);
                global.__rt.client = -1;
            }
            test_drain_events();
        });

        test("receive broadcast weather message", function() {
            global.__rt.weather_received = false;
            global.__rt.weather_data = undefined;

            colyseus_on_message(global.__rt.room, function(_room, _type, _data) {
                if (_type == "weather") {
                    global.__rt.weather_data = _data;
                    global.__rt.weather_received = true;
                }
            });

            // Server broadcasts weather every 4 seconds
            var _start = current_time;
            while (!global.__rt.weather_received && current_time - _start < 6000) {
                colyseus_process();
            }

            expect(global.__rt.weather_received).toBeTruthy();
            expect(global.__rt.weather_data).toHaveProperty("weather");
        });

        test("send move message updates player position in state", function() {
            global.__rt.callbacks = colyseus_callbacks_create(global.__rt.room);
            global.__rt.x_updated = false;

            // Attach x listener via on_add to get the correct instance handle
            colyseus_on_add(global.__rt.callbacks, "players", function(_instance, _key) {
                colyseus_listen(global.__rt.callbacks, _instance, "x", function(_val, _prev) {
                    if (_val == 100) {
                        global.__rt.x_updated = true;
                    }
                });
            });

            // Process to let on_add fire for existing player
            var _start = current_time;
            while (current_time - _start < 500) { colyseus_process(); }

            colyseus_send(global.__rt.room, "move", { x: 100, y: 200 });

            _start = current_time;
            while (!global.__rt.x_updated && current_time - _start < 3000) {
                colyseus_process();
            }

            expect(global.__rt.x_updated).toBeTruthy();
        });

        test("send add_item and verify via state change", function() {
            global.__rt.state_changed = false;

            colyseus_on_state_change(global.__rt.room, function(_room) {
                global.__rt.state_changed = true;
            });

            colyseus_send(global.__rt.room, "add_item", { name: "shield" });

            var _start = current_time;
            while (!global.__rt.state_changed && current_time - _start < 3000) {
                colyseus_process();
            }

            expect(global.__rt.state_changed).toBeTruthy();
        });
    });

    // =========================================================================
    // Section 5: Room Leave
    // =========================================================================
    describe("Room Leave", function() {

        beforeEach(function() {
            test_drain_events();
            global.__rt = { done: false, room: -1, client: -1, callbacks: -1 };
            global.__rt.client = colyseus_client_create("http://127.0.0.1:2567");
            global.__rt.room = colyseus_client_join_or_create(global.__rt.client, "my_room", "{}");

            global.__rt.done = false;
            colyseus_on_join(global.__rt.room, function(_room) {
                global.__rt.done = true;
            });
            test_poll_until(global.__rt, 5000);
        });

        afterEach(function() {
            if (global.__rt.room != -1) {
                colyseus_room_free(global.__rt.room);
                global.__rt.room = -1;
            }
            if (global.__rt.client != -1) {
                colyseus_client_free(global.__rt.client);
                global.__rt.client = -1;
            }
            test_drain_events();
        });

        test("on_leave fires after colyseus_room_leave", function() {
            global.__rt.left = false;
            global.__rt.leave_code = -1;

            colyseus_on_leave(global.__rt.room, function(_code, _reason) {
                global.__rt.leave_code = _code;
                global.__rt.left = true;
            });

            colyseus_room_leave(global.__rt.room);

            var _start = current_time;
            while (!global.__rt.left && current_time - _start < 3000) {
                colyseus_process();
            }

            expect(global.__rt.left).toBeTruthy();
            // After leave, mark room as already left so afterEach doesn't double-leave
            global.__rt.room = -1;
        });
    });
});
