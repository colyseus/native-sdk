// =============================================================================
// Colyseus GML Wrapper — prediction layer
//
// colyseus_* functions over the __colyseus_gm_* extension bindings, named
// after the native SDK's C API. Handles are numbers, like room refs:
//
//   input   = colyseus_room_input(net_room);
//   predict = colyseus_predict_for_room(net_room);
//   me = colyseus_predict_reconciler(predict, self_player, {
//       fields: ["x", "y"],
//       step: function(_ctx, _s, _cmd) { _s.x += _cmd.moveX * SPEED * _ctx.dt; },
//   });
//
// Per-Step order, as in the JS SDK:
//   colyseus_process();
//   var _steps = colyseus_predict_tick(predict, colyseus_predict_now());
//   repeat (_steps) {
//       colyseus_input_set(input, "moveX", mx);
//       colyseus_input_send(input);
//   }
//   draw with colyseus_predict_value(predict, entity, "x") / colyseus_reconciler_value(me, "x")
//
// GameMaker's FFI can never call GML, so the native reconcilers run in manual
// mode and these GML functions run the steps for them:
// colyseus_predict_tick() replays the unacked inputs after a server
// correction, and colyseus_input_send() steps the input just sent. Dead-reckon
// steps run C-side (COLYSEUS_STEP_INTEGRATE: x/y/vx/vy with optional
// bounds/friction/maxSpeed params). Event-channel settlement and spawn
// rejections arrive through colyseus_process() as queued events, one frame
// after the fact.
//
// The ColyseusInput / ColyseusPredict constructors at the end of this script
// predate these functions and delegate to them.
// =============================================================================

#macro COLYSEUS_EVENT_PREDICT_SETTLE  19
#macro COLYSEUS_EVENT_SPAWN_REJECT    20

// colyseus_predict_mode_t
#macro COLYSEUS_PREDICT_LERP         0
#macro COLYSEUS_PREDICT_EXTRAPOLATE  1
#macro COLYSEUS_PREDICT_DAMPED       2
#macro COLYSEUS_PREDICT_RECKON       3
#macro COLYSEUS_PREDICT_RAW          4

// built-in C-side reckon steps
#macro COLYSEUS_STEP_NONE       0
#macro COLYSEUS_STEP_INTEGRATE  1

global.__colyseus_predict_rooms = array_create(9, 0);              // predict id → room ref
global.__colyseus_predict_recons = [undefined];                    // reconciler handle → record
global.__colyseus_predict_channels = array_create(17, undefined);  // channel id → settlement callbacks
global.__colyseus_predict_channel_owner = array_create(17, 0);     // channel id → predict id
global.__colyseus_predict_spawns = array_create(9, undefined);     // spawns id → on_reject holder
global.__colyseus_predict_spawns_owner = array_create(9, 0);       // spawns id → predict id

/// Monotonic ms — the time base colyseus_predict_tick() paces against.
function colyseus_predict_now() {
    return __colyseus_gm_now();
}

/// @ignore instance argument → native handle (cached struct or raw).
/// Used by both scripts, defined HERE: the HTML5 emitter writes a broken
/// `function name{}` stub when a constructor's static method calls a function
/// from another script, and the static methods below are the callers.
function __colyseus_handle(_x) {
    return is_struct(_x) ? _x.__handle : _x;
}

/// @ignore predict/reconciler/channel/spawns argument → its handle (the
/// constructors' structs carry it as `id`)
function __colyseus_predict_ref(_x) {
    return is_struct(_x) ? _x.id : _x;
}

/// @ignore input/clock argument → room ref (ColyseusInput/ColyseusClock carry it)
function __colyseus_room_ref(_x) {
    return is_struct(_x) ? _x.room_ref : _x;
}

/// @ignore optional struct member with default
function __colyseus_predict_opt(_s, _k, _def) {
    if (is_struct(_s) && variable_struct_exists(_s, _k)) {
        return variable_struct_get(_s, _k);
    }
    return _def;
}

/// @ignore ["x","y"] → "x,y"
function __colyseus_predict_csv(_fields) {
    if (is_string(_fields)) return _fields;
    var _csv = "";
    for (var _i = 0; _i < array_length(_fields); _i++) {
        if (_i > 0) _csv += ",";
        _csv += _fields[_i];
    }
    return _csv;
}

/// @ignore the numeric (scalar) field names of a schema handle
function __colyseus_predict_numeric_fields(_handle) {
    var _out = [];
    var _n = __colyseus_schema_field_count(_handle);
    for (var _i = 0; _i < _n; _i++) {
        var _type = __colyseus_schema_field_type_at(_handle, _i);
        if (_type > COLYSEUS_TYPE_STRING && _type < COLYSEUS_TYPE_REF) {
            array_push(_out, __colyseus_schema_field_name(_handle, _i));
        }
    }
    return _out;
}

// =============================================================================
// Input — the room-owned singleton, synthesized from INPUT_REFLECTION
// =============================================================================

/// The room's input handle, like room.input() in the JS SDK. Join first: the
/// room must have advertised its input type. Options are first-call-wins.
/// @param {Real} _room_ref  Room reference
/// @param {Struct} [_opts]  { render_delay, history_size }
/// @returns {Real} Input handle, 0 on failure
function colyseus_room_input(_room_ref, _opts = undefined) {
    var _ok = __colyseus_gm_input_init(_room_ref,
        __colyseus_predict_opt(_opts, "unreliable", 0) ? 1 : 0,
        __colyseus_predict_opt(_opts, "history_size", 0),
        __colyseus_predict_opt(_opts, "render_delay", 0)) > 0;
    if (!_ok) {
        show_debug_message("colyseus_room_input: failed (not joined yet, or the room defines no input)");
        return 0;
    }
    return _room_ref;
}

