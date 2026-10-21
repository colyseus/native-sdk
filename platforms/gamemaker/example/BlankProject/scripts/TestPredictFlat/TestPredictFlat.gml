// =============================================================================
// Prediction test suite — the colyseus_* functions, with plain-struct step
// arguments (_s.x, _cmd.moveX). The Core/Advanced/Net suites cover the same
// scenarios through the constructors, which delegate to these functions.
// Needs the playground server on :5173 (see TestPredictHelpers).
// =============================================================================

global.__ptf = undefined;

/// stepEntity (src/shared/movement.ts) on a plain-struct view.
function predict_test_flat_movement(_ctx, _s, _cmd) {
    var _ax = _cmd.moveX;
    var _ay = _cmd.moveY;
    if (_ax != 0 && _ay != 0) { _ax *= SIM_SQRT1_2; _ay *= SIM_SQRT1_2; }

    var _vx = _s.vx;
    var _vy = _s.vy;
    if (_ax != 0 || _ay != 0) {
        _vx += _ax * SIM_PLAYER_ACCEL * _ctx.dt;
        _vy += _ay * SIM_PLAYER_ACCEL * _ctx.dt;
    } else {
        _vx *= SIM_PLAYER_FRICTION_K;
        _vy *= SIM_PLAYER_FRICTION_K;
        if (_vx > -0.05 && _vx < 0.05) _vx = 0;
        if (_vy > -0.05 && _vy < 0.05) _vy = 0;
    }

    var _sq = _vx * _vx + _vy * _vy;
    if (_sq > SIM_PLAYER_MAX_SPEED * SIM_PLAYER_MAX_SPEED) {
        var _sc = SIM_PLAYER_MAX_SPEED / sqrt(_sq);
        _vx *= _sc;
        _vy *= _sc;
    }

    var _x = _s.x + _vx * _ctx.dt;
    var _y = _s.y + _vy * _ctx.dt;

    var _min_x = SIM_PLAYER_HALF, _max_x = SIM_ARENA_W - SIM_PLAYER_HALF;
    var _min_y = SIM_PLAYER_HALF, _max_y = SIM_ARENA_H - SIM_PLAYER_HALF;
    if (_x < _min_x) { _x = _min_x; if (_vx < 0) _vx = 0; }
    else if (_x > _max_x) { _x = _max_x; if (_vx > 0) _vx = 0; }
    if (_y < _min_y) { _y = _min_y; if (_vy < 0) _vy = 0; }
    else if (_y > _max_y) { _y = _max_y; if (_vy > 0) _vy = 0; }

    _s.x = _x;
    _s.y = _y;
    _s.vx = _vx;
    _s.vy = _vy;
}

/// stepPuck (src/shared/hockey.ts) on a plain-struct view.
function predict_test_flat_puck(_p, _dt) {
    var _vx = _p.vx * SIM_PUCK_FRICTION_K;
    var _vy = _p.vy * SIM_PUCK_FRICTION_K;
    var _x = _p.x + _vx * _dt;
    var _y = _p.y + _vy * _dt;
    var _min = SIM_PUCK_RADIUS;
    var _max_x = SIM_ARENA_W - SIM_PUCK_RADIUS;
    var _max_y = SIM_ARENA_H - SIM_PUCK_RADIUS;
    if (_x < _min) { _x = _min; _vx = abs(_vx) * SIM_PUCK_RESTITUTION; }
    else if (_x > _max_x) { _x = _max_x; _vx = -abs(_vx) * SIM_PUCK_RESTITUTION; }
    if (_y < _min) { _y = _min; _vy = abs(_vy) * SIM_PUCK_RESTITUTION; }
    else if (_y > _max_y) { _y = _max_y; _vy = -abs(_vy) * SIM_PUCK_RESTITUTION; }
    _p.x = _x; _p.y = _y; _p.vx = _vx; _p.vy = _vy;
}

