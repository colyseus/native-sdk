// =============================================================================
// Prediction test suite — network: latency injector + drop/reconnect.
// Mirrors platforms/godot/tests/test/test_netdelay.gd / test_drop_reconnect.gd.
// =============================================================================

global.__ptn = undefined;

suite(function() {

    describe("Predict: netdelay injector", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptn = predict_test_join("lab-move");
        });
        afterEach(function() {
            colyseus_netdelay_set(global.__ptn.room, 0, 0);
            predict_test_teardown(global.__ptn);
            global.__ptn = undefined;
        });

        test("injected delay shows up in rtt and clears again", function() {
            var _t = global.__ptn;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);

            // baseline localhost rtt
            predict_test_drive(_predict, _input, undefined, 1000, undefined);
            var _base = _predict.clock.rtt();
            expect(_base).toBeGreaterThan(0);
            // pump-serialized inbound adds a frame of baseline latency
            expect(_base).toBeLessThan(150);

            // 300ms round trip, split both ways → rtt tracks past 200
            colyseus_netdelay_set(_t.room, 300, 0);
            var _env = { saw_in_flight: 0 };
            var _start = current_time;
            while (current_time - _start < 5000) {
                colyseus_process();
                var _steps = _predict.tick(colyseus_predict_now());
                repeat (_steps) { _input.send(); }   // paced — floods overflow the server buffer
                var _n = colyseus_netdelay_in_flight();
                if (_n > _env.saw_in_flight) _env.saw_in_flight = _n;
                if (_predict.clock.rtt() > 200) break;
            }
            expect(_env.saw_in_flight).toBeGreaterThan(0);
            expect(_predict.clock.rtt()).toBeGreaterThan(200);

            // clearing the delay brings it back down
            colyseus_netdelay_set(_t.room, 0, 0);
            _start = current_time;
            while (current_time - _start < 3000) {
                colyseus_process();
                var _steps = _predict.tick(colyseus_predict_now());
                repeat (_steps) { _input.send(); }
                if (_predict.clock.rtt() < 120) break;
            }
            expect(_predict.clock.rtt()).toBeLessThan(120);
            _predict.free_native();
        });
    });

    describe("Predict: drop + reconnect", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptn = predict_test_join("lab-move");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptn);
            global.__ptn = undefined;
        });

        test("drop reconnects, epoch bumps, rebuilt reconciler stays precise", function() {
            var _t = global.__ptn;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            // fast options: the default 5s min-uptime gate would race the test
            colyseus_room_set_reconnection_options(_t.room, 1, 10, 100, 1000, 500, 100, -1);

            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);
            var _me = predict_test_me(_t);
            expect(_me).toBeGreaterThan(0);
            var _recon = _predict.reconciler(_me, {
                fields: ["x", "y", "vx", "vy"],
                smooth_ms: 66.67, snap: 8,
                step: predict_test_step_movement,
            });

            // settle past min-uptime at wire precision
            predict_test_drive(_predict, _input, _recon, 1500, function(_inp) {
                _inp.set("moveX", 1); _inp.set("moveY", 0);
            });
            expect(_recon.drift_ema()).toBeLessThan(0.01);
            var _epoch_before = _input.epoch();

            var _flags = { dropped: false, reconnected: false, left: false };
            colyseus_on_drop(_t.room, method(_flags, function(_c, _r) { dropped = true; }));
            colyseus_on_reconnect(_t.room, method(_flags, function() { reconnected = true; }));
            colyseus_on_leave(_t.room, method(_flags, function(_c, _r) { left = true; }));

            colyseus_netdelay_drop(_t.room);
            var _start = current_time;
            while (current_time - _start < 15000 && !_flags.reconnected) {
                colyseus_process();
            }
            expect(_flags.dropped).toBeTruthy();
            expect(_flags.left).toBeFalsy();
            expect(_flags.reconnected).toBeTruthy();
            // the fresh server input buffer restarts seqs — the epoch follows
            expect(_input.epoch()).toBeGreaterThan(_epoch_before);

            // resync replaced the decoded instances: re-resolve + rebuild
            _t.state = __colyseus_room_get_state(_t.room);
            var _me2 = predict_test_me(_t);
            expect(_me2).toBeGreaterThan(0);
            _recon.rebuild(_me2);
            expect(_recon.id).toBeGreaterThan(0);

            predict_test_drive(_predict, _input, _recon, 2500, function(_inp) {
                _inp.set("moveX", -1); _inp.set("moveY", 0);
            });
            // no stale pre-drop backlog replayed — precision holds
            expect(_recon.reconcile_seq()).toBeGreaterThan(5);
            expect(_recon.drift_ema()).toBeLessThan(0.01);

            _recon.free_native();
            _predict.free_native();
        });
    });
});
