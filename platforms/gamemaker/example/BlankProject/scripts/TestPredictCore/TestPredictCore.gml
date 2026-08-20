// =============================================================================
// Prediction test suite — core: input handle, passive smoothing, reckon,
// flat reconciler. Mirrors platforms/godot/tests/test/test_input_handle.gd,
// test_predict_passive.gd, test_predict_reckon.gd, test_predict_reconciler.gd.
// Needs the playground server on :5173 (see TestPredictHelpers).
// =============================================================================

global.__pt = undefined;

suite(function() {

    describe("Predict: input handle", function() {

        beforeEach(function() {
            test_drain_events();
            global.__pt = predict_test_join("lab-move");
        });
        afterEach(function() {
            predict_test_teardown(global.__pt);
            global.__pt = undefined;
        });

        test("room.input synthesizes from INPUT_REFLECTION and acks flow", function() {
            var _t = global.__pt;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);

            var _input = new ColyseusInput(_t.room);
            expect(_input.ok).toBeTruthy();
            expect(_input.tick_rate()).toBe(20);

            // staged field reads back; first send is seq 1
            _input.set("moveX", 1);
            expect(_input.get("moveX")).toBe(1);
            var _predict = new ColyseusPredict(_t.room);
            var _me = predict_test_me(_t);
            expect(_me).toBeGreaterThan(0);
            var _x0 = __colyseus_schema_get_number(_me, "x");

            predict_test_drive(_predict, _input, undefined, 1200, function(_inp) {
                _inp.set("moveX", 1);
                _inp.set("moveY", 0);
            });

            expect(_input.sent_count()).toBeGreaterThan(5);
            expect(_input.last_processed()).toBeGreaterThan(0);
            expect(_input.pending_count()).toBeLessThan(_input.sent_count());
            expect(_predict.clock.rtt()).toBeGreaterThan(0);
            expect(_predict.clock.patch_interval()).toBeGreaterThan(0);
            // the input actually moved the decoded player (re-resolved)
            _me = predict_test_me(_t);
            expect(__colyseus_schema_get_number(_me, "x")).toBeGreaterThan(_x0 + 1);
            _predict.free_native();
        });
    });

    describe("Predict: passive smoothing", function() {

        beforeEach(function() {
            test_drain_events();
            global.__pt = predict_test_join("lab-bots");
        });
        afterEach(function() {
            predict_test_teardown(global.__pt);
            global.__pt = undefined;
        });

        test("attach_all lerp produces dense, in-arena values", function() {
            var _t = global.__pt;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);
            expect(_predict.attach_all("bots", {
                x: { mode: COLYSEUS_PREDICT_LERP, delay: 100 },
                y: { mode: COLYSEUS_PREDICT_LERP, delay: 100 },
            })).toBe(0);

            // grab any bot — keep the KEY and re-resolve per read (raw-pointer
            // handles dangle when the decoder replaces an instance)
            var _bot_key = "bot1";
            var _bot = 0;
            var _start = current_time;
            while (current_time - _start < 4000 && _bot == 0) {
                colyseus_process();
                _bot = __colyseus_map_get(_t.state, "bots", _bot_key);
                if (_bot == 0) { _bot_key = "bot"; _bot = __colyseus_map_get(_t.state, "bots", _bot_key); }
                if (_bot == 0) _bot_key = "bot1";
            }
            expect(_bot).toBeGreaterThan(0);

            var _samples = ds_map_create();
            var _env = { predict: _predict, t: _t, bot_key: _bot_key, samples: _samples,
                         bad: 0, moved: 0, last: -1 };
            predict_test_drive(_predict, _input, undefined, 1600, undefined,
                method(_env, function() {
                    var _st = __colyseus_room_get_state(t.room);
                    var _b = __colyseus_map_get(_st, "bots", bot_key);
                    if (_b == 0) return;
                    var _v = predict.value(_b, "x");
                    if (is_nan(_v) || _v < -1 || _v > SIM_ARENA_W + 1) bad += 1;
                    else {
                        samples[? string(round(_v * 100))] = 1;
                        if (last >= 0 && _v != last) moved += 1;
                        last = _v;
                    }
                }));

            expect(_env.bad).toBe(0);
            expect(_env.moved).toBeGreaterThan(20);
            // lerp yields far more distinct positions than the ~32 raw patches
            expect(ds_map_size(_samples)).toBeGreaterThan(60);
            // unknown field is NaN, never a plausible 0
            _t.state = __colyseus_room_get_state(_t.room);
            _bot = __colyseus_map_get(_t.state, "bots", _bot_key);
            expect(is_nan(_predict.value(_bot, "nope"))).toBeTruthy();
            ds_map_destroy(_samples);
            _predict.free_native();
        });
    });

    describe("Predict: dead reckoning", function() {

        beforeEach(function() {
            test_drain_events();
            global.__pt = predict_test_join("lab-bots");
        });
        afterEach(function() {
            predict_test_teardown(global.__pt);
            global.__pt = undefined;
        });

        test("attach_all_reckon projects bots with the built-in step", function() {
            var _t = global.__pt;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);
            expect(_predict.attach_all_reckon("bots", ["x", "y"],
                COLYSEUS_STEP_INTEGRATE, "", 0, 10, 0)).toBe(0);

            var _bot_key = "bot1";
            var _bot = 0;
            var _start = current_time;
            while (current_time - _start < 4000 && _bot == 0) {
                colyseus_process();
                _bot = __colyseus_map_get(_t.state, "bots", _bot_key);
                if (_bot == 0) { _bot_key = "bot"; _bot = __colyseus_map_get(_t.state, "bots", _bot_key); }
                if (_bot == 0) _bot_key = "bot1";
            }
            expect(_bot).toBeGreaterThan(0);

            var _env = { predict: _predict, t: _t, bot_key: _bot_key, bad: 0, reads: 0 };
            predict_test_drive(_predict, _input, undefined, 1500, undefined,
                method(_env, function() {
                    var _st = __colyseus_room_get_state(t.room);
                    var _b = __colyseus_map_get(_st, "bots", bot_key);
                    if (_b == 0) return;
                    var _v = predict.value(_b, "x");
                    if (is_nan(_v)) bad += 1; else reads += 1;
                }));
            expect(_env.bad).toBe(0);
            expect(_env.reads).toBeGreaterThan(10);
            // value_at the last snapshot instant reads ≈ the decoded snapshot
            _t.state = __colyseus_room_get_state(_t.room);
            _bot = __colyseus_map_get(_t.state, "bots", _bot_key);
            expect(_bot).toBeGreaterThan(0);
            var _snap = __colyseus_schema_get_number(_bot, "x");
            var _at = _predict.value_at(_bot, "x", _predict.clock.last_server_time());
            expect(abs(_at - _snap)).toBeLessThan(1.5);
            _predict.free_native();
        });
    });

    describe("Predict: reconciler", function() {

        beforeEach(function() {
            test_drain_events();
            global.__pt = predict_test_join("lab-move");
        });
        afterEach(function() {
            predict_test_teardown(global.__pt);
            global.__pt = undefined;
        });

        test("rollback stays at wire precision; impulse corrects then decays", function() {
            var _t = global.__pt;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);
            var _me = predict_test_me(_t);
            expect(_me).toBeGreaterThan(0);

            var _recon = _predict.reconciler(_me, {
                fields: ["x", "y", "vx", "vy"],
                smooth_ms: 66.67,
                snap: 8,
                step: predict_test_step_movement,
            });
            expect(_recon.id).toBeGreaterThan(0);

            var _x0 = _recon.value("x");
            predict_test_drive(_predict, _input, _recon, 2500, function(_inp) {
                _inp.set("moveX", 1);
                _inp.set("moveY", 0);
            });

            expect(_recon.reconcile_seq()).toBeGreaterThan(10);
            expect(_recon.value("x") - _x0).toBeGreaterThan(5);
            // the transliteration proof: predicted path matches the server's
            expect(_recon.drift_ema()).toBeLessThan(0.01);
            expect(_recon.last_correction_mag()).toBeLessThan(0.05);
            // mirror x tracks the rendered value
            expect(abs(_recon.state.get("x") - _recon.value("x"))).toBeLessThan(2);

            // a server-side impulse the client didn't predict → visible correction
            colyseus_send(_t.room, "impulse", {});
            var _env = { recon: _recon, peak: 0 };
            predict_test_drive(_predict, _input, _recon, 1500, function(_inp) {
                _inp.set("moveX", 0);
                _inp.set("moveY", 0);
            }, method(_env, function() {
                var _m = recon.last_correction_mag();
                if (_m > peak) peak = _m;
            }));
            expect(_env.peak).toBeGreaterThan(0.05);

            // and it settles back to wire precision
            predict_test_drive(_predict, _input, _recon, 3000, function(_inp) {
                _inp.set("moveX", 0);
                _inp.set("moveY", 0);
            });
            expect(_recon.last_correction_mag()).toBeLessThan(0.05);
            _recon.free_native();
            _predict.free_native();
        });
    });
});