/// collidePaddlePuck (src/shared/hockey.ts) on plain-struct views.
function predict_test_flat_collide(_paddle, _puck) {
    var _dx = _puck.x - _paddle.x;
    var _dy = _puck.y - _paddle.y;
    var _r = SIM_PADDLE_RADIUS + SIM_PUCK_RADIUS;
    var _d2 = _dx * _dx + _dy * _dy;
    if (_d2 >= _r * _r) return false;
    var _d = sqrt(_d2);
    if (_d == 0) _d = 0.000001;
    var _nx = _dx / _d, _ny = _dy / _d;
    var _px = _paddle.x + _nx * _r;
    var _py = _paddle.y + _ny * _r;
    var _along = _paddle.vx * _nx + _paddle.vy * _ny;
    var _speed = _along > SIM_PUCK_PUSH_MIN ? _along : SIM_PUCK_PUSH_MIN;
    var _vx = _nx * _speed + _paddle.vx * 0.35;
    var _vy = _ny * _speed + _paddle.vy * 0.35;
    var _min = SIM_PUCK_RADIUS;
    var _max_x = SIM_ARENA_W - SIM_PUCK_RADIUS;
    var _max_y = SIM_ARENA_H - SIM_PUCK_RADIUS;
    if (_px < _min) { _px = _min; _vx = abs(_vx) * SIM_PUCK_RESTITUTION; }
    else if (_px > _max_x) { _px = _max_x; _vx = -abs(_vx) * SIM_PUCK_RESTITUTION; }
    if (_py < _min) { _py = _min; _vy = abs(_vy) * SIM_PUCK_RESTITUTION; }
    else if (_py > _max_y) { _py = _max_y; _vy = -abs(_vy) * SIM_PUCK_RESTITUTION; }
    _puck.x = _px; _puck.y = _py;
    _puck.vx = _vx; _puck.vy = _vy;
    return true;
}

/// lab-hockey's world step: my paddle → puck flight → contact, the server's order.
function predict_test_flat_hockey(_ctx, _w, _cmd) {
    predict_test_flat_movement(_ctx, _w.me, _cmd);
    predict_test_flat_puck(_w.puck, _ctx.dt);
    predict_test_flat_collide(_w.me, _w.puck);
}

/// The per-frame contract, as in the JS SDK: process → tick → per step: stage + send.
/// No pump: tick() replays and send() steps every reconciler.
function predict_test_flat_drive(_predict, _input, _ms, _input_fn, _frame_fn = undefined) {
    var _start = current_time;
    while (current_time - _start < _ms) {
        colyseus_process();
        var _steps = colyseus_predict_tick(_predict, colyseus_predict_now());
        repeat (_steps) {
            if (_input_fn != undefined) _input_fn(_input);
            colyseus_input_send(_input);
        }
        if (_frame_fn != undefined) _frame_fn();
    }
}

/// A named function for colyseus_step_memo: a "ref", not a method.
function predict_test_flat_double(_args) {
    return _args.v * 2;
}

function predict_test_flat_seek_right(_input) {
    colyseus_input_set(_input, "moveX", 1);
    colyseus_input_set(_input, "moveY", 0);
}

