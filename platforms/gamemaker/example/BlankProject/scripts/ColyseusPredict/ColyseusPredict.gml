// =============================================================================
// Colyseus GML Wrapper — prediction layer
//
// Ergonomic surface over the colyseus_gm_predict_* extension functions:
//   input  = new ColyseusInput(room_ref);
//   predict = new ColyseusPredict(room_ref);
//   recon  = predict.reconciler(player, { fields: ["x","y","vx","vy"],
//              step: function(ctx, s, cmd) { /* mutate s */ } });
//
// Per-Step contract (colyseus_process() already pumps netdelay + reconnect):
//   colyseus_process();
//   var _steps = predict.tick(colyseus_predict_now());
//   repeat (_steps) { input.set("moveX", mx); input.send(); recon.pump(); }
//   recon.pump();   // replay bursts detected by tick
//   draw with predict.value(entity, "x") / recon.value("x")
//
// GameMaker's FFI can never call GML, so the reconciler runs in MANUAL PUMP
// mode: pump() drains due steps and calls YOUR step function between
// pump_next and pump_commit. Dead-reckon steps run C-side (step_id 1 =
// integrate: x/y/vx/vy with optional bounds/friction/maxSpeed params).
// Event-channel settlement and spawn rejections arrive through
// colyseus_process() as queued events, one frame after the fact.
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

global.__colyseus_predict_channels = array_create(17, undefined);  // channel_id → ColyseusEventChannel
global.__colyseus_predict_spawns  = array_create(9, undefined);    // spawns_id → ColyseusSpawns

/// Monotonic ms — the time base predict.tick() paces against.
function colyseus_predict_now() {
    return __colyseus_gm_now();
}