/// Stage one field of the next input.
function colyseus_input_set(_input, _field, _value) {
    return __colyseus_gm_input_set(__colyseus_room_ref(_input), _field, _value);
}
/// The staged value of a field (NaN for unknown fields).
function colyseus_input_get(_input, _field) {
    return __colyseus_gm_input_get(__colyseus_room_ref(_input), _field);
}
/// Send the staged input and step it on every reconciler that uses this
/// input. Returns its 1-based seq (0 = nothing sent).
function colyseus_input_send(_input) {
    var _room = __colyseus_room_ref(_input);
    var _seq = __colyseus_gm_input_send(_room);
    __colyseus_predict_pump(0, _room);
    return _seq;
}
function colyseus_input_sent_count(_input)     { return __colyseus_gm_input_stat(__colyseus_room_ref(_input), 0); }
function colyseus_input_last_processed(_input) { return __colyseus_gm_input_stat(__colyseus_room_ref(_input), 1); }
function colyseus_input_pending_count(_input)  { return __colyseus_gm_input_stat(__colyseus_room_ref(_input), 2); }
function colyseus_input_epoch(_input)          { return __colyseus_gm_input_stat(__colyseus_room_ref(_input), 3); }
/// The room's simulation rate in Hz (0 when the server does not advertise it).
function colyseus_input_tick_rate(_input)      { return __colyseus_gm_input_stat(__colyseus_room_ref(_input), 4); }
function colyseus_input_patch_rate(_input)     { return __colyseus_gm_input_stat(__colyseus_room_ref(_input), 5); }
function colyseus_input_render_delay(_input)   { return __colyseus_gm_input_stat(__colyseus_room_ref(_input), 7); }
function colyseus_input_set_render_delay(_input, _ms) {
    __colyseus_gm_input_set_render_delay(__colyseus_room_ref(_input), _ms);
}
/// Lag-comp gate: stamp rewind times only on inputs whose _field is nonzero
/// (set the field before send). "" clears the gate.
function colyseus_input_set_rewind_field(_input, _field) {
    return __colyseus_gm_input_set_rewind_field(__colyseus_room_ref(_input), _field);
}
function colyseus_input_reset(_input) {
    __colyseus_gm_input_reset(__colyseus_room_ref(_input));
}

// =============================================================================
// Room clock readouts
// =============================================================================

global.__colyseus_room_clocks = ds_map_create();  // room ref → ColyseusClock

/// The room's clock, like room.clock in the JS SDK: one per room, never
/// undefined. Read it with the colyseus_room_clock_* functions, which return
/// 0 until the room has joined.
///   var _rtt = colyseus_room_clock_rtt(colyseus_room_get_clock(net_room));
/// @param {Real} _room_ref  Room reference
/// @returns {Struct.ColyseusClock}
function colyseus_room_get_clock(_room_ref) {
    var _clock = ds_map_find_value(global.__colyseus_room_clocks, _room_ref);
    if (_clock == undefined) {
        // a clock holds only its ref, so the one cached for a freed room serves the next
        _clock = new ColyseusClock(_room_ref);
        ds_map_set(global.__colyseus_room_clocks, _room_ref, _clock);
    }
    return _clock;
}

// Each takes the clock or the room ref.
function colyseus_room_clock_now(_clock)              { return __colyseus_gm_now(); }
function colyseus_room_clock_server_now(_clock)       { return __colyseus_gm_clock_stat(__colyseus_room_ref(_clock), 0); }
function colyseus_room_clock_render_now(_clock)       { return __colyseus_gm_clock_stat(__colyseus_room_ref(_clock), 1); }
function colyseus_room_clock_rtt(_clock)              { return __colyseus_gm_clock_stat(__colyseus_room_ref(_clock), 2); }
function colyseus_room_clock_smoothed_rtt(_clock)     { return __colyseus_gm_clock_stat(__colyseus_room_ref(_clock), 3); }
function colyseus_room_clock_jitter(_clock)           { return __colyseus_gm_clock_stat(__colyseus_room_ref(_clock), 4); }
function colyseus_room_clock_last_server_time(_clock) { return __colyseus_gm_clock_stat(__colyseus_room_ref(_clock), 5); }
function colyseus_room_clock_patch_interval(_clock)   { return __colyseus_gm_clock_stat(__colyseus_room_ref(_clock), 6); }

// =============================================================================
// Netdelay injector (debug latency + the drop button)
// =============================================================================

/// Both numbers are ROUND TRIPS, split evenly across the two directions, so
/// _delay_ms is what the clock's rtt converges to — matching the JS SDK's __net().
function colyseus_netdelay_set(_room_ref, _delay_ms, _jitter_ms = 0) {
    __colyseus_gm_netdelay_set(_room_ref, _delay_ms, _jitter_ms);
}
function colyseus_netdelay_in_flight() {
    return __colyseus_gm_netdelay_in_flight();
}
function colyseus_netdelay_drop(_room_ref) {
    __colyseus_gm_netdelay_drop(_room_ref);
}

// =============================================================================
// Predict — the app-facing controller
// =============================================================================

/// A Predict scoped to the room: the smoothing, reckoning and rollback
/// controller. Free it with colyseus_predict_free().
/// @param {Real} _room_ref  Room reference
/// @returns {Real} Predict handle, 0 on failure
function colyseus_predict_for_room(_room_ref) {
    var _id = __colyseus_gm_predict_create(_room_ref);
    if (_id <= 0) {
        show_debug_message("colyseus_predict_for_room: failed (not joined yet?)");
        return 0;
    }
    global.__colyseus_predict_rooms[_id] = _room_ref;
    return _id;
}

/// Free a Predict with every reconciler, event channel and spawn store made from it.
function colyseus_predict_free(_predict) {
    var _pid = __colyseus_predict_ref(_predict);
    if (_pid <= 0) return;
    var _recons = global.__colyseus_predict_recons;
    for (var _i = 1; _i < array_length(_recons); _i++) {
        if (_recons[_i] != undefined && _recons[_i].predict == _pid) global.__colyseus_predict_recons[_i] = undefined;
    }
    for (var _i = 1; _i < array_length(global.__colyseus_predict_channels); _i++) {
        if (global.__colyseus_predict_channel_owner[_i] == _pid) {
            global.__colyseus_predict_channels[_i] = undefined;
            global.__colyseus_predict_channel_owner[_i] = 0;
        }
    }
    for (var _i = 1; _i < array_length(global.__colyseus_predict_spawns); _i++) {
        if (global.__colyseus_predict_spawns_owner[_i] == _pid) {
            global.__colyseus_predict_spawns[_i] = undefined;
            global.__colyseus_predict_spawns_owner[_i] = 0;
        }
    }
    __colyseus_gm_predict_free(_pid);
    global.__colyseus_predict_rooms[_pid] = 0;
}