suite(function() {

    describe("Predict (functions): input, tick, clock", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptf = predict_test_join("lab-move");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptf);
            global.__ptf = undefined;
        });

        test("colyseus_room_input sends, acks flow, clock readers answer", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);

            var _input = colyseus_room_input(_t.room);
            expect(_input).toBeGreaterThan(0);
            expect(colyseus_input_tick_rate(_input)).toBe(20);
            colyseus_input_set(_input, "moveX", 1);
            expect(colyseus_input_get(_input, "moveX")).toBe(1);

            var _predict = colyseus_predict_for_room(_t.room);
            expect(_predict).toBeGreaterThan(0);
            predict_test_flat_drive(_predict, _input, 1200, predict_test_flat_seek_right);

            expect(colyseus_input_sent_count(_input)).toBeGreaterThan(5);
            expect(colyseus_input_last_processed(_input)).toBeGreaterThan(0);
            expect(colyseus_input_pending_count(_input)).toBeLessThan(colyseus_input_sent_count(_input));
            var _clock = colyseus_room_get_clock(_t.room);
            expect(colyseus_room_clock_rtt(_clock)).toBeGreaterThan(0);
            expect(colyseus_room_clock_rtt(_t.room)).toBe(colyseus_room_clock_rtt(_clock));
            expect(colyseus_room_clock_patch_interval(_clock)).toBeGreaterThan(0);
            expect(_clock.rtt()).toBe(colyseus_room_clock_rtt(_clock));
            // the constructors' structs are accepted where a handle is expected
            var _legacy = new ColyseusPredict(_t.room);
            expect(colyseus_predict_tick(_legacy, colyseus_predict_now())).toBeGreaterThan(-1);
            _legacy.free_native();
            colyseus_predict_free(_predict);
        });
    });

    describe("Predict (functions): reconciler", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptf = predict_test_join("lab-move");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptf);
            global.__ptf = undefined;
        });

        test("struct step stays at wire precision; impulse corrects then decays", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = colyseus_room_input(_t.room);
            var _predict = colyseus_predict_for_room(_t.room);
            // the documented path: the entity as a struct from the state
            var _start = current_time;
            var _self = undefined;
            while (current_time - _start < 4000 && _self == undefined) {
                colyseus_process();
                _self = colyseus_map_get(colyseus_room_get_state(_t.room), "players", _t.sid);
            }
            expect(is_struct(_self)).toBeTruthy();

            global.__ptf_seen = { ctx: undefined, cmd_x: NaN, fields: 0 };
            var _me = colyseus_predict_reconciler(_predict, _self, {
                fields: ["x", "y", "vx", "vy"],
                smooth_ms: 66.67,
                snap: 8,
                step: function(_ctx, _s, _cmd) {
                    predict_test_flat_movement(_ctx, _s, _cmd);
                    global.__ptf_seen.ctx = _ctx;
                    global.__ptf_seen.cmd_x = _cmd.moveX;
                    global.__ptf_seen.fields = array_length(variable_struct_get_names(_s));
                },
            });
            expect(_me).toBeGreaterThan(0);

            var _x0 = colyseus_reconciler_value(_me, "x");
            predict_test_flat_drive(_predict, _input, 2500, predict_test_flat_seek_right);

            expect(colyseus_reconciler_reconcile_seq(_me)).toBeGreaterThan(10);
            expect(colyseus_reconciler_value(_me, "x") - _x0).toBeGreaterThan(5);
            expect(colyseus_reconciler_drift(_me).ema).toBeLessThan(0.01);
            expect(colyseus_reconciler_last_correction_mag(_me)).toBeLessThan(0.05);
            expect(abs(colyseus_reconciler_state(_me).x - colyseus_reconciler_value(_me, "x"))).toBeLessThan(2);
            // plain structs: ctx fields, the input field, every numeric entity field
            expect(global.__ptf_seen.ctx.dt).toBe(1 / 20);
            expect(global.__ptf_seen.cmd_x).toBe(1);
            expect(global.__ptf_seen.fields).toBeGreaterThan(3);

            // a server-side impulse the client didn't predict → visible correction
            colyseus_send(_t.room, "impulse", {});
            var _env = { me: _me, peak: 0 };
            predict_test_flat_drive(_predict, _input, 1500, function(_inp) {
                colyseus_input_set(_inp, "moveX", 0);
                colyseus_input_set(_inp, "moveY", 0);
            }, method(_env, function() {
                var _m = colyseus_reconciler_last_correction_mag(me);
                if (_m > peak) peak = _m;
            }));
            expect(_env.peak).toBeGreaterThan(0.05);

            predict_test_flat_drive(_predict, _input, 3000, function(_inp) {
                colyseus_input_set(_inp, "moveX", 0);
                colyseus_input_set(_inp, "moveY", 0);
            });
            expect(colyseus_reconciler_last_correction_mag(_me)).toBeLessThan(0.05);
            colyseus_reconciler_free(_me);
            expect(is_nan(colyseus_reconciler_value(_me, "x"))).toBeTruthy();
            colyseus_predict_free(_predict);
        });

        // A live-only nudge forces a rollback per ack, so replays run.
        test("colyseus_step_memo freezes the live value for replays", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = colyseus_room_input(_t.room);
            var _predict = colyseus_predict_for_room(_t.room);
            var _self = predict_test_me(_t);
            expect(_self).toBeGreaterThan(0);

            global.__ptf_memo = { live: ds_map_create(), checked: 0, mismatch: 0, value_ok: 0 };
            var _me = colyseus_predict_reconciler(_predict, _self, {
                fields: ["x", "y", "vx", "vy"],
                smooth_ms: 0,
                step: function(_ctx, _s, _cmd) {
                    predict_test_flat_movement(_ctx, _s, _cmd);
                    var _roll = colyseus_step_memo("roll", function() { return irandom(1000000); });
                    if (colyseus_step_memo("args", function(_a) { return _a.v * 2; }, { v: 21 }) == 42
                        && colyseus_step_memo("named", predict_test_flat_double, { v: 4 }) == 8) {
                        global.__ptf_memo.value_ok += 1;
                    }
                    if (!_ctx.is_replay) {
                        ds_map_set(global.__ptf_memo.live, _ctx.tick, _roll);
                        _s.x += 0.01;   // live-only mismatch
                    } else {
                        var _want = ds_map_find_value(global.__ptf_memo.live, _ctx.tick);
                        if (_want != undefined) {
                            global.__ptf_memo.checked += 1;
                            if (_want != _roll) global.__ptf_memo.mismatch += 1;
                        }
                    }
                },
            });
            predict_test_flat_drive(_predict, _input, 2000, predict_test_flat_seek_right);

            expect(global.__ptf_memo.checked).toBeGreaterThan(5);
            expect(global.__ptf_memo.mismatch).toBe(0);
            expect(global.__ptf_memo.value_ok).toBeGreaterThan(5);
            expect(is_nan(colyseus_step_memo("roll", function() { return 1; }))).toBeTruthy();   // outside a step
            ds_map_destroy(global.__ptf_memo.live);
            colyseus_predict_free(_predict);
        });
    });

    describe("Predict (functions): smoothing and reckoning", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptf = predict_test_join("lab-bots");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptf);
            global.__ptf = undefined;
        });

        test("attach_all lerp and attach_all_reckon produce in-arena values", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = colyseus_room_input(_t.room);
            var _lerp = colyseus_predict_for_room(_t.room);
            var _reckon = colyseus_predict_for_room(_t.room);
            expect(colyseus_predict_attach_all(_lerp, "bots", {
                x: { mode: COLYSEUS_PREDICT_LERP, delay: 100 },
                y: { mode: COLYSEUS_PREDICT_LERP, delay: 100 },
            })).toBe(0);
            expect(colyseus_predict_attach_all_reckon(_reckon, "bots", ["x", "y"],
                COLYSEUS_STEP_INTEGRATE, "", 0, 10, 0)).toBe(0);

            var _env = { lerp: _lerp, reckon: _reckon, t: _t, bad: 0, moved: 0, last: -1, reads: 0 };
            var _start = current_time;
            while (current_time - _start < 1600) {
                colyseus_process();
                colyseus_predict_tick(_reckon, colyseus_predict_now());
                var _steps = colyseus_predict_tick(_lerp, colyseus_predict_now());
                repeat (_steps) colyseus_input_send(_input);
                var _st = __colyseus_room_get_state(_t.room);
                var _b = __colyseus_map_get(_st, "bots", "bot1");
                if (_b == 0) _b = __colyseus_map_get(_st, "bots", "bot");
                if (_b == 0) continue;
                var _v = colyseus_predict_value(_lerp, _b, "x");
                var _r = colyseus_predict_value(_reckon, _b, "x");
                if (is_nan(_v) || _v < -1 || _v > SIM_ARENA_W + 1 || is_nan(_r)) _env.bad += 1;
                else {
                    _env.reads += 1;
                    if (_env.last >= 0 && _v != _env.last) _env.moved += 1;
                    _env.last = _v;
                }
            }
            expect(_env.bad).toBe(0);
            expect(_env.reads).toBeGreaterThan(10);
            expect(_env.moved).toBeGreaterThan(20);
            colyseus_predict_free(_lerp);
            colyseus_predict_free(_reckon);
        });
    });

    describe("Predict (functions): composite sim (hockey)", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptf = predict_test_join("lab-hockey");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptf);
            global.__ptf = undefined;
        });

        test("struct world step: puck leads authority; corrections stay small", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            colyseus_send(_t.room, "bot", { on: false });

            var _input = colyseus_room_input(_t.room);
            var _predict = colyseus_predict_for_room(_t.room);
            var _self = predict_test_me(_t);
            var _puck = predict_test_ref(_t, "puck");
            expect(_self).toBeGreaterThan(0);
            expect(_puck).toBeGreaterThan(0);

            var _sim = colyseus_predict_sim_reconciler(_predict, {
                world: { me: _self, puck: _puck },
                smooth_ms: 0,
                step: predict_test_flat_hockey,
            });
            expect(_sim).toBeGreaterThan(0);

            var _env = {
                sim: _sim, t: _t,
                corrections: [], peak_lead: 0, phase_t: current_time, seek: true,
            };
            var _stepper = method(_env, function(_inp) {
                if (current_time - phase_t > 1500) { seek = !seek; phase_t = current_time; }
                var _tx = seek ? colyseus_reconciler_value(sim, "puck.x") : SIM_ARENA_W / 2;
                var _ty = seek ? colyseus_reconciler_value(sim, "puck.y") : SIM_ARENA_H - 8;
                var _px = colyseus_reconciler_value(sim, "me.x");
                var _py = colyseus_reconciler_value(sim, "me.y");
                colyseus_input_set(_inp, "moveX", _tx - _px > 1 ? 1 : (_tx - _px < -1 ? -1 : 0));
                colyseus_input_set(_inp, "moveY", _ty - _py > 1 ? 1 : (_ty - _py < -1 ? -1 : 0));
            });
            var _sampler = method(_env, function() {
                array_push(corrections, colyseus_reconciler_last_correction_mag(sim));
                var _st = __colyseus_room_get_state(t.room);
                var _pk = __colyseus_schema_get_number(_st, "puck");
                if (_pk == 0) return;
                var _lead = abs(colyseus_reconciler_value(sim, "puck.x") - __colyseus_schema_get_number(_pk, "x"));
                if (_lead > peak_lead) peak_lead = _lead;
            });
            predict_test_flat_drive(_predict, _input, 8000, _stepper, _sampler);

            expect(colyseus_reconciler_reconcile_seq(_sim)).toBeGreaterThan(20);
            array_sort(_env.corrections, true);
            var _median = _env.corrections[array_length(_env.corrections) div 2];
            expect(_median).toBeLessThan(0.5);
            expect(_env.peak_lead).toBeGreaterThan(0.3);
            _t.state = __colyseus_room_get_state(_t.room);
            _puck = __colyseus_schema_get_number(_t.state, "puck");
            expect(abs(colyseus_reconciler_value(_sim, "puck.x") - colyseus_predict_value(_predict, _puck, "x"))).toBeLessThan(3);
            expect(abs(colyseus_sim_reconciler_world(_sim).puck.x - colyseus_reconciler_value(_sim, "puck.x"))).toBeLessThan(6);

            colyseus_reconciler_free(_sim);
            colyseus_predict_free(_predict);
        });
    });

    describe("Predict (functions): optimistic events", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptf = predict_test_join("lab-goal");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptf);
            global.__ptf = undefined;
        });

        test("colyseus_step_predict confirms; deny-rate 100 auto-rejects", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = colyseus_room_input(_t.room);
            var _predict = colyseus_predict_for_room(_t.room);
            var _self = predict_test_me(_t);
            expect(_self).toBeGreaterThan(0);

            var _tally = { predicted: 0, confirmed: 0, rejected: 0 };
            var _goals = colyseus_event_channel_create(_predict, {
                grace_ticks: 10,
                on_predict: method(_tally, function(_k) { predicted += 1; }),
                on_confirm: method(_tally, function(_k) { confirmed += 1; }),
                on_reject: method(_tally, function(_k) { rejected += 1; }),
            });
            expect(_goals).toBeGreaterThan(0);
            colyseus_on_message(_t.room, method({ goals: _goals, sid: _t.sid }, function(_room, _type, _payload) {
                if (_type == "goal" && is_struct(_payload) && _payload[$ "sid"] == sid) {
                    colyseus_event_channel_confirm(goals);
                }
            }));

            // the scoring gate inside the reconciled step (src/shared/goal.ts);
            // no is_replay guard: replays must not predict twice
            var _me = colyseus_predict_reconciler(_predict, _self, {
                fields: ["x", "y", "vx", "vy", "scoreTicks"],
                smooth_ms: 66.67,
                step: method({ goals: _goals }, function(_ctx, _s, _cmd) {
                    predict_test_flat_movement(_ctx, _s, _cmd);
                    if (_s.scoreTicks > 0) {
                        _s.scoreTicks -= 1;
                    } else if (_s.x >= SIM_ARENA_W - 8
                            && _s.y >= SIM_ARENA_H / 2 - 9
                            && _s.y <= SIM_ARENA_H / 2 + 9) {
                        _s.scoreTicks = 50;
                        colyseus_step_predict(goals, "goal-" + string(_ctx.tick));
                    }
                }),
            });
            expect(_me).toBeGreaterThan(0);

            colyseus_send(_t.room, "denyRate", { rate: 0 });
            var _seeker = method({ me: _me }, function(_inp) {
                var _x = colyseus_reconciler_value(me, "x");
                var _y = colyseus_reconciler_value(me, "y");
                colyseus_input_set(_inp, "moveX", _x >= SIM_ARENA_W - 8 ? -1 : 1);
                colyseus_input_set(_inp, "moveY", _y > SIM_ARENA_H / 2 + 1 ? -1 : (_y < SIM_ARENA_H / 2 - 1 ? 1 : 0));
            });
            predict_test_flat_drive(_predict, _input, 7000, _seeker);
            expect(_tally.predicted).toBeGreaterThan(0);
            expect(_tally.confirmed).toBeGreaterThan(0);
            expect(_tally.rejected).toBe(0);
            expect(_tally.confirmed).toBeLessThan(_tally.predicted + 1);

            colyseus_send(_t.room, "denyRate", { rate: 100 });
            var _before = _tally.predicted;
            predict_test_flat_drive(_predict, _input, 8000, _seeker);
            expect(_tally.predicted).toBeGreaterThan(_before);
            expect(_tally.rejected).toBeGreaterThan(0);

            colyseus_event_channel_free(_goals);
            colyseus_reconciler_free(_me);
            colyseus_predict_free(_predict);
        });
    });

    describe("Predict (functions): predicted spawns", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptf = predict_test_join("lab-projectile");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptf);
            global.__ptf = undefined;
        });

        test("a local spawn hands off to the server's entity under the same id", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            var _input = colyseus_room_input(_t.room);
            var _predict = colyseus_predict_for_room(_t.room);
            var _self = predict_test_me(_t);
            expect(_self).toBeGreaterThan(0);

            var _shots = colyseus_spawns_create(_predict, "projectiles", {
                fields: ["x", "y", "vx", "vy"],
                owned_field: "owner",
                owned_value: _t.sid,
                spawn_time_field: "bornMs",
                step_id: COLYSEUS_STEP_INTEGRATE,
                step_params: json_stringify({ bounds: [0, 0, SIM_ARENA_W, SIM_ARENA_H], edge: "bounce" }),
            });
            expect(_shots).toBeGreaterThan(0);

            colyseus_input_set(_input, "aimX", SIM_ARENA_W - 5);
            colyseus_input_set(_input, "aimY", SIM_ARENA_H / 2);
            colyseus_input_set(_input, "fire", 1);
            var _sid = colyseus_spawns_spawn(_shots, {
                x: __colyseus_schema_get_number(_self, "x"),
                y: __colyseus_schema_get_number(_self, "y"),
                vx: 34, vy: 0,
            });
            expect(_sid).toBeGreaterThan(0);
            expect(array_length(colyseus_spawns_entries(_shots))).toBeGreaterThan(0);
            expect(colyseus_spawns_alive(_shots, _sid)).toBeTruthy();
            expect(is_nan(colyseus_spawns_value(_shots, _sid, "x"))).toBeFalsy();

            predict_test_flat_drive(_predict, _input, 400, function(_inp) {
                colyseus_input_set(_inp, "moveX", 0);
                colyseus_input_set(_inp, "moveY", 0);
            });
            colyseus_input_set(_input, "fire", 0);

            var _confirmed = false;
            var _lead = 0;
            var _start = current_time;
            while (current_time - _start < 5000 && !_confirmed) {
                colyseus_process();
                colyseus_predict_tick(_predict, colyseus_predict_now());
                var _es = colyseus_spawns_entries(_shots);
                for (var _i = 0; _i < array_length(_es); _i++) {
                    if (_es[_i].id == _sid && _es[_i].confirmed) { _confirmed = true; _lead = _es[_i].lead_ms; }
                }
            }
            expect(_confirmed).toBeTruthy();
            expect(_lead).toBeGreaterThan(0);
            expect(is_nan(colyseus_spawns_value(_shots, _sid, "x"))).toBeFalsy();

            colyseus_spawns_free(_shots);
            colyseus_predict_free(_predict);
        });
    });

    describe("Predict (functions): drop + reconnect", function() {

        beforeEach(function() {
            test_drain_events();
            global.__ptf = predict_test_join("lab-move");
        });
        afterEach(function() {
            predict_test_teardown(global.__ptf);
            global.__ptf = undefined;
        });

        test("rebuild keeps the reconciler handle and its precision", function() {
            var _t = global.__ptf;
            expect(_t.ok).toBeTruthy();
            predict_test_settle(_t);
            colyseus_room_set_reconnection_options(_t.room, 1, 10, 100, 1000, 500, 100, -1);

            var _input = colyseus_room_input(_t.room);
            var _predict = colyseus_predict_for_room(_t.room);
            var _self = predict_test_me(_t);
            expect(_self).toBeGreaterThan(0);
            var _me = colyseus_predict_reconciler(_predict, _self, {
                fields: ["x", "y", "vx", "vy"],
                smooth_ms: 66.67, snap: 8,
                step: predict_test_flat_movement,
            });
            predict_test_flat_drive(_predict, _input, 1500, predict_test_flat_seek_right);
            expect(colyseus_reconciler_drift(_me).ema).toBeLessThan(0.01);
            var _epoch_before = colyseus_input_epoch(_input);

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
            expect(colyseus_input_epoch(_input)).toBeGreaterThan(_epoch_before);

            _t.state = __colyseus_room_get_state(_t.room);
            var _self2 = predict_test_me(_t);
            expect(_self2).toBeGreaterThan(0);
            colyseus_reconciler_rebuild(_me, _self2);
            expect(is_nan(colyseus_reconciler_value(_me, "x"))).toBeFalsy();

            predict_test_flat_drive(_predict, _input, 2500, function(_inp) {
                colyseus_input_set(_inp, "moveX", -1);
                colyseus_input_set(_inp, "moveY", 0);
            });
            expect(colyseus_reconciler_reconcile_seq(_me)).toBeGreaterThan(5);
            expect(colyseus_reconciler_drift(_me).ema).toBeLessThan(0.01);

            colyseus_reconciler_free(_me);
            colyseus_predict_free(_predict);
        });
    });
});
