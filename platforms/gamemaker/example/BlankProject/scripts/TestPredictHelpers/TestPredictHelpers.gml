// =============================================================================
// Shared helpers for the prediction test suites.
//
// These suites need the prediction-tools playground server on :5173
// (`cd demos/prediction-tools && pnpm dev --host 0.0.0.0`) — its lab rooms
// (lab-move / lab-bots / lab-hockey / lab-goal / lab-projectile) advertise
// INPUT_REFLECTION and run the shared deterministic sim at 20 Hz.
// =============================================================================

#macro PREDICT_TEST_ENDPOINT "http://127.0.0.1:5173"

// shared sim constants (src/shared/constants.ts, verbatim)
#macro SIM_ARENA_W 100
#macro SIM_ARENA_H 60
#macro SIM_PLAYER_HALF 1.6
#macro SIM_PLAYER_ACCEL 220
#macro SIM_PLAYER_MAX_SPEED 34
#macro SIM_PLAYER_FRICTION_K 0.72
#macro SIM_SQRT1_2 0.70710678118654752440
// hockey (src/shared/hockey.ts)
#macro SIM_PADDLE_RADIUS 2.2
#macro SIM_PUCK_RADIUS 1.4
#macro SIM_PUCK_FRICTION_K 0.985
#macro SIM_PUCK_RESTITUTION 0.92
#macro SIM_PUCK_PUSH_MIN 14

/// Join a lab room; poll until joined AND the first state decode landed.
/// Returns { client, room, sid, state, ok }.
function predict_test_join(_room_name) {
    var _ctx = { client: -1, room: -1, sid: "", state: 0, ok: false, done: false };
    _ctx.client = colyseus_client_create(PREDICT_TEST_ENDPOINT);
    if (_ctx.client <= 0) return _ctx;
    _ctx.room = colyseus_client_join_or_create(_ctx.client, _room_name, "{}");
    if (_ctx.room <= 0) return _ctx;
    colyseus_on_join(_ctx.room, method(_ctx, function(_r) { done = true; }));
    var _start = current_time;
    while (current_time - _start < 8000) {
        colyseus_process();
        if (_ctx.done) {
            _ctx.state = __colyseus_room_get_state(_ctx.room);
            if (_ctx.state != 0) break;
        }
    }
    _ctx.sid = colyseus_room_get_session_id(_ctx.room);
    _ctx.ok = _ctx.done && _ctx.state != 0 && string_length(_ctx.sid) > 0;
    return _ctx;
}

/// Let the initial decode + resync settle: instance handles captured during
/// the very first patches can be REPLACED by the decoder (raw-pointer handles
/// dangle) — capture only after the stream has been stable for a moment.
function predict_test_settle(_ctx, _ms = 600) {
    var _start = current_time;
    while (current_time - _start < _ms) { colyseus_process(); }
    _ctx.state = __colyseus_room_get_state(_ctx.room);
}

/// The raw decoded instance handle of OUR player in the `players` map.
/// Polls briefly — the entry can trail the first state patch.
function predict_test_me(_ctx) {
    var _start = current_time;
    var _me = 0;
    while (current_time - _start < 4000) {
        colyseus_process();
        // fresh root each poll — colyseus_process may have replaced instances
        _ctx.state = __colyseus_room_get_state(_ctx.room);
        _me = __colyseus_map_get(_ctx.state, "players", _ctx.sid);
        if (_me != 0) break;
    }
    return _me;
}

/// Leave + free with a settle drain (mirrors the TestRoomApi teardown).
function predict_test_teardown(_ctx) {
    if (_ctx.room > 0) {
        colyseus_room_leave(_ctx.room);
        var _start = current_time;
        while (current_time - _start < 500) { colyseus_process(); }
        colyseus_room_free(_ctx.room);
    }
    if (_ctx.client > 0) colyseus_client_free(_ctx.client);
    test_drain_events();
}

/// Drive the full per-frame prediction contract for _ms wall-clock ms:
/// process → tick → per-step _input_fn(input) + send + pump → pump.
/// _frame_fn (optional) runs once per iteration for sampling.
function predict_test_drive(_predict, _input, _recon, _ms, _input_fn, _frame_fn = undefined) {
    var _start = current_time;
    while (current_time - _start < _ms) {
        colyseus_process();
        var _steps = _predict.tick(colyseus_predict_now());
        if (_recon != undefined) _recon.pump();
        repeat (_steps) {
            if (_input_fn != undefined) _input_fn(_input);
            _input.send();
            if (_recon != undefined) _recon.pump();
        }
        if (_frame_fn != undefined) _frame_fn();
    }
}