/// Advance the whole prediction stack, replaying the unacked inputs after a
/// server correction. Returns the fixed input steps due this frame: send
/// exactly that many inputs.
function colyseus_predict_tick(_predict, _now) {
    var _pid = __colyseus_predict_ref(_predict);
    var _steps = __colyseus_gm_predict_tick(_pid, _now);
    __colyseus_predict_pump(_pid, 0);
    return _steps;
}

/// Smooth fields of one instance:
///   colyseus_predict_attach(predict, ball, { x: COLYSEUS_PREDICT_DAMPED, y: { mode: COLYSEUS_PREDICT_LERP, delay: 100 } });
function colyseus_predict_attach(_predict, _instance, _config) {
    return __colyseus_gm_predict_attach(__colyseus_predict_ref(_predict),
        __colyseus_handle(_instance), json_stringify(_config));
}
/// Track every entry of a collection, present and future. _except = a key to
/// leave out (your own session id: the reconciler owns that entity).
function colyseus_predict_attach_all(_predict, _collection, _config = undefined, _except = "") {
    var _spec = { collection: _collection, except: _except };
    if (_config != undefined) _spec.config = _config;
    return __colyseus_gm_predict_attach_all(__colyseus_predict_ref(_predict), 0, json_stringify(_spec));
}
/// Dead-reckon an instance through a built-in C step (COLYSEUS_STEP_INTEGRATE).
function colyseus_predict_attach_reckon(_predict, _instance, _fields, _step_id, _params = "",
                                        _smooth_ms = 0, _substep_ms = 0, _snap = 0) {
    return __colyseus_gm_predict_attach_reckon(__colyseus_predict_ref(_predict),
        __colyseus_handle(_instance), json_stringify({
            fields: __colyseus_predict_csv(_fields),
            step_id: _step_id, step_params: _params,
            smooth_ms: _smooth_ms, substep_ms: _substep_ms, snap: _snap,
        }));
}
/// Dead-reckon every entry of a collection, present and future.
function colyseus_predict_attach_all_reckon(_predict, _collection, _fields, _step_id, _params = "",
                                            _smooth_ms = 0, _substep_ms = 0, _snap = 0) {
    return __colyseus_gm_predict_attach_all_reckon(__colyseus_predict_ref(_predict), 0, json_stringify({
        collection: _collection,
        fields: __colyseus_predict_csv(_fields),
        step_id: _step_id, step_params: _params,
        smooth_ms: _smooth_ms, substep_ms: _substep_ms, snap: _snap,
    }));
}
function colyseus_predict_detach(_predict, _instance) {
    __colyseus_gm_predict_detach(__colyseus_predict_ref(_predict), __colyseus_handle(_instance));
}

/// One read idiom: smoothed/reckoned/reconciled value of a tracked field,
/// raw decoded fallback when untracked, NaN for unknown fields.
function colyseus_predict_value(_predict, _instance, _field) {
    return __colyseus_gm_predict_value(__colyseus_predict_ref(_predict), __colyseus_handle(_instance), _field);
}
function colyseus_predict_value_at(_predict, _instance, _field, _time) {
    return __colyseus_gm_predict_value_at(__colyseus_predict_ref(_predict),
        __colyseus_handle(_instance), _field, _time);
}

// =============================================================================
// Reconciler — rollback for your own entity (flat) or a world (sim)
// =============================================================================

/// Rollback for your own entity. _opts:
///   fields     field names the reconciler corrects and smooths (omit = every numeric field)
///   step       function(_ctx, _s, _cmd): the SAME step the server runs
///   smooth_ms  correction smoothing (omit for the default, 0 = snap)
///   snap       correction distance that skips smoothing (0 = off)
///   step_ms, sub_steps, input (default: the room's input)
///
/// The step runs inside colyseus_input_send() for each input sent, and again
/// inside colyseus_predict_tick() to replay after a correction. It gets plain structs: _ctx { dt, dt_ms, tick, is_replay, reckon_time,
/// lag_comp_active, sub_steps, sub_dt, sub_dt_ms }, _s (the entity's numeric
/// fields; what you assign is kept) and _cmd (the input fields). They are
/// only valid during the call.
/// @returns {Real} Reconciler handle, 0 on failure
function colyseus_predict_reconciler(_predict, _truth, _opts) {
    return __colyseus_reconciler_create(__colyseus_predict_ref(_predict), _truth, _opts, false);
}

/// Rollback for several entities stepped together. _opts as
/// colyseus_predict_reconciler(), plus world: { name: instance, ... }. The
/// step's second argument is the world: _w.puck.x. Read rendered values as
/// colyseus_reconciler_value(me, "puck.x").
/// @returns {Real} Reconciler handle, 0 on failure
function colyseus_predict_sim_reconciler(_predict, _opts) {
    return __colyseus_reconciler_create(__colyseus_predict_ref(_predict), undefined, _opts, false);
}

/// @ignore run every due step of a reconciler record: a pending reconcile's
/// replay burst, then the live catch-up
function __colyseus_reconciler_pump(_r) {
    var _id = _r.native;
    var _step = _r.step;
    var _ctx = _r.ctx;
    var _first = true;
    while (__colyseus_gm_recon_pump_begin(_id) > 0) {
        while (__colyseus_gm_recon_pump_next(_id) > 0) {
            __colyseus_step_ctx_refresh(_ctx, _first);
            _first = false;
            if (_r.legacy) {
                _step(_ctx, _r.world != undefined ? _r.world : _r.state, _r.cmd);
            } else {
                var _cmd = _r.cmd;
                var _names = _r.cmd_fields;
                for (var _i = 0; _i < array_length(_names); _i++) {
                    _cmd[$ _names[_i]] = __colyseus_gm_step_cmd(_names[_i]);
                }
                var _parts = _r.parts;
                for (var _p = 0; _p < array_length(_parts); _p++) __colyseus_view_read(_parts[_p]);
                _step(_ctx, _r.view, _cmd);
                for (var _p = 0; _p < array_length(_parts); _p++) __colyseus_view_write(_parts[_p]);
            }
            __colyseus_gm_recon_pump_commit(_id);
        }
        __colyseus_gm_recon_pump_end(_id);
    }
}

