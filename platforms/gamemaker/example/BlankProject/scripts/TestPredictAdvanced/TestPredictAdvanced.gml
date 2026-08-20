// =============================================================================
// Prediction test suite — advanced: composite sim (lab-hockey), optimistic
// events (lab-goal), predicted spawns (lab-projectile). Mirrors the Godot
// test_predict_sim.gd / test_predict_events.gd / test_predict_spawns.gd.
// =============================================================================

global.__pta = undefined;

suite(function() {

    describe("Predict: composite sim (hockey)", function() {

        beforeEach(function() {
            test_drain_events();
            global.__pta = predict_test_join("lab-hockey");
        });
        afterEach(function() {
            predict_test_teardown(global.__pta);
            global.__pta = undefined;
        });

        test("predicted puck leads authority; corrections stay small", function() {
            var _t = global.__pta;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            // a server-driven bot paddle mispredicts every contact — park it
            colyseus_send(_t.room, "bot", { on: false });

            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);
            var _me = predict_test_me(_t);
            var _puck = 0;
            var _start = current_time;
            while (current_time - _start < 4000 && _puck == 0) {
                colyseus_process();
                _puck = __colyseus_schema_get_number(_t.state, "puck");
            }
            expect(_me).toBeGreaterThan(0);
            expect(_puck).toBeGreaterThan(0);

            // world step: my paddle → puck flight → contact (server order)
            var _sim = _predict.sim({
                world: { me: _me, puck: _puck },
                smooth_ms: 0,
                step: function(_ctx, _world, _cmd) {
                    predict_test_step_movement(_ctx, _world.me, _cmd);
                    predict_test_step_puck(_world.puck, _ctx.dt);
                    predict_test_collide_paddle_puck(_world.me, _world.puck);
                },
            });
            expect(_sim.id).toBeGreaterThan(0);

            // seek the puck, then retreat — repeated contacts for 8 seconds
            var _env = {
                sim: _sim, predict: _predict, t: _t,
                corrections: [], peak_lead: 0, phase_t: current_time,
                seek: true, mx: 0, my: 0,
            };
            var _stepper = method(_env, function(_inp) {
                if (current_time - phase_t > 1500) { seek = !seek; phase_t = current_time; }
                var _tx = seek ? sim.value("puck.x") : SIM_ARENA_W / 2;
                var _ty = seek ? sim.value("puck.y") : SIM_ARENA_H - 8;
                var _px = sim.value("me.x"), _py = sim.value("me.y");
                _inp.set("moveX", _tx - _px > 1 ? 1 : (_tx - _px < -1 ? -1 : 0));
                _inp.set("moveY", _ty - _py > 1 ? 1 : (_ty - _py < -1 ? -1 : 0));
            });
            var _sampler = method(_env, function() {
                var _m = sim.last_correction_mag();
                array_push(corrections, _m);
                // predicted puck vs authoritative decoded puck (re-resolved:
                // the raw handle dangles if the decoder replaces the instance)
                var _st = __colyseus_room_get_state(t.room);
                var _pk = __colyseus_schema_get_number(_st, "puck");
                if (_pk == 0) return;
                var _lead = abs(sim.value("puck.x") - __colyseus_schema_get_number(_pk, "x"));
                if (_lead > peak_lead) peak_lead = _lead;
            });
            predict_test_drive(_predict, _input, _sim, 8000, _stepper, _sampler);

            expect(_sim.reconcile_seq()).toBeGreaterThan(20);
            array_sort(_env.corrections, true);
            var _median = _env.corrections[array_length(_env.corrections) div 2];
            // wrong puck friction lands at ~1.78 — exact transliteration stays small
            expect(_median).toBeLessThan(0.5);
            // the predicted puck genuinely led the authoritative one
            expect(_env.peak_lead).toBeGreaterThan(0.3);
            // one pose, three read paths agree (re-resolve the decoded puck)
            _t.state = __colyseus_room_get_state(_t.room);
            _puck = __colyseus_schema_get_number(_t.state, "puck");
            expect(_puck).toBeGreaterThan(0);
            expect(abs(_sim.value("puck.x") - _predict.value(_puck, "x"))).toBeLessThan(3);
            expect(abs(_sim.world.puck.get("x") - _sim.value("puck.x"))).toBeLessThan(6);

            _sim.free_native();
            _predict.free_native();
        });
    });

    describe("Predict: optimistic events", function() {

        beforeEach(function() {
            test_drain_events();
            global.__pta = predict_test_join("lab-goal");
        });
        afterEach(function() {
            predict_test_teardown(global.__pta);
            global.__pta = undefined;
        });

        test("goal gate predicts; deny-rate 100 auto-rejects on grace ticks", function() {
            var _t = global.__pta;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);
            var _me = predict_test_me(_t);
            expect(_me).toBeGreaterThan(0);

            var _tally = { predicted: 0, confirmed: 0, rejected: 0 };
            var _goals = _predict.define_event({
                grace_ticks: 10,
                on_predict: method(_tally, function(_k) { predicted += 1; }),
                on_confirm: method(_tally, function(_k) { confirmed += 1; }),
                on_reject: method(_tally, function(_k) { rejected += 1; }),
            });
            expect(_goals.id).toBeGreaterThan(0);
            // server broadcast confirms the pending prediction
            colyseus_on_message(_t.room, method({ goals: _goals, sid: _t.sid }, function(_room, _type, _payload) {
                if (_type == "goal" && is_struct(_payload) && _payload[$ "sid"] == sid) {
                    goals.confirm();
                }
            }));

            // the scoring gate inside the reconciled step (src/shared/goal.ts)
            var _recon = _predict.reconciler(_me, {
                fields: ["x", "y", "vx", "vy", "scoreTicks"],
                smooth_ms: 66.67,
                step: method({ goals: _goals }, function(_ctx, _s, _cmd) {
                    predict_test_step_movement(_ctx, _s, _cmd);
                    var _ticks = _s.get("scoreTicks");
                    if (_ticks > 0) { _s.set("scoreTicks", _ticks - 1); }
                    else if (_s.get("x") >= SIM_ARENA_W - 8
                          && _s.get("y") >= SIM_ARENA_H / 2 - 9
                          && _s.get("y") <= SIM_ARENA_H / 2 + 9) {
                        _s.set("scoreTicks", 50);
                        if (!_ctx.is_replay) _ctx.predict(goals, "goal-" + string(_ctx.tick));
                    }
                }),
            });
            expect(_recon.id).toBeGreaterThan(0);

            // deny rate 0: run into the zone repeatedly → predictions confirm
            colyseus_send(_t.room, "denyRate", { rate: 0 });
            var _seeker = method({ recon: _recon }, function(_inp) {
                var _x = recon.value("x"), _y = recon.value("y");
                var _in_zone = _x >= SIM_ARENA_W - 8;
                _inp.set("moveX", _in_zone ? -1 : 1);
                _inp.set("moveY", _y > SIM_ARENA_H / 2 + 1 ? -1 : (_y < SIM_ARENA_H / 2 - 1 ? 1 : 0));
            });
            predict_test_drive(_predict, _input, _recon, 7000, _seeker);
            expect(_tally.predicted).toBeGreaterThan(0);
            expect(_tally.confirmed).toBeGreaterThan(0);
            expect(_tally.rejected).toBe(0);

            // deny rate 100: the server never awards → grace-tick auto-reject
            colyseus_send(_t.room, "denyRate", { rate: 100 });
            var _before = _tally.predicted;
            predict_test_drive(_predict, _input, _recon, 8000, _seeker);
            expect(_tally.predicted).toBeGreaterThan(_before);
            expect(_tally.rejected).toBeGreaterThan(0);

            _goals.free_native();
            _recon.free_native();
            _predict.free_native();
        });
    });

    describe("Predict: predicted spawns", function() {

        beforeEach(function() {
            test_drain_events();
            global.__pta = predict_test_join("lab-projectile");
        });
        afterEach(function() {
            predict_test_teardown(global.__pta);
            global.__pta = undefined;
        });

        test("local spawn correlates onto the authoritative entity with lead", function() {
            var _t = global.__pta;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = new ColyseusInput(_t.room);
            var _predict = new ColyseusPredict(_t.room);
            var _me = predict_test_me(_t);
            expect(_me).toBeGreaterThan(0);

            var _shots = _predict.spawns("projectiles", {
                fields: ["x", "y", "vx", "vy"],
                owned_field: "owner",
                owned_value: _t.sid,
                spawn_time_field: "bornMs",
                step_id: COLYSEUS_STEP_INTEGRATE,
                step_params: json_stringify({ bounds: [0, 0, SIM_ARENA_W, SIM_ARENA_H], edge: "bounce" }),
            });
            expect(_shots.id).toBeGreaterThan(0);

            // fire once from the decoded pose (the room spawns the authority)
            var _px = __colyseus_schema_get_number(_me, "x");
            var _py = __colyseus_schema_get_number(_me, "y");
            _input.set("aimX", SIM_ARENA_W - 5);
            _input.set("aimY", SIM_ARENA_H / 2);
            _input.set("fire", 1);
            var _sid = _shots.spawn({ x: _px, y: _py, vx: 34, vy: 0 });
            expect(_sid).toBeGreaterThan(0);

            // pending local is immediately visible and readable
            var _entries = _shots.entries();
            expect(array_length(_entries)).toBeGreaterThan(0);
            expect(is_nan(_shots.value(_sid, "x"))).toBeFalsy();

            // drive with fire held for one send, then released
            predict_test_drive(_predict, _input, undefined, 400, function(_inp) {
                _inp.set("moveX", 0); _inp.set("moveY", 0);
            });
            _input.set("fire", 0);

            // the authoritative projectile arrives and consumes the SAME id
            var _env = { shots: _shots, sid_: _sid, confirmed: false, lead: 0 };
            var _start = current_time;
            while (current_time - _start < 5000 && !_env.confirmed) {
                colyseus_process();
                _predict.tick(colyseus_predict_now());
                var _es = _shots.entries();
                for (var _i = 0; _i < array_length(_es); _i++) {
                    if (_es[_i].id == _sid && _es[_i].confirmed) {
                        _env.confirmed = true;
                        _env.lead = _es[_i].lead_ms;
                    }
                }
            }
            expect(_env.confirmed).toBeTruthy();
            expect(_env.lead).toBeGreaterThan(0);
            // reads span the handoff — now backed by the server instance
            expect(is_nan(_shots.value(_sid, "x"))).toBeFalsy();

            _shots.free_native();
            _predict.free_native();
        });
    });
});
