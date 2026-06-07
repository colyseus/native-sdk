// =============================================================================
// StateView Callback Tests — connects to "view_test_room"
//
// Tests on_add / on_remove for view:true arrays (hand) vs non-view arrays
// (discardPile), specifically the splice+push pattern that triggers the
// decoder bug where DELETE_BY_REFID is lost.
// =============================================================================

global.__vt = { done: false, room: -1, client: -1, callbacks: -1 };

suite(function() {

    describe("StateView Callbacks", function() {

        beforeEach(function() {
            test_drain_events();
            global.__vt = {
                done: false,
                room: -1,
                client: -1,
                callbacks: -1,
                player: undefined,
                hand_add_count: 0,
                hand_remove_count: 0,
                discard_add_count: 0,
                discard_remove_count: 0,
                round: 0,
            };

            global.__vt.client = colyseus_client_create("http://127.0.0.1:2567");
            global.__vt.room = colyseus_client_join_or_create(global.__vt.client, "view_test_room", "{}");

            // Wait for join
            colyseus_on_join(global.__vt.room, function(_room) {
                global.__vt.done = true;
            });
            test_poll_until(global.__vt, 5000);

            // Wait for initial state
            colyseus_on_state_change(global.__vt.room, function(_room) {
                global.__vt.state_received = true;
            });
            var _start = current_time;
            while (current_time - _start < 1000) { colyseus_process(); }

            // Create callbacks
            global.__vt.callbacks = colyseus_callbacks_create(global.__vt.room);

            // Capture player via on_add (immediate)
            colyseus_on_add(global.__vt.callbacks, "players", function(_instance, _key) {
                global.__vt.player = _instance;
            });

            // Discard pile callbacks
            colyseus_on_add(global.__vt.callbacks, "discardPile", function(_instance, _key) {
                global.__vt.discard_add_count++;
            });
            colyseus_on_remove(global.__vt.callbacks, "discardPile", function(_instance, _key) {
                global.__vt.discard_remove_count++;
            });

            // Round listener
            colyseus_listen(global.__vt.callbacks, "round", function(_val, _prev) {
                global.__vt.round = _val;
            });

            // Process to let immediate callbacks fire
            _start = current_time;
            while (current_time - _start < 500) { colyseus_process(); }
        });

        afterEach(function() {
            if (global.__vt.callbacks != -1) {
                colyseus_callbacks_free(global.__vt.callbacks);
                global.__vt.callbacks = -1;
            }
            if (global.__vt.room != -1) {
                colyseus_room_leave(global.__vt.room);
                var _start = current_time;
                while (current_time - _start < 500) { colyseus_process(); }
                colyseus_room_free(global.__vt.room);
                global.__vt.room = -1;
            }
            if (global.__vt.client != -1) {
                colyseus_client_free(global.__vt.client);
                global.__vt.client = -1;
            }
            test_drain_events();
        });

        // =====================================================================
        // Initial state
        // =====================================================================

        test("player captured via on_add", function() {
            expect(is_struct(global.__vt.player)).toBe(true);
        });

        test("initial discard pile has cards", function() {
            expect(global.__vt.discard_add_count).toBeGreaterThanOrEqual(2);
        });

        test("hand on_add fires for initial 3 cards (view:true)", function() {
            // Register hand callbacks on the player
            global.__vt.hand_add_count = 0;
            colyseus_on_add(global.__vt.callbacks, global.__vt.player, "hand", function(_instance, _key) {
                global.__vt.hand_add_count++;
            });

            // Immediate should fire for existing cards
            var _start = current_time;
            while (current_time - _start < 500) { colyseus_process(); }

            expect(global.__vt.hand_add_count).toBeGreaterThanOrEqual(3);
        });

        // =====================================================================
        // Splice+push on view:true array (the bug scenario)
        // =====================================================================

        test("reset_hand: on_remove fires for all old cards (view:true)", function() {
            // Register hand callbacks
            global.__vt.hand_add_count = 0;
            global.__vt.hand_remove_count = 0;

            colyseus_on_add(global.__vt.callbacks, global.__vt.player, "hand", function(_instance, _key) {
                global.__vt.hand_add_count++;
            });
            colyseus_on_remove(global.__vt.callbacks, global.__vt.player, "hand", function(_instance, _key) {
                global.__vt.hand_remove_count++;
            });

            // Let immediate callbacks fire (initial 3 cards)
            var _start = current_time;
            while (current_time - _start < 500) { colyseus_process(); }

            var _initial_adds = global.__vt.hand_add_count;
            show_debug_message("[TEST] Initial hand adds: " + string(_initial_adds));

            // Reset counters
            global.__vt.hand_add_count = 0;
            global.__vt.hand_remove_count = 0;

            // Send reset_hand: server splices all 3 cards, pushes 4 new ones
            colyseus_send(global.__vt.room, "reset_hand", { newCount: 4 });

            // Wait for round change
            _start = current_time;
            while (global.__vt.round < 1 && current_time - _start < 5000) {
                colyseus_process();
            }
            // Extra poll for callbacks to settle
            _start = current_time;
            while (current_time - _start < 500) { colyseus_process(); }

            show_debug_message("[TEST] reset_hand: hand_remove=" + string(global.__vt.hand_remove_count)
                + " (expected 3), hand_add=" + string(global.__vt.hand_add_count)
                + " (expected 4)");

            // CRITICAL: on_remove must fire for all 3 old cards
            expect(global.__vt.hand_remove_count).toBe(3);
            // on_add must fire for the 4 new cards
            expect(global.__vt.hand_add_count).toBe(4);
        });

        // =====================================================================
        // Splice+push on non-view array (comparison baseline)
        // =====================================================================

        test("reset_discard: on_remove fires for all old cards (non-view)", function() {
            // Track how many discard cards exist before the reset
            var _initial_discard = global.__vt.discard_add_count;

            // Reset counters
            global.__vt.discard_add_count = 0;
            global.__vt.discard_remove_count = 0;

            // Send reset_discard: server splices ALL current cards, pushes 3 new ones
            colyseus_send(global.__vt.room, "reset_discard", { newCount: 3 });

            // Wait for round change
            var _start = current_time;
            while (global.__vt.round < 1 && current_time - _start < 5000) {
                colyseus_process();
            }
            _start = current_time;
            while (current_time - _start < 500) { colyseus_process(); }

            show_debug_message("[TEST] reset_discard: discard_remove=" + string(global.__vt.discard_remove_count)
                + " (expected " + string(_initial_discard) + "), discard_add=" + string(global.__vt.discard_add_count)
                + " (expected 3)");

            // on_remove must fire for old cards, on_add for 3 new ones
            expect(global.__vt.discard_remove_count).toBeGreaterThan(0);
            expect(global.__vt.discard_add_count).toBe(3);
        });
    });
});