/// @ignore pump the reconcilers of a predict (_pid > 0) or of an input's room (_room > 0)
function __colyseus_predict_pump(_pid, _room) {
    var _recons = global.__colyseus_predict_recons;
    for (var _i = 1; _i < array_length(_recons); _i++) {
        var _r = _recons[_i];
        if (_r == undefined || _r.native <= 0) continue;
        if ((_pid > 0 && _r.predict == _pid) || (_room > 0 && _r.input_room == _room)) {
            __colyseus_reconciler_pump(_r);
        }
    }
}

/// Rendered value: a field name, or "part.field" on a sim reconciler.
function colyseus_reconciler_value(_reconciler, _field) {
    return __colyseus_gm_recon_value(__colyseus_reconciler_native(_reconciler), _field);
}
function colyseus_reconciler_pending_count(_reconciler) {
    return __colyseus_gm_recon_stat(__colyseus_reconciler_native(_reconciler), 0);
}
/// Size of the last correction (0 = the prediction matched the server).
function colyseus_reconciler_last_correction_mag(_reconciler) {
    return __colyseus_gm_recon_stat(__colyseus_reconciler_native(_reconciler), 2);
}
function colyseus_reconciler_last_correction(_reconciler, _field) {
    return __colyseus_gm_recon_last_correction(__colyseus_reconciler_native(_reconciler), _field);
}
function colyseus_reconciler_reconcile_seq(_reconciler) {
    return __colyseus_gm_recon_stat(__colyseus_reconciler_native(_reconciler), 3);
}
/// Correction telemetry: { ema, peak }.
function colyseus_reconciler_drift(_reconciler) {
    var _id = __colyseus_reconciler_native(_reconciler);
    return { ema: __colyseus_gm_recon_stat(_id, 4), peak: __colyseus_gm_recon_stat(_id, 5) };
}
function colyseus_reconciler_reset(_reconciler) {
    __colyseus_gm_recon_reset(__colyseus_reconciler_native(_reconciler));
}

/// The predicted entity outside a step, for game logic (aim, collision
/// queries): the struct a step receives, with current values. Read-only.
function colyseus_reconciler_state(_reconciler) {
    var _r = __colyseus_reconciler_record(_reconciler);
    if (_r == undefined) return undefined;
    if (_r.legacy) return _r.sim ? _r.world : _r.state;
    for (var _p = 0; _p < array_length(_r.parts); _p++) __colyseus_view_read(_r.parts[_p]);
    return _r.view;
}

/// A sim reconciler's predicted world outside a step: _w.paddle.x. Read-only.
function colyseus_sim_reconciler_world(_reconciler) {
    return colyseus_reconciler_state(_reconciler);
}

/// A reconnect resync replaces the decoded instances: rebuild against the
/// re-decoded one (a sim takes the new world struct). The handle stays valid.
function colyseus_reconciler_rebuild(_reconciler, _new_source = undefined) {
    var _r = __colyseus_reconciler_record(_reconciler);
    if (_r == undefined) return;
    __colyseus_gm_recon_free(_r.native);
    if (_new_source != undefined) _r.source = _new_source;
    __colyseus_reconciler_bind(_r);
}

function colyseus_reconciler_free(_reconciler) {
    var _h = __colyseus_predict_ref(_reconciler);
    var _r = __colyseus_reconciler_record(_h);
    if (_r == undefined) return;
    __colyseus_gm_recon_free(_r.native);
    global.__colyseus_predict_recons[_h] = undefined;
}

/// @ignore handle → record (undefined when freed)
function __colyseus_reconciler_record(_reconciler) {
    var _h = __colyseus_predict_ref(_reconciler);
    if (_h < 1 || _h >= array_length(global.__colyseus_predict_recons)) return undefined;
    return global.__colyseus_predict_recons[_h];
}

/// @ignore handle → native reconciler id
function __colyseus_reconciler_native(_reconciler) {
    var _r = __colyseus_reconciler_record(_reconciler);
    return _r == undefined ? 0 : _r.native;
}

/// @ignore _legacy: the step gets the constructors' get/set views
/// (ColyseusStepCtx, ColyseusMirror, ColyseusStepCmd) instead of plain structs
function __colyseus_reconciler_create(_pid, _truth, _opts, _legacy) {
    var _sim = variable_struct_exists(_opts, "world");
    var _r = {
        predict: _pid, opts: _opts, legacy: _legacy, sim: _sim,
        source: _sim ? _opts.world : _truth,
        step: _opts.step, native: 0, input_room: 0,
        ctx: _legacy ? new ColyseusStepCtx() : {
            dt: 0, dt_ms: 0, tick: 0, is_replay: false, reckon_time: 0,
            lag_comp_active: false, sub_steps: 0, sub_dt: 0, sub_dt_ms: 0,
        },
        cmd: _legacy ? new ColyseusStepCmd() : {},
        cmd_fields: [],
        state: undefined, world: undefined,   // legacy views
        view: undefined, parts: [],           // plain-struct views
    };
    __colyseus_reconciler_bind(_r);
    if (_r.native <= 0) return 0;
    var _recons = global.__colyseus_predict_recons;
    var _h = array_length(_recons);
    for (var _i = 1; _i < array_length(_recons); _i++) {
        if (_recons[_i] == undefined) { _h = _i; break; }
    }
    global.__colyseus_predict_recons[_h] = _r;
    return _h;
}

