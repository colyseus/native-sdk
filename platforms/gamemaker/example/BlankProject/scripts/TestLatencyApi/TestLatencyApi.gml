// =============================================================================
// Latency API Test Suite (#941)
// Drives the GML event routing with synthesized latency events (push helpers),
// mirroring how TestHttpApi tests HTTP dispatch.
// =============================================================================

global.__test = { done: false, err: undefined, data: undefined };

suite(function() {

    describe("Latency event dispatch", function() {

        beforeEach(function() {
            test_drain_events();
            global.__test = { done: false, err: undefined, data: undefined };
        });

        test("get_latency success dispatches latency_ms", function() {
            ds_map_set(global.__colyseus_latency_handlers, 5001, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_latency_push_response(5001, 42.5, "ws://eu:2567");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toBe(42.5);
        });

        test("get_latency error dispatches an error struct", function() {
            ds_map_set(global.__colyseus_latency_handlers, 5002, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_latency_push_error(5002, 1006, "latency probe timed out");
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toBe(undefined);
            expect(global.__test.err).toHaveProperty("code", 1006);
            expect(global.__test.err).toHaveProperty("message", "latency probe timed out");
        });

        test("select_by_latency dispatches best endpoint + latency", function() {
            ds_map_set(global.__colyseus_latency_handlers, 5003, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_latency_push_selected(5003, "ws://us:2567", 12.0);
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.err).toBe(undefined);
            expect(global.__test.data).toHaveProperty("endpoint", "ws://us:2567");
            expect(global.__test.data).toHaveProperty("latency_ms", 12.0);
        });

        test("select_by_latency all-failed dispatches an error", function() {
            ds_map_set(global.__colyseus_latency_handlers, 5004, function(_err, _data) {
                global.__test.err = _err;
                global.__test.data = _data;
                global.__test.done = true;
            });

            __colyseus_gm_latency_push_selected(5004, "", -1.0);
            colyseus_process();

            expect(global.__test.done).toBeTruthy();
            expect(global.__test.data).toBe(undefined);
            expect(is_struct(global.__test.err)).toBeTruthy();
        });

    });

});