/// stepEntity (src/shared/movement.ts) against a reconciler mirror — the
/// transliteration whose exactness the drift_ema assertions prove.
function predict_test_step_movement(_ctx, _s, _cmd) {
    var _ax = _cmd.get("moveX");
    var _ay = _cmd.get("moveY");
    if (_ax != 0 && _ay != 0) { _ax *= SIM_SQRT1_2; _ay *= SIM_SQRT1_2; }

    var _vx = _s.get("vx");
    var _vy = _s.get("vy");
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

    var _x = _s.get("x") + _vx * _ctx.dt;
    var _y = _s.get("y") + _vy * _ctx.dt;

    var _min_x = SIM_PLAYER_HALF, _max_x = SIM_ARENA_W - SIM_PLAYER_HALF;
    var _min_y = SIM_PLAYER_HALF, _max_y = SIM_ARENA_H - SIM_PLAYER_HALF;
    if (_x < _min_x) { _x = _min_x; if (_vx < 0) _vx = 0; }
    else if (_x > _max_x) { _x = _max_x; if (_vx > 0) _vx = 0; }
    if (_y < _min_y) { _y = _min_y; if (_vy < 0) _vy = 0; }
    else if (_y > _max_y) { _y = _max_y; if (_vy > 0) _vy = 0; }

    _s.set("x", _x);
    _s.set("y", _y);
    _s.set("vx", _vx);
    _s.set("vy", _vy);
}

/// stepPuck (src/shared/hockey.ts) against a { get/set } mirror view.
function predict_test_step_puck(_p, _dt) {
    var _vx = _p.get("vx") * SIM_PUCK_FRICTION_K;
    var _vy = _p.get("vy") * SIM_PUCK_FRICTION_K;
    var _x = _p.get("x") + _vx * _dt;
    var _y = _p.get("y") + _vy * _dt;
    var _min = SIM_PUCK_RADIUS;
    var _max_x = SIM_ARENA_W - SIM_PUCK_RADIUS;
    var _max_y = SIM_ARENA_H - SIM_PUCK_RADIUS;
    if (_x < _min) { _x = _min; _vx = abs(_vx) * SIM_PUCK_RESTITUTION; }
    else if (_x > _max_x) { _x = _max_x; _vx = -abs(_vx) * SIM_PUCK_RESTITUTION; }
    if (_y < _min) { _y = _min; _vy = abs(_vy) * SIM_PUCK_RESTITUTION; }
    else if (_y > _max_y) { _y = _max_y; _vy = -abs(_vy) * SIM_PUCK_RESTITUTION; }
    _p.set("x", _x); _p.set("y", _y); _p.set("vx", _vx); _p.set("vy", _vy);
}

/// collidePaddlePuck (src/shared/hockey.ts) — order-dependent, resolve in
/// the server's players-map order.
function predict_test_collide_paddle_puck(_paddle, _puck) {
    var _dx = _puck.get("x") - _paddle.get("x");
    var _dy = _puck.get("y") - _paddle.get("y");
    var _r = SIM_PADDLE_RADIUS + SIM_PUCK_RADIUS;
    var _d2 = _dx * _dx + _dy * _dy;
    if (_d2 >= _r * _r) return false;
    var _d = sqrt(_d2);
    if (_d == 0) _d = 0.000001;
    var _nx = _dx / _d, _ny = _dy / _d;
    var _px = _paddle.get("x") + _nx * _r;
    var _py = _paddle.get("y") + _ny * _r;
    var _pvx = _paddle.get("vx"), _pvy = _paddle.get("vy");
    var _along = _pvx * _nx + _pvy * _ny;
    var _speed = _along > SIM_PUCK_PUSH_MIN ? _along : SIM_PUCK_PUSH_MIN;
    var _vx = _nx * _speed + _pvx * 0.35;
    var _vy = _ny * _speed + _pvy * 0.35;
    var _min = SIM_PUCK_RADIUS;
    var _max_x = SIM_ARENA_W - SIM_PUCK_RADIUS;
    var _max_y = SIM_ARENA_H - SIM_PUCK_RADIUS;
    if (_px < _min) { _px = _min; _vx = abs(_vx) * SIM_PUCK_RESTITUTION; }
    else if (_px > _max_x) { _px = _max_x; _vx = -abs(_vx) * SIM_PUCK_RESTITUTION; }
    if (_py < _min) { _py = _min; _vy = abs(_vy) * SIM_PUCK_RESTITUTION; }
    else if (_py > _max_y) { _py = _max_y; _vy = -abs(_vy) * SIM_PUCK_RESTITUTION; }
    _puck.set("x", _px); _puck.set("y", _py);
    _puck.set("vx", _vx); _puck.set("vy", _vy);
    return true;
}