/// @ignore (re)create the native reconciler and its step views
function __colyseus_reconciler_bind(_r) {
    var _o = _r.opts;
    var _input = __colyseus_room_ref(__colyseus_predict_opt(_o, "input", 0));
    _r.input_room = _input != 0 ? _input : global.__colyseus_predict_rooms[_r.predict];
    _r.parts = [];
    if (_r.sim) {
        __colyseus_gm_sim_begin(_r.predict);
        var _names = variable_struct_get_names(_r.source);
        array_sort(_names, true);   // deterministic part order — server-matched
        for (var _i = 0; _i < array_length(_names); _i++) {
            __colyseus_gm_sim_part(_names[_i], __colyseus_handle(variable_struct_get(_r.source, _names[_i])));
        }
        _r.native = __colyseus_gm_sim_create(_input,
            __colyseus_predict_opt(_o, "smooth_ms", -1),
            __colyseus_predict_opt(_o, "snap", 0),
            __colyseus_predict_opt(_o, "step_ms", 0),
            __colyseus_predict_opt(_o, "sub_steps", 0));
        if (_r.native > 0) {
            _r.world = _r.legacy ? {} : undefined;
            _r.view = {};
            for (var _i = 0; _i < array_length(_names); _i++) {
                var _mirror = __colyseus_gm_sim_part_mirror(_r.native, _names[_i]);
                if (_r.legacy) {
                    variable_struct_set(_r.world, _names[_i], new ColyseusMirror(_mirror));
                } else {
                    var _part = __colyseus_view_part(_mirror);
                    array_push(_r.parts, _part);
                    variable_struct_set(_r.view, _names[_i], _part.view);
                }
            }
        }
    } else {
        _r.native = __colyseus_gm_predict_reconciler(_r.predict,
            __colyseus_handle(_r.source), _input,
            json_stringify({
                fields: __colyseus_predict_csv(__colyseus_predict_opt(_o, "fields", "")),
                smooth_ms: __colyseus_predict_opt(_o, "smooth_ms", -1),
                snap: __colyseus_predict_opt(_o, "snap", 0),
                step_ms: __colyseus_predict_opt(_o, "step_ms", 0),
                sub_steps: __colyseus_predict_opt(_o, "sub_steps", 0),
            }));
        if (_r.native > 0) {
            var _mirror = __colyseus_gm_recon_state(_r.native);
            if (_r.legacy) {
                _r.state = new ColyseusMirror(_mirror);
            } else {
                var _part = __colyseus_view_part(_mirror);
                array_push(_r.parts, _part);
                _r.view = _part.view;
            }
        }
    }
    if (_r.native <= 0) {
        show_debug_message("colyseus_predict_reconciler: native create failed");
        return;
    }
    if (!_r.legacy) {
        _r.cmd_fields = __colyseus_predict_numeric_fields(__colyseus_gm_input_data(_r.input_room));
    }
}

/// @ignore a mirror's plain-struct view: read before each step, changed
/// fields written back after it
function __colyseus_view_part(_handle) {
    var _fields = __colyseus_predict_numeric_fields(_handle);
    return { handle: _handle, fields: _fields, view: {}, seen: array_create(array_length(_fields), 0) };
}

/// @ignore
function __colyseus_view_read(_part) {
    var _h = _part.handle;
    var _names = _part.fields;
    var _view = _part.view;
    for (var _i = 0; _i < array_length(_names); _i++) {
        var _v = __colyseus_gm_mirror_get(_h, _names[_i]);
        _view[$ _names[_i]] = _v;
        _part.seen[_i] = _v;
    }
}

/// @ignore
function __colyseus_view_write(_part) {
    var _h = _part.handle;
    var _names = _part.fields;
    var _view = _part.view;
    for (var _i = 0; _i < array_length(_names); _i++) {
        var _v = _view[$ _names[_i]];
        if (is_numeric(_v) && _v != _part.seen[_i]) __colyseus_gm_mirror_set(_h, _names[_i], _v);
    }
}

/// @ignore dt/dt_ms/sub_* are fixed by the reconciler's config — read once
/// per pump, not per step (a replay burst refreshes the rest per step)
function __colyseus_step_ctx_refresh(_ctx, _first) {
    if (_first) {
        _ctx.dt = __colyseus_gm_step_ctx(0);
        _ctx.dt_ms = __colyseus_gm_step_ctx(1);
        _ctx.sub_steps = __colyseus_gm_step_ctx(3);
        _ctx.sub_dt = __colyseus_gm_step_ctx(4);
        _ctx.sub_dt_ms = __colyseus_gm_step_ctx(5);
    }
    _ctx.tick = __colyseus_gm_step_ctx(2);
    _ctx.is_replay = __colyseus_gm_step_ctx(6) > 0;
    _ctx.reckon_time = __colyseus_gm_step_ctx(7);
    _ctx.lag_comp_active = __colyseus_gm_step_ctx(8) > 0;
}

// =============================================================================
// Step helpers — call these inside a step function
// =============================================================================

/// A value computed once, on the live step, and frozen for that step's
/// replays: an RNG roll, a lag-compensated hit. _compute is a function,
/// called as _compute(_userdata) on the live step only; GML functions can't
/// see the step's locals, so pass them in _userdata. Numbers only. Returns
/// NaN when the live step stored none, and outside a step. _key tells
/// several memos in one step apart.
///   var _vx = colyseus_step_memo("hit", collide, { state: _s, time: _ctx.reckon_time });
function colyseus_step_memo(_key, _compute, _userdata = undefined) {
    var _frozen = __colyseus_gm_step_memo_peek(_key);
    if (!is_nan(_frozen) || __colyseus_gm_step_ctx(6) != 0) return _frozen;
    return __colyseus_gm_step_memo_store(_key, _compute(_userdata));
}

/// An optimistic event born inside the step. Live steps only; replays skip it.
function colyseus_step_predict(_channel, _key) {
    __colyseus_gm_step_predict(__colyseus_predict_ref(_channel), _key);
}

// =============================================================================
// Optimistic events
// =============================================================================