/// @ignore instance argument → native handle (cached shadow struct or raw)
function __colyseus_predict_handle(_x) {
    if (is_struct(_x)) return _x.__handle;
    return _x;
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

// =============================================================================
// Input handle — the room-owned singleton, synthesized from INPUT_REFLECTION
// =============================================================================

/// @param {Real} _room_ref
/// @param {Struct} [_opts]  { unreliable, history_size, render_delay }
function ColyseusInput(_room_ref, _opts = undefined) constructor {
    room_ref = _room_ref;
    ok = __colyseus_gm_input_init(_room_ref,
        __colyseus_predict_opt(_opts, "unreliable", 0) ? 1 : 0,
        __colyseus_predict_opt(_opts, "history_size", 0),
        __colyseus_predict_opt(_opts, "render_delay", 0)) > 0;
    if (!ok) show_debug_message("ColyseusInput: input_init failed (no INPUT_REFLECTION yet? join first)");

    static set = function(_field, _value) { return __colyseus_gm_input_set(room_ref, _field, _value); };
    static get = function(_field) { return __colyseus_gm_input_get(room_ref, _field); };
    /// Sends the staged input; returns the 1-based seq (0 = nothing sent).
    static send = function() { return __colyseus_gm_input_send(room_ref); };
    static sent_count     = function() { return __colyseus_gm_input_stat(room_ref, 0); };
    static last_processed = function() { return __colyseus_gm_input_stat(room_ref, 1); };
    static pending_count  = function() { return __colyseus_gm_input_stat(room_ref, 2); };
    static epoch          = function() { return __colyseus_gm_input_stat(room_ref, 3); };
    static tick_rate      = function() { return __colyseus_gm_input_stat(room_ref, 4); };
    static patch_rate     = function() { return __colyseus_gm_input_stat(room_ref, 5); };
    static render_delay   = function() { return __colyseus_gm_input_stat(room_ref, 7); };
    static set_render_delay = function(_ms) { __colyseus_gm_input_set_render_delay(room_ref, _ms); };
    /// Lag-comp gate: rewind stamping only when this input FIELD is nonzero
    /// (set the field before send). "" clears the gate.
    static set_rewind_field = function(_field) { return __colyseus_gm_input_set_rewind_field(room_ref, _field); };
    static reset = function() { __colyseus_gm_input_reset(room_ref); };
}

// =============================================================================
// Room clock readouts
// =============================================================================

/// @param {Real} _room_ref
function ColyseusClock(_room_ref) constructor {
    room_ref = _room_ref;
    static now          = function() { return __colyseus_gm_now(); };
    static server_now   = function() { return __colyseus_gm_clock_stat(room_ref, 0); };
    static render_now   = function() { return __colyseus_gm_clock_stat(room_ref, 1); };
    static rtt          = function() { return __colyseus_gm_clock_stat(room_ref, 2); };
    static smoothed_rtt = function() { return __colyseus_gm_clock_stat(room_ref, 3); };
    static jitter       = function() { return __colyseus_gm_clock_stat(room_ref, 4); };
    static last_server_time = function() { return __colyseus_gm_clock_stat(room_ref, 5); };
    static patch_interval   = function() { return __colyseus_gm_clock_stat(room_ref, 6); };
}

// =============================================================================
// Netdelay injector (debug latency + the drop button)
// =============================================================================

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
// Mirror + step-context views (what a reconciler step function receives)
// =============================================================================

/// A bare C schema instance (a reconciler mirror or sim part) exposed to GML.
function ColyseusMirror(_handle) constructor {
    __handle = _handle;
    static get = function(_field) { return __colyseus_gm_mirror_get(__handle, _field); };
    static set = function(_field, _value) { return __colyseus_gm_mirror_set(__handle, _field, _value); };
}

/// The per-step context. Plain fields refreshed before each step call; memo
/// helpers freeze values live and replay them frozen (see reconciler.h).
function ColyseusStepCtx() constructor {
    dt = 0; dt_ms = 0; tick = 0; is_replay = false;
    reckon_time = 0; lag_comp_active = false; sub_dt = 0;

    /// dt/dt_ms/sub_dt are fixed by the reconciler's config — read once per
    /// pump, not per step (a replay burst refreshes the rest per step).
    static __refresh_const = function() {
        dt = __colyseus_gm_step_ctx(0);
        dt_ms = __colyseus_gm_step_ctx(1);
        sub_dt = __colyseus_gm_step_ctx(4);
    };
    static __refresh = function() {
        tick = __colyseus_gm_step_ctx(2);
        is_replay = __colyseus_gm_step_ctx(6) > 0;
        reckon_time = __colyseus_gm_step_ctx(7);
        lag_comp_active = __colyseus_gm_step_ctx(8) > 0;
    };
    /// Frozen value for this seq, or NaN when the live step stored none.
    static memo_peek = function(_key) { return __colyseus_gm_step_memo_peek(_key); };
    /// Live: stores + returns _value. Replay: returns the frozen value.
    static memo_store = function(_key, _value) { return __colyseus_gm_step_memo_store(_key, _value); };
    /// Optimistic event born inside the step (live-only; replay-safe in C).
    static predict = function(_channel, _key) { __colyseus_gm_step_predict(_channel.id, _key); };
}

/// The command (input snapshot) of the step being pumped.
function ColyseusStepCmd() constructor {
    static get = function(_field) { return __colyseus_gm_step_cmd(_field); };
}

// =============================================================================
// Reconciler — manual pump over the flat or composite (sim) face
// =============================================================================

/// Created via predict.reconciler(...) / predict.sim(...) — not directly.
function ColyseusReconciler(_predict, _spec) constructor {
    predict = _predict;
    __spec = _spec;              // kept for rebuild() after a reconnect
    id = 0;
    state = undefined;           // ColyseusMirror (flat face)
    world = undefined;           // struct of part name → ColyseusMirror (sim face)
    step_fn = _spec.step;
    ctx = new ColyseusStepCtx();
    cmd = new ColyseusStepCmd();

    static __create_native = function() {
        var _s = __spec;
        if (variable_struct_exists(_s, "world")) {
            __colyseus_gm_sim_begin(predict.id);
            var _names = variable_struct_get_names(_s.world);
            array_sort(_names, true);   // deterministic part order — server-matched
            for (var _i = 0; _i < array_length(_names); _i++) {
                __colyseus_gm_sim_part(_names[_i],
                    __colyseus_predict_handle(variable_struct_get(_s.world, _names[_i])));
            }
            id = __colyseus_gm_sim_create(
                __colyseus_predict_opt(_s, "input", 0),
                __colyseus_predict_opt(_s, "smoothing", -1),
                __colyseus_predict_opt(_s, "snap", 0),
                __colyseus_predict_opt(_s, "step_ms", 0),
                __colyseus_predict_opt(_s, "sub_steps", 0));
            world = {};
            for (var _i = 0; _i < array_length(_names); _i++) {
                variable_struct_set(world, _names[_i],
                    new ColyseusMirror(__colyseus_gm_sim_part_mirror(id, _names[_i])));
            }
        } else {
            id = __colyseus_gm_predict_reconciler(predict.id,
                __colyseus_predict_handle(_s.truth),
                __colyseus_predict_opt(_s, "input", 0),
                json_stringify({
                    fields: __colyseus_predict_csv(__colyseus_predict_opt(_s, "fields", "")),
                    smoothing: __colyseus_predict_opt(_s, "smoothing", -1),
                    snap: __colyseus_predict_opt(_s, "snap", 0),
                    step_ms: __colyseus_predict_opt(_s, "step_ms", 0),
                    sub_steps: __colyseus_predict_opt(_s, "sub_steps", 0),
                }));
            state = new ColyseusMirror(__colyseus_gm_recon_state(id));
        }
        if (id <= 0) show_debug_message("ColyseusReconciler: native create failed");
    };
    __create_native();

    /// Drain every due step (a pending reconcile's replay burst, then the
    /// live catch-up). Call after predict.tick() and after input.send().
    static pump = function() {
        var _first = true;
        while (__colyseus_gm_recon_pump_begin(id) > 0) {
            while (__colyseus_gm_recon_pump_next(id) > 0) {
                if (_first) { ctx.__refresh_const(); _first = false; }
                ctx.__refresh();
                if (world != undefined) step_fn(ctx, world, cmd);
                else step_fn(ctx, state, cmd);
                __colyseus_gm_recon_pump_commit(id);
            }
            __colyseus_gm_recon_pump_end(id);
        }
    };

    /// Rendered value: field name (flat) or "part.field" pose key (sim).
    static value = function(_field) { return __colyseus_gm_recon_value(id, _field); };
    static pending_count = function() { return __colyseus_gm_recon_stat(id, 0); };
    static last_correction_mag = function() { return __colyseus_gm_recon_stat(id, 2); };
    static reconcile_seq = function() { return __colyseus_gm_recon_stat(id, 3); };
    static drift_ema = function() { return __colyseus_gm_recon_stat(id, 4); };
    static drift_peak = function() { return __colyseus_gm_recon_stat(id, 5); };
    static last_correction = function(_field) { return __colyseus_gm_recon_last_correction(id, _field); };
    static reset = function() { __colyseus_gm_recon_reset(id); };

    /// A reconnect resync replaces the decoded truth instance — free the
    /// native reconciler and rebuild it against the re-decoded one.
    static rebuild = function(_new_truth = undefined) {
        __colyseus_gm_recon_free(id);
        if (_new_truth != undefined) {
            if (variable_struct_exists(__spec, "world")) __spec.world = _new_truth;
            else __spec.truth = _new_truth;
        }
        __create_native();
    };

    static free_native = function() {
        if (id > 0) {
            __colyseus_gm_recon_free(id);
            id = 0;
        }
    };
}

// =============================================================================
// Optimistic events
// =============================================================================

/// Created via predict.define_event(...) — settlement callbacks are invoked
/// from colyseus_process() (queued: they land the frame after the fact).
function ColyseusEventChannel(_predict, _opts) constructor {
    predict = _predict;
    on_predict     = __colyseus_predict_opt(_opts, "on_predict", undefined);
    on_confirm     = __colyseus_predict_opt(_opts, "on_confirm", undefined);
    on_reject      = __colyseus_predict_opt(_opts, "on_reject", undefined);
    on_unpredicted = __colyseus_predict_opt(_opts, "on_unpredicted", undefined);
    id = __colyseus_gm_events_create(
        _predict.room_ref,
        __colyseus_predict_opt(_opts, "grace_ticks", 0),
        __colyseus_predict_opt(_opts, "ttl_ms", 0),
        __colyseus_predict_opt(_opts, "cooldown_ms", 0));
    if (id > 0) {
        __colyseus_gm_predict_drive_events(_predict.id, id);
        global.__colyseus_predict_channels[id] = self;
    } else {
        show_debug_message("ColyseusEventChannel: create failed (cap reached?)");
    }

    /// UI-born optimistic prediction (sim-born ones use ctx.predict inside a step).
    static predict_ui = function(_key) { return __colyseus_gm_events_predict(id, _key) > 0; };
    static confirm = function(_key = "") { return __colyseus_gm_events_confirm(id, _key); };
    static reject  = function(_key = "") { return __colyseus_gm_events_reject(id, _key); };
    static has     = function(_key = "") { return __colyseus_gm_events_has(id, _key) > 0; };
    static pending_count = function() { return __colyseus_gm_events_pending(id); };
    static clear = function() { __colyseus_gm_events_clear(id); };
    static free_native = function() {
        if (id > 0) {
            global.__colyseus_predict_channels[id] = undefined;
            __colyseus_gm_events_free(id);
            id = 0;
        }
    };
}

// =============================================================================
// Predicted spawns
// =============================================================================

/// Created via predict.spawns(collection, opts).
function ColyseusSpawns(_predict, _collection, _opts) constructor {
    predict = _predict;
    collection = _collection;
    fields = __colyseus_predict_opt(_opts, "fields", []);
    on_reject = __colyseus_predict_opt(_opts, "on_reject", undefined);
    id = __colyseus_gm_spawns_create(_predict.room_ref, json_stringify({
        ttl_ms: __colyseus_predict_opt(_opts, "ttl_ms", 0),
        fields: __colyseus_predict_csv(fields),
        owned_field: __colyseus_predict_opt(_opts, "owned_field", ""),
        owned_value: __colyseus_predict_opt(_opts, "owned_value", ""),
        spawn_time_field: __colyseus_predict_opt(_opts, "spawn_time_field", ""),
        step_id: __colyseus_predict_opt(_opts, "step_id", COLYSEUS_STEP_NONE),
        step_params: __colyseus_predict_opt(_opts, "step_params", ""),
    }));
    if (id > 0) {
        __colyseus_gm_predict_bind_spawns(_predict.id, id, 0, _collection);
        global.__colyseus_predict_spawns[id] = self;
    } else {
        show_debug_message("ColyseusSpawns: create failed");
    }

    /// Optimistically spawn a local: _values = { x: ..., y: ..., vx: ... }.
    /// Returns the stable spawn id.
    static spawn = function(_values) {
        var _names = variable_struct_get_names(_values);
        for (var _i = 0; _i < array_length(_names); _i++) {
            __colyseus_gm_spawns_spawn_set(id, _names[_i], variable_struct_get(_values, _names[_i]));
        }
        return __colyseus_gm_spawns_spawn(id);
    };
    static cancel = function(_sid) { __colyseus_gm_spawns_cancel(id, _sid); };
    static accept = function(_sid) { __colyseus_gm_spawns_accept(id, _sid); };
    static size = function() { return __colyseus_gm_spawns_size(id); };
    static alive = function(_sid) { return __colyseus_gm_spawns_alive(id, _sid) > 0; };

    /// Every live entry: [{ id, confirmed, lead_ms, server }].
    static entries = function() {
        var _out = [];
        var _has = __colyseus_gm_spawns_iter_begin(id);
        while (_has > 0) {
            array_push(_out, {
                id: __colyseus_gm_spawns_entry_stat(id, 0),
                confirmed: __colyseus_gm_spawns_entry_stat(id, 1) > 0,
                lead_ms: __colyseus_gm_spawns_entry_stat(id, 2),
                server: __colyseus_gm_spawns_entry_stat(id, 3),
            });
            _has = __colyseus_gm_spawns_iter_next(id);
        }
        return _out;
    };
    /// Field read spanning the pending→confirmed handoff.
    static value = function(_sid, _field) {
        if (__colyseus_gm_spawns_seek(id, _sid) <= 0) return NaN;
        return __colyseus_gm_spawns_entry_value(id, _field);
    };
    static free_native = function() {
        if (id > 0) {
            global.__colyseus_predict_spawns[id] = undefined;
            __colyseus_gm_spawns_free(id);
            id = 0;
        }
    };
}

// =============================================================================
// Predict — the app-facing controller
// =============================================================================

/// @param {Real} _room_ref
function ColyseusPredict(_room_ref) constructor {
    room_ref = _room_ref;
    id = __colyseus_gm_predict_create(_room_ref);
    if (id <= 0) show_debug_message("ColyseusPredict: create failed");
    clock = new ColyseusClock(_room_ref);

    /// Advance the whole prediction stack; returns the fixed input steps due
    /// this frame (send exactly that many inputs).
    static tick = function(_now) { return __colyseus_gm_predict_tick(id, _now); };

    /// attach(instance, { x: COLYSEUS_PREDICT_DAMPED, y: { mode:..., delay:100 } })
    static attach = function(_instance, _config) {
        return __colyseus_gm_predict_attach(id,
            __colyseus_predict_handle(_instance), json_stringify(_config));
    };
    /// Track every entry of a collection, present and future. _except = own key.
    static attach_all = function(_collection, _config = undefined, _except = "") {
        var _spec = { collection: _collection, except: _except };
        if (_config != undefined) _spec.config = _config;
        return __colyseus_gm_predict_attach_all(id, 0, json_stringify(_spec));
    };
    /// Dead-reckon an instance through a built-in C step.
    static attach_reckon = function(_instance, _fields, _step_id, _params = "",
                                    _smoothing = 0, _substep_ms = 0, _snap = 0) {
        return __colyseus_gm_predict_attach_reckon(id,
            __colyseus_predict_handle(_instance), json_stringify({
                fields: __colyseus_predict_csv(_fields),
                step_id: _step_id, step_params: _params,
                smoothing: _smoothing, substep_ms: _substep_ms, snap: _snap,
            }));
    };
    static attach_all_reckon = function(_collection, _fields, _step_id, _params = "",
                                        _smoothing = 0, _substep_ms = 0, _snap = 0) {
        return __colyseus_gm_predict_attach_all_reckon(id, 0, json_stringify({
            collection: _collection,
            fields: __colyseus_predict_csv(_fields),
            step_id: _step_id, step_params: _params,
            smoothing: _smoothing, substep_ms: _substep_ms, snap: _snap,
        }));
    };
    static detach = function(_instance) {
        __colyseus_gm_predict_detach(id, __colyseus_predict_handle(_instance));
    };

    /// One read idiom: smoothed/reckoned/reconciled value of a tracked field,
    /// raw decoded fallback when untracked, NaN for unknown fields.
    static value = function(_instance, _field) {
        return __colyseus_gm_predict_value(id, __colyseus_predict_handle(_instance), _field);
    };
    static value_at = function(_instance, _field, _time) {
        return __colyseus_gm_predict_value_at(id, __colyseus_predict_handle(_instance), _field, _time);
    };

    /// Flat rollback: { truth-instance via arg, fields, step, smoothing, snap }.
    static reconciler = function(_truth, _opts) {
        _opts.truth = _truth;
        return new ColyseusReconciler(self, _opts);
    };
    /// Composite rollback: { world: { name: instance, ... }, step, ... }.
    static sim = function(_opts) {
        return new ColyseusReconciler(self, _opts);
    };
    static define_event = function(_opts) { return new ColyseusEventChannel(self, _opts); };
    static spawns = function(_collection, _opts) { return new ColyseusSpawns(self, _collection, _opts); };

    static free_native = function() {
        if (id > 0) {
            __colyseus_gm_predict_free(id);
            id = 0;
        }
    };
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