/// An event channel driven by the Predict. _opts: grace_ticks, ttl_ms,
/// cooldown_ms, and the callbacks on_predict(key), on_confirm(key),
/// on_reject(key), on_unpredicted(key). Callbacks run in colyseus_process(),
/// the frame after the fact.
/// @returns {Real} Channel handle, 0 on failure
function colyseus_event_channel_create(_predict, _opts = undefined) {
    var _pid = __colyseus_predict_ref(_predict);
    var _id = __colyseus_gm_events_create(
        global.__colyseus_predict_rooms[_pid],
        __colyseus_predict_opt(_opts, "grace_ticks", 0),
        __colyseus_predict_opt(_opts, "ttl_ms", 0),
        __colyseus_predict_opt(_opts, "cooldown_ms", 0));
    if (_id <= 0) {
        show_debug_message("colyseus_event_channel_create: failed (cap reached?)");
        return 0;
    }
    __colyseus_gm_predict_drive_events(_pid, _id);
    global.__colyseus_predict_channels[_id] = {
        on_predict:     __colyseus_predict_opt(_opts, "on_predict", undefined),
        on_confirm:     __colyseus_predict_opt(_opts, "on_confirm", undefined),
        on_reject:      __colyseus_predict_opt(_opts, "on_reject", undefined),
        on_unpredicted: __colyseus_predict_opt(_opts, "on_unpredicted", undefined),
    };
    global.__colyseus_predict_channel_owner[_id] = _pid;
    return _id;
}

/// Predict an event outside a step (UI-born). In a step, use colyseus_step_predict().
function colyseus_event_channel_predict(_channel, _key) {
    return __colyseus_gm_events_predict(__colyseus_predict_ref(_channel), _key) > 0;
}
function colyseus_event_channel_confirm(_channel, _key = "") {
    return __colyseus_gm_events_confirm(__colyseus_predict_ref(_channel), _key);
}
function colyseus_event_channel_reject(_channel, _key = "") {
    return __colyseus_gm_events_reject(__colyseus_predict_ref(_channel), _key);
}
function colyseus_event_channel_has(_channel, _key = "") {
    return __colyseus_gm_events_has(__colyseus_predict_ref(_channel), _key) > 0;
}
function colyseus_event_channel_pending_count(_channel) {
    return __colyseus_gm_events_pending(__colyseus_predict_ref(_channel));
}
function colyseus_event_channel_clear(_channel) {
    __colyseus_gm_events_clear(__colyseus_predict_ref(_channel));
}
function colyseus_event_channel_free(_channel) {
    var _id = __colyseus_predict_ref(_channel);
    if (_id <= 0) return;
    global.__colyseus_predict_channels[_id] = undefined;
    global.__colyseus_predict_channel_owner[_id] = 0;
    __colyseus_gm_events_free(_id);
}

// =============================================================================
// Predicted spawns
// =============================================================================

/// Locally spawned entities that hand off to the server's copies in
/// _collection. _opts: fields, ttl_ms, owned_field, owned_value,
/// spawn_time_field, step_id + step_params (motion while pending), and
/// on_reject(spawn_id).
/// @returns {Real} Spawns handle, 0 on failure
function colyseus_spawns_create(_predict, _collection, _opts = undefined) {
    var _pid = __colyseus_predict_ref(_predict);
    var _id = __colyseus_gm_spawns_create(global.__colyseus_predict_rooms[_pid], json_stringify({
        ttl_ms: __colyseus_predict_opt(_opts, "ttl_ms", 0),
        fields: __colyseus_predict_csv(__colyseus_predict_opt(_opts, "fields", [])),
        owned_field: __colyseus_predict_opt(_opts, "owned_field", ""),
        owned_value: __colyseus_predict_opt(_opts, "owned_value", ""),
        spawn_time_field: __colyseus_predict_opt(_opts, "spawn_time_field", ""),
        step_id: __colyseus_predict_opt(_opts, "step_id", COLYSEUS_STEP_NONE),
        step_params: __colyseus_predict_opt(_opts, "step_params", ""),
    }));
    if (_id <= 0) {
        show_debug_message("colyseus_spawns_create: failed");
        return 0;
    }
    __colyseus_gm_predict_bind_spawns(_pid, _id, 0, _collection);
    global.__colyseus_predict_spawns[_id] = { on_reject: __colyseus_predict_opt(_opts, "on_reject", undefined) };
    global.__colyseus_predict_spawns_owner[_id] = _pid;
    return _id;
}

/// Spawn a local entity: _values = { x: ..., y: ..., vx: ... }. Returns its
/// spawn id, which stays the same after the server's copy arrives.
function colyseus_spawns_spawn(_spawns, _values) {
    var _id = __colyseus_predict_ref(_spawns);
    var _names = variable_struct_get_names(_values);
    for (var _i = 0; _i < array_length(_names); _i++) {
        __colyseus_gm_spawns_spawn_set(_id, _names[_i], variable_struct_get(_values, _names[_i]));
    }
    return __colyseus_gm_spawns_spawn(_id);
}
function colyseus_spawns_cancel(_spawns, _sid) { __colyseus_gm_spawns_cancel(__colyseus_predict_ref(_spawns), _sid); }
function colyseus_spawns_accept(_spawns, _sid) { __colyseus_gm_spawns_accept(__colyseus_predict_ref(_spawns), _sid); }
function colyseus_spawns_size(_spawns) { return __colyseus_gm_spawns_size(__colyseus_predict_ref(_spawns)); }
function colyseus_spawns_alive(_spawns, _sid) { return __colyseus_gm_spawns_alive(__colyseus_predict_ref(_spawns), _sid) > 0; }

/// Every live entry: [{ id, confirmed, lead_ms, server }].
function colyseus_spawns_entries(_spawns) {
    var _id = __colyseus_predict_ref(_spawns);
    var _out = [];
    var _has = __colyseus_gm_spawns_iter_begin(_id);
    while (_has > 0) {
        array_push(_out, {
            id: __colyseus_gm_spawns_entry_stat(_id, 0),
            confirmed: __colyseus_gm_spawns_entry_stat(_id, 1) > 0,
            lead_ms: __colyseus_gm_spawns_entry_stat(_id, 2),
            server: __colyseus_gm_spawns_entry_stat(_id, 3),
        });
        _has = __colyseus_gm_spawns_iter_next(_id);
    }
    return _out;
}

/// A field of a spawn, read the same way before and after the handoff (NaN when gone).
function colyseus_spawns_value(_spawns, _sid, _field) {
    var _id = __colyseus_predict_ref(_spawns);
    if (__colyseus_gm_spawns_seek(_id, _sid) <= 0) return NaN;
    return __colyseus_gm_spawns_entry_value(_id, _field);
}

function colyseus_spawns_free(_spawns) {
    var _id = __colyseus_predict_ref(_spawns);
    if (_id <= 0) return;
    global.__colyseus_predict_spawns[_id] = undefined;
    global.__colyseus_predict_spawns_owner[_id] = 0;
    __colyseus_gm_spawns_free(_id);
}

// =============================================================================
// Event dispatch — called from colyseus_process() for the predict event types
// =============================================================================

/// @ignore
/// Colyseus.gml calls this by name: the two scripts ship together and are
/// inseparable at compile time (GML has no soft function references).
function __colyseus_predict_dispatch(_evt) {
    if (_evt == COLYSEUS_EVENT_PREDICT_SETTLE) {
        var _ch = global.__colyseus_predict_channels[colyseus_event_get_callback_handle()];
        if (_ch != undefined) {
            var _kind = colyseus_event_get_code();
            var _key = colyseus_event_get_message();
            if (_kind == 0 && _ch.on_predict != undefined) _ch.on_predict(_key);
            else if (_kind == 1 && _ch.on_confirm != undefined) _ch.on_confirm(_key);
            else if (_kind == 2 && _ch.on_reject != undefined) _ch.on_reject(_key);
            else if (_kind == 3 && _ch.on_unpredicted != undefined) _ch.on_unpredicted(_key);
        }
        return true;
    }
    if (_evt == COLYSEUS_EVENT_SPAWN_REJECT) {
        var _sp = global.__colyseus_predict_spawns[colyseus_event_get_callback_handle()];
        if (_sp != undefined && _sp.on_reject != undefined) {
            _sp.on_reject(colyseus_event_get_code());
        }
        return true;
    }
    return false;
}

// =============================================================================
// Constructors — the earlier struct API, kept for existing projects. Each
// method calls the function of the same name above.
// =============================================================================

/// @param {Real} _room_ref
/// @param {Struct} [_opts]  { unreliable, history_size, render_delay }
function ColyseusInput(_room_ref, _opts = undefined) constructor {
    room_ref = _room_ref;
    ok = colyseus_room_input(_room_ref, _opts) != 0;

    static set = function(_field, _value) { return colyseus_input_set(room_ref, _field, _value); };
    static get = function(_field) { return colyseus_input_get(room_ref, _field); };
    static send = function() { return colyseus_input_send(room_ref); };
    static sent_count     = function() { return colyseus_input_sent_count(room_ref); };
    static last_processed = function() { return colyseus_input_last_processed(room_ref); };
    static pending_count  = function() { return colyseus_input_pending_count(room_ref); };
    static epoch          = function() { return colyseus_input_epoch(room_ref); };
    static tick_rate      = function() { return colyseus_input_tick_rate(room_ref); };
    static patch_rate     = function() { return colyseus_input_patch_rate(room_ref); };
    static render_delay   = function() { return colyseus_input_render_delay(room_ref); };
    static set_render_delay = function(_ms) { colyseus_input_set_render_delay(room_ref, _ms); };
    static set_rewind_field = function(_field) { return colyseus_input_set_rewind_field(room_ref, _field); };
    static reset = function() { colyseus_input_reset(room_ref); };
}

/// What colyseus_room_get_clock() returns.
/// @param {Real} _room_ref
function ColyseusClock(_room_ref) constructor {
    room_ref = _room_ref;
    static now          = function() { return colyseus_room_clock_now(room_ref); };
    static server_now   = function() { return colyseus_room_clock_server_now(room_ref); };
    static render_now   = function() { return colyseus_room_clock_render_now(room_ref); };
    static rtt          = function() { return colyseus_room_clock_rtt(room_ref); };
    static smoothed_rtt = function() { return colyseus_room_clock_smoothed_rtt(room_ref); };
    static jitter       = function() { return colyseus_room_clock_jitter(room_ref); };
    static last_server_time = function() { return colyseus_room_clock_last_server_time(room_ref); };
    static patch_interval   = function() { return colyseus_room_clock_patch_interval(room_ref); };
}

/// A bare C schema instance (a reconciler mirror or sim part) exposed to GML.
function ColyseusMirror(_handle) constructor {
    __handle = _handle;
    static get = function(_field) { return __colyseus_gm_mirror_get(__handle, _field); };
    static set = function(_field, _value) { return __colyseus_gm_mirror_set(__handle, _field, _value); };
}

/// The step context the constructors' reconcilers pass. Its fields keep the
/// values of the LAST step run, so `recon.ctx.dt` is fine to read after a
/// tick or send; the memo helpers answer NaN outside a step.
function ColyseusStepCtx() constructor {
    dt = 0; dt_ms = 0; tick = 0; is_replay = false;
    reckon_time = 0; lag_comp_active = false;
    sub_steps = 0; sub_dt = 0; sub_dt_ms = 0;

    /// Frozen value for this seq, or NaN when the live step stored none.
    static memo_peek = function(_key) { return __colyseus_gm_step_memo_peek(_key); };
    /// Live: stores + returns _value. Replay: returns the frozen value.
    static memo_store = function(_key, _value) { return __colyseus_gm_step_memo_store(_key, _value); };
    static predict = function(_channel, _key) { colyseus_step_predict(_channel, _key); };
}

/// The command (input snapshot) of the step being run.
function ColyseusStepCmd() constructor {
    static get = function(_field) { return __colyseus_gm_step_cmd(_field); };
}

/// Created via predict.reconciler(...) / predict.sim(...) — not directly.
/// `id` is the reconciler handle the colyseus_reconciler_* functions take.
function ColyseusReconciler(_predict, _spec) constructor {
    predict = _predict;

    static __adopt = function() {
        var _r = __colyseus_reconciler_record(id);
        ctx = _r != undefined ? _r.ctx : new ColyseusStepCtx();
        cmd = _r != undefined ? _r.cmd : new ColyseusStepCmd();
        state = _r != undefined ? _r.state : undefined;
        world = _r != undefined ? _r.world : undefined;
    };
    // tick() and send() run the steps, so this finds nothing due
    static pump = function() {
        var _r = __colyseus_reconciler_record(id);
        if (_r != undefined) __colyseus_reconciler_pump(_r);
    };
    static value = function(_field) { return colyseus_reconciler_value(id, _field); };
    static pending_count = function() { return colyseus_reconciler_pending_count(id); };
    static last_correction_mag = function() { return colyseus_reconciler_last_correction_mag(id); };
    static reconcile_seq = function() { return colyseus_reconciler_reconcile_seq(id); };
    static drift_ema = function() { return colyseus_reconciler_drift(id).ema; };
    static drift_peak = function() { return colyseus_reconciler_drift(id).peak; };
    static last_correction = function(_field) { return colyseus_reconciler_last_correction(id, _field); };
    static reset = function() { colyseus_reconciler_reset(id); };
    static rebuild = function(_new_truth = undefined) {
        colyseus_reconciler_rebuild(id, _new_truth);
        __adopt();
    };
    static free_native = function() {
        if (id > 0) {
            colyseus_reconciler_free(id);
            id = 0;
        }
    };

    id = __colyseus_reconciler_create(_predict.id,
        __colyseus_predict_opt(_spec, "truth", undefined), _spec, true);
    __adopt();
}

/// Created via predict.define_event(...).
function ColyseusEventChannel(_predict, _opts) constructor {
    predict = _predict;
    on_predict     = __colyseus_predict_opt(_opts, "on_predict", undefined);
    on_confirm     = __colyseus_predict_opt(_opts, "on_confirm", undefined);
    on_reject      = __colyseus_predict_opt(_opts, "on_reject", undefined);
    on_unpredicted = __colyseus_predict_opt(_opts, "on_unpredicted", undefined);
    id = colyseus_event_channel_create(_predict.id, _opts);
    if (id > 0) global.__colyseus_predict_channels[id] = self;   // callbacks reassigned later still fire

    static predict_ui = function(_key) { return colyseus_event_channel_predict(id, _key); };
    static confirm = function(_key = "") { return colyseus_event_channel_confirm(id, _key); };
    static reject  = function(_key = "") { return colyseus_event_channel_reject(id, _key); };
    static has     = function(_key = "") { return colyseus_event_channel_has(id, _key); };
    static pending_count = function() { return colyseus_event_channel_pending_count(id); };
    static clear = function() { colyseus_event_channel_clear(id); };
    static free_native = function() {
        if (id > 0) {
            colyseus_event_channel_free(id);
            id = 0;
        }
    };
}

/// Created via predict.spawns(collection, opts).
function ColyseusSpawns(_predict, _collection, _opts) constructor {
    predict = _predict;
    collection = _collection;
    fields = __colyseus_predict_opt(_opts, "fields", []);
    on_reject = __colyseus_predict_opt(_opts, "on_reject", undefined);
    id = colyseus_spawns_create(_predict.id, _collection, _opts);
    if (id > 0) global.__colyseus_predict_spawns[id] = self;

    static spawn = function(_values) { return colyseus_spawns_spawn(id, _values); };
    static cancel = function(_sid) { colyseus_spawns_cancel(id, _sid); };
    static accept = function(_sid) { colyseus_spawns_accept(id, _sid); };
    static size = function() { return colyseus_spawns_size(id); };
    static alive = function(_sid) { return colyseus_spawns_alive(id, _sid); };
    static entries = function() { return colyseus_spawns_entries(id); };
    static value = function(_sid, _field) { return colyseus_spawns_value(id, _sid, _field); };
    static free_native = function() {
        if (id > 0) {
            colyseus_spawns_free(id);
            id = 0;
        }
    };
}

/// @param {Real} _room_ref
function ColyseusPredict(_room_ref) constructor {
    room_ref = _room_ref;
    id = colyseus_predict_for_room(_room_ref);
    clock = colyseus_room_get_clock(_room_ref);

    static tick = function(_now) { return colyseus_predict_tick(id, _now); };
    static attach = function(_instance, _config) { return colyseus_predict_attach(id, _instance, _config); };
    static attach_all = function(_collection, _config = undefined, _except = "") {
        return colyseus_predict_attach_all(id, _collection, _config, _except);
    };
    static attach_reckon = function(_instance, _fields, _step_id, _params = "",
                                    _smooth_ms = 0, _substep_ms = 0, _snap = 0) {
        return colyseus_predict_attach_reckon(id, _instance, _fields, _step_id, _params,
            _smooth_ms, _substep_ms, _snap);
    };
    static attach_all_reckon = function(_collection, _fields, _step_id, _params = "",
                                        _smooth_ms = 0, _substep_ms = 0, _snap = 0) {
        return colyseus_predict_attach_all_reckon(id, _collection, _fields, _step_id, _params,
            _smooth_ms, _substep_ms, _snap);
    };
    static detach = function(_instance) { colyseus_predict_detach(id, _instance); };
    static value = function(_instance, _field) { return colyseus_predict_value(id, _instance, _field); };
    static value_at = function(_instance, _field, _time) {
        return colyseus_predict_value_at(id, _instance, _field, _time);
    };
    static reconciler = function(_truth, _opts) {
        _opts.truth = _truth;
        return new ColyseusReconciler(self, _opts);
    };
    static sim = function(_opts) { return new ColyseusReconciler(self, _opts); };
    static define_event = function(_opts) { return new ColyseusEventChannel(self, _opts); };
    static spawns = function(_collection, _opts) { return new ColyseusSpawns(self, _collection, _opts); };
    static free_native = function() {
        if (id > 0) {
            colyseus_predict_free(id);
            id = 0;
        }
    };
}
