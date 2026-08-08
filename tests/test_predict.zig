const std = @import("std");
const testing = std.testing;

// ============================================================================
// Phase 4 — Predict layer (Reconciler stage).
//
// Scenarios mirror colyseus-0.18 PORTING/generate-predict-fixtures.cts
// (self-verified against the JS Reconciler). Contract:
// PORTING/sdk-ports-predict-layer.md.
// ============================================================================

const c = @cImport({
    @cInclude("colyseus/room_clock.h");
    @cInclude("colyseus/input_handle.h");
    @cInclude("colyseus/predict/drift.h");
    @cInclude("colyseus/predict/reconciler.h");
    @cInclude("colyseus/predict/predict.h");
    @cInclude("colyseus/predict/sim_reconciler.h");
    @cInclude("colyseus/schema/input_encoder.h");
    @cInclude("colyseus/schema/decoder.h");
    @cInclude("colyseus/schema/callbacks.h");
    @cInclude("colyseus/schema/dynamic_schema.h");
    @cInclude("schema/recon_state.h");
    @cInclude("schema/passive_ent.h");
    @cInclude("schema/reckon_ball.h");
    @cInclude("schema/accel_input.h");
    @cInclude("schema/sim_paddle.h");
    @cInclude("schema/sim_puck.h");
});

var NOW: f64 = 0;
fn scriptedNow() callconv(.c) f64 {
    return NOW;
}

fn stubSend(data: [*c]const u8, length: usize, userdata: ?*anyopaque) callconv(.c) void {
    _ = data;
    _ = length;
    _ = userdata;
}
fn stubIsOpen(userdata: ?*anyopaque) callconv(.c) bool {
    _ = userdata;
    return true;
}
fn stubGetClock(userdata: ?*anyopaque) callconv(.c) ?*c.colyseus_room_clock_t {
    _ = userdata;
    return null;
}

const Ctx = struct {
    input_instance: *c.accel_input_t,
    handle: *c.colyseus_input_handle_t,
    truth: *c.recon_state_t,
    recon: *c.colyseus_reconciler_t,
};

// step shared with the "server": vx += ax·dt; x += vx·dt
fn accelStep(ctx: [*c]const c.colyseus_step_ctx_t, state: ?*c.colyseus_schema_t, command: ?*const c.colyseus_schema_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const s: *c.recon_state_t = @ptrCast(@alignCast(state.?));
    const cmd: *const c.accel_input_t = @ptrCast(@alignCast(command.?));
    s.vx += cmd.ax * ctx.*.dt;
    s.x += s.vx * ctx.*.dt;
}

fn makeCtx(smoothing: f64) Ctx {
    c.colyseus_room_clock_now_provider = scriptedNow;
    const input_instance = c.accel_input_create().?;
    input_instance.*.__base.__vtable = &c.accel_input_vtable;
    const encoder = c.colyseus_input_encoder_create(
        @ptrCast(input_instance), &c.accel_input_vtable, false, 0).?;
    var options = std.mem.zeroes(c.colyseus_input_options_t);
    const handle = c.colyseus_input_handle_create(
        @ptrCast(input_instance), &c.accel_input_vtable, encoder,
        false, false, &options, 0, 0, 0,
        stubSend, stubIsOpen, stubGetClock, null).?;

    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;

    var ropts = std.mem.zeroes(c.colyseus_reconciler_options_t);
    ropts.smoothing = smoothing;
    ropts.step_ms = 50;
    const recon = c.colyseus_reconciler_create(
        @ptrCast(truth), &c.recon_state_vtable, handle, null, accelStep, &ropts).?;

    return .{ .input_instance = input_instance, .handle = handle, .truth = truth, .recon = recon };
}

fn destroyCtx(ctx: Ctx) void {
    c.colyseus_reconciler_free(ctx.recon);
    c.colyseus_input_handle_free(ctx.handle);
    c.recon_state_vtable.destroy.?(@ptrCast(ctx.truth));
}

fn serverStep(truth: *c.recon_state_t, ax: f64) void {
    truth.vx += ax * 0.05;
    truth.x += truth.vx * 0.05;
}

test "reconciler_core" {
    const ctx = makeCtx(0); // hard corrections — exp()-free trajectories
    defer destroyCtx(ctx);
    const state: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(ctx.recon)));

    NOW = 0;
    c.colyseus_reconciler_tick(ctx.recon, NOW);

    // fixture: 6 sends at 50ms cadence, server acks trailing by 2 inputs
    const expected_x = [_]f64{ 0.025, 0.07500000000000001, 0.15000000000000002, 0.21250000000000002, 0.2625, 0.30000000000000004 };
    const expected_vx = [_]f64{ 0.5, 1, 1.5, 1.25, 1, 0.75 };
    var sent_ax: [8]f64 = undefined;
    var i: usize = 1;
    while (i <= 6) : (i += 1) {
        NOW = @as(f64, @floatFromInt(i)) * 50;
        c.colyseus_reconciler_tick(ctx.recon, NOW);
        const ax: f64 = if (i <= 3) 10 else -5;
        sent_ax[i] = ax;
        ctx.input_instance.*.ax = ax;
        _ = c.colyseus_input_handle_send(ctx.handle);
        if (i >= 3) { // server processed input i-2
            serverStep(ctx.truth, sent_ax[i - 2]);
            _ = c.colyseus_input_handle_ack_input(ctx.handle, @intCast(i - 2));
            c.colyseus_reconciler_tick(ctx.recon, NOW);
        }
        try testing.expectEqual(expected_x[i - 1], state.x);
        try testing.expectEqual(expected_vx[i - 1], state.vx);
        try testing.expectEqual(@as(f64, 0), c.colyseus_reconciler_last_correction_mag(ctx.recon));
    }
    try testing.expectEqual(@as(c_int, 4), c.colyseus_reconciler_reconcile_seq(ctx.recon));

    // divergent truth: server-side teleport the client didn't predict
    serverStep(ctx.truth, sent_ax[4]);
    ctx.truth.x += 100;
    _ = c.colyseus_input_handle_ack_input(ctx.handle, 5);
    NOW = 350;
    c.colyseus_reconciler_tick(ctx.recon, NOW);
    try testing.expectEqual(@as(f64, 100.3), state.x);
    try testing.expectEqual(@as(f64, 0.75), state.vx);
    try testing.expectEqual(@as(f64, -100), c.colyseus_reconciler_last_correction(ctx.recon, "x"));
    try testing.expectEqual(@as(f64, 100), c.colyseus_reconciler_last_correction_mag(ctx.recon));

    // value() with smoothing 0: equals state at clamped alpha
    try testing.expectEqual(@as(f64, 100.3), c.colyseus_reconciler_value(ctx.recon, "x"));
}

// ============================================================================
// Dynamic-vtable twin of reconciler_core: same step math, same fixture, but
// the TRUTH and MIRROR are dynamic schemas (hash storage — the GDScript /
// reflection path). Every number must match the static fixture exactly; the
// storage model must be invisible to the rollback engine.
// ============================================================================

fn dynNum(s: *c.colyseus_dynamic_schema_t, index: c_int) *c.colyseus_dynamic_value_t {
    return c.colyseus_dynamic_schema_ensure(s, index, c.COLYSEUS_FIELD_NUMBER);
}

// step shared with the "server", against dynamic storage: vx += ax·dt; x += vx·dt
fn accelStepDyn(ctx: [*c]const c.colyseus_step_ctx_t, state: ?*c.colyseus_schema_t, command: ?*const c.colyseus_schema_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const s: *c.colyseus_dynamic_schema_t = @ptrCast(@alignCast(state.?));
    const cmd: *const c.accel_input_t = @ptrCast(@alignCast(command.?));
    const vx = dynNum(s, 1);
    const x = dynNum(s, 0);
    vx.*.data.num += cmd.ax * ctx.*.dt;
    x.*.data.num += vx.*.data.num * ctx.*.dt;
}

fn serverStepDyn(truth: *c.colyseus_dynamic_schema_t, ax: f64) void {
    const vx = dynNum(truth, 1);
    const x = dynNum(truth, 0);
    vx.*.data.num += ax * 0.05;
    x.*.data.num += vx.*.data.num * 0.05;
}

test "reconciler_dynamic_truth" {
    c.colyseus_room_clock_now_provider = scriptedNow;

    // hand-built dynamic vtable: { x: number@0, vx: number@1 }
    const dvt = c.colyseus_dynamic_vtable_create("recon_state_dyn").?;
    defer c.colyseus_dynamic_vtable_free(dvt);
    c.colyseus_dynamic_vtable_add_field(dvt, c.colyseus_dynamic_field_create(0, "x", c.COLYSEUS_FIELD_NUMBER, "number"));
    c.colyseus_dynamic_vtable_add_field(dvt, c.colyseus_dynamic_field_create(1, "vx", c.COLYSEUS_FIELD_NUMBER, "number"));

    // static input schema over a dynamic state — the GDExtension's exact mix
    const input_instance = c.accel_input_create().?;
    input_instance.*.__base.__vtable = &c.accel_input_vtable;
    const encoder = c.colyseus_input_encoder_create(
        @ptrCast(input_instance), &c.accel_input_vtable, false, 0).?;
    var options = std.mem.zeroes(c.colyseus_input_options_t);
    const handle = c.colyseus_input_handle_create(
        @ptrCast(input_instance), &c.accel_input_vtable, encoder,
        false, false, &options, 0, 0, 0,
        stubSend, stubIsOpen, stubGetClock, null).?;
    defer c.colyseus_input_handle_free(handle);

    const truth = c.colyseus_dynamic_schema_create(dvt).?;
    defer c.colyseus_dynamic_schema_free(truth);

    var ropts = std.mem.zeroes(c.colyseus_reconciler_options_t);
    ropts.smoothing = 0;
    ropts.step_ms = 50;
    const recon = c.colyseus_reconciler_create(
        @ptrCast(truth), &dvt.*.base, handle, null, accelStepDyn, &ropts).?;
    defer c.colyseus_reconciler_free(recon);

    const mirror: *c.colyseus_dynamic_schema_t =
        @ptrCast(@alignCast(c.colyseus_reconciler_state(recon)));

    NOW = 0;
    c.colyseus_reconciler_tick(recon, NOW);

    // the reconciler_core fixture, verbatim
    const expected_x = [_]f64{ 0.025, 0.07500000000000001, 0.15000000000000002, 0.21250000000000002, 0.2625, 0.30000000000000004 };
    const expected_vx = [_]f64{ 0.5, 1, 1.5, 1.25, 1, 0.75 };
    var sent_ax: [8]f64 = undefined;
    var i: usize = 1;
    while (i <= 6) : (i += 1) {
        NOW = @as(f64, @floatFromInt(i)) * 50;
        c.colyseus_reconciler_tick(recon, NOW);
        const ax: f64 = if (i <= 3) 10 else -5;
        sent_ax[i] = ax;
        input_instance.*.ax = ax;
        _ = c.colyseus_input_handle_send(handle);
        if (i >= 3) {
            serverStepDyn(truth, sent_ax[i - 2]);
            _ = c.colyseus_input_handle_ack_input(handle, @intCast(i - 2));
            c.colyseus_reconciler_tick(recon, NOW);
        }
        try testing.expectEqual(expected_x[i - 1], dynNum(mirror, 0).*.data.num);
        try testing.expectEqual(expected_vx[i - 1], dynNum(mirror, 1).*.data.num);
        try testing.expectEqual(@as(f64, 0), c.colyseus_reconciler_last_correction_mag(recon));
    }
    try testing.expectEqual(@as(c_int, 4), c.colyseus_reconciler_reconcile_seq(recon));

    // divergent truth: server-side teleport the client didn't predict
    serverStepDyn(truth, sent_ax[4]);
    dynNum(truth, 0).*.data.num += 100;
    _ = c.colyseus_input_handle_ack_input(handle, 5);
    NOW = 350;
    c.colyseus_reconciler_tick(recon, NOW);
    try testing.expectEqual(@as(f64, 100.3), dynNum(mirror, 0).*.data.num);
    try testing.expectEqual(@as(f64, 0.75), dynNum(mirror, 1).*.data.num);
    try testing.expectEqual(@as(f64, -100), c.colyseus_reconciler_last_correction(recon, "x"));
    try testing.expectEqual(@as(f64, 100), c.colyseus_reconciler_last_correction_mag(recon));
    try testing.expectEqual(@as(f64, 100.3), c.colyseus_reconciler_value(recon, "x"));

    // a bare mirror must have NO userdata shadow
    try testing.expect(mirror.*.userdata == null);
}

// memo compute counter for the next scenario
var compute_runs: i32 = 0;
var memo_dx: f64 = 0;
fn memoCompute(userdata: ?*anyopaque) callconv(.c) f64 {
    _ = userdata;
    compute_runs += 1;
    return if (memo_dx >= 2) 5 else std.math.nan(f64);
}

fn memoStep(ctx: [*c]const c.colyseus_step_ctx_t, state: ?*c.colyseus_schema_t, command: ?*const c.colyseus_schema_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const s: *c.recon_state_t = @ptrCast(@alignCast(state.?));
    const cmd: *const c.accel_input_t = @ptrCast(@alignCast(command.?));
    memo_dx = cmd.ax; // stage for the compute (C closures — module scope)
    const bonus = c.colyseus_step_memo(ctx, "", memoCompute, null);
    s.x += cmd.ax + (if (std.math.isNan(bonus)) 0 else bonus);
}

test "reconciler_memo_epoch" {
    c.colyseus_room_clock_now_provider = scriptedNow;
    compute_runs = 0;

    const input_instance = c.accel_input_create().?;
    input_instance.*.__base.__vtable = &c.accel_input_vtable;
    const encoder = c.colyseus_input_encoder_create(
        @ptrCast(input_instance), &c.accel_input_vtable, false, 0).?;
    var options = std.mem.zeroes(c.colyseus_input_options_t);
    const handle = c.colyseus_input_handle_create(
        @ptrCast(input_instance), &c.accel_input_vtable, encoder,
        false, false, &options, 0, 0, 0,
        stubSend, stubIsOpen, stubGetClock, null).?;
    defer c.colyseus_input_handle_free(handle);

    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));

    var ropts = std.mem.zeroes(c.colyseus_reconciler_options_t);
    ropts.smoothing = 0;
    ropts.step_ms = 50;
    const fields = [_][*c]const u8{"x"};
    ropts.fields = @ptrCast(&fields);
    ropts.field_count = 1;
    const recon = c.colyseus_reconciler_create(
        @ptrCast(truth), &c.recon_state_vtable, handle, null, memoStep, &ropts).?;
    defer c.colyseus_reconciler_free(recon);
    const state: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(recon)));

    NOW = 0;
    c.colyseus_reconciler_tick(recon, NOW);
    input_instance.*.ax = 1;
    _ = c.colyseus_input_handle_send(handle);
    input_instance.*.ax = 2; // memoizes 5
    _ = c.colyseus_input_handle_send(handle);
    input_instance.*.ax = 1;
    _ = c.colyseus_input_handle_send(handle);
    try testing.expectEqual(@as(f64, 9), state.x); // 1 + 7 + 1
    try testing.expectEqual(@as(i32, 3), compute_runs);

    // ack 1 with matching truth → adopt + replay of 2..3; memo frozen
    truth.*.x = 1;
    _ = c.colyseus_input_handle_ack_input(handle, 1);
    NOW = 50;
    c.colyseus_reconciler_tick(recon, NOW);
    try testing.expectEqual(@as(f64, 9), state.x);
    try testing.expectEqual(@as(i32, 3), compute_runs); // replay did NOT re-run

    // epoch follow: handle reset → controller self-resets from truth
    truth.*.x = 42;
    c.colyseus_input_handle_reset(handle);
    NOW = 100;
    c.colyseus_reconciler_tick(recon, NOW);
    try testing.expectEqual(@as(f64, 42), state.x);
    try testing.expectEqual(@as(c_int, 0), c.colyseus_reconciler_pending_count(recon));
}

test "drift_math" {
    var d = c.colyseus_drift_t{ .ema = 0, .peak = 0 };
    c.colyseus_drift_update(&d, 10);
    try testing.expectEqual(@as(f64, 1), d.ema);
    try testing.expectEqual(@as(f64, 10), d.peak);
    c.colyseus_drift_update(&d, 0);
    try testing.expectEqual(@as(f64, 0.9), d.ema);
    try testing.expectEqual(@as(f64, 9), d.peak);
    try testing.expectEqual(@as(c_uint, c.COLYSEUS_DRIFT_JITTER), c.colyseus_drift_classify(&d, 5));
    try testing.expectEqual(@as(c_uint, c.COLYSEUS_DRIFT_DIVERGING), c.colyseus_drift_classify(&d, 0.5));
    d.ema = 0;
    d.peak = 0;
    try testing.expectEqual(@as(c_uint, c.COLYSEUS_DRIFT_MATCHED), c.colyseus_drift_classify(&d, 0));
}

// ─── passive smoothing (fixture scenario D) ─────────────────────────────────

fn decodeBytes(decoder: *c.colyseus_decoder_t, bytes: []const u8) void {
    var it = c.colyseus_iterator_t{ .offset = 0 };
    c.colyseus_decoder_decode(decoder, bytes.ptr, bytes.len, &it);
}

test "passive_smoothing" {
    c.colyseus_room_clock_now_provider = scriptedNow;

    const decoder = c.colyseus_decoder_create(&c.passive_ent_vtable).?;
    defer c.colyseus_decoder_free(decoder);
    const callbacks = c.colyseus_callbacks_create(decoder).?;
    defer c.colyseus_callbacks_free(callbacks);
    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);
    c.colyseus_room_clock_set_patch_interval(clock, 50);

    const p = c.colyseus_predict_create(callbacks, clock).?;
    defer c.colyseus_predict_free(p);
    const ent: *c.colyseus_schema_t = @ptrCast(@alignCast(c.colyseus_decoder_get_state(decoder)));

    var lerp_opts = std.mem.zeroes(c.colyseus_predict_field_options_t);
    lerp_opts.mode = c.COLYSEUS_PREDICT_LERP;
    var damped_opts = std.mem.zeroes(c.colyseus_predict_field_options_t);
    damped_opts.mode = c.COLYSEUS_PREDICT_DAMPED;
    var ext_opts = std.mem.zeroes(c.colyseus_predict_field_options_t);
    ext_opts.mode = c.COLYSEUS_PREDICT_EXTRAPOLATE;
    ext_opts.damping = -1; // raw projection (no output EMA)
    var raw_opts = std.mem.zeroes(c.colyseus_predict_field_options_t);
    raw_opts.mode = c.COLYSEUS_PREDICT_RAW;
    var angle_opts = std.mem.zeroes(c.colyseus_predict_field_options_t);
    angle_opts.mode = c.COLYSEUS_PREDICT_LERP;
    angle_opts.angle = true;
    // One attach, five modes — the per-field config the (fields, options) pair
    // could not express, exercised through the PUBLIC surface.
    const cfg = [_]c.colyseus_attach_field_t{
        .{ .field = "a", .opts = &lerp_opts },
        .{ .field = "b", .opts = &damped_opts },
        .{ .field = "c", .opts = &ext_opts },
        .{ .field = "d", .opts = &raw_opts },
        .{ .field = "yaw", .opts = &angle_opts },
    };
    _ = c.colyseus_predict_attach(p, ent, &cfg, cfg.len);

    // patches on the server-time axis: sample(sNow, -1) at NOW=sNow pins
    // offset 0 → serverNow == NOW, lastServerTime == sNow (fixture axis)
    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1);
    decodeBytes(decoder, &[_]u8{ 128, 10, 129, 10, 130, 10, 131, 10, 132, 3 });
    NOW = 1050;
    c.colyseus_room_clock_sample(clock, 1050, -1);
    decodeBytes(decoder, &[_]u8{ 128, 20, 129, 20, 130, 20, 131, 20, 132, 253 }); // yaw -3 crosses ±π
    NOW = 1100;
    c.colyseus_room_clock_sample(clock, 1100, -1);
    decodeBytes(decoder, &[_]u8{ 128, 30, 129, 30, 130, 30, 131, 30 });

    // fixture reads @1150: lerp(a)=20, raw(d)=30, extrapolate(c)=40
    NOW = 1150;
    _ = c.colyseus_predict_tick(p, NOW);
    try testing.expectEqual(@as(f64, 20), c.colyseus_predict_value(p, ent, "a"));
    try testing.expectEqual(@as(f64, 30), c.colyseus_predict_value(p, ent, "d"));
    try testing.expectEqual(@as(f64, 40), c.colyseus_predict_value(p, ent, "c"));
    // angle: unwrapped fold keeps the lerp on the ±π seam
    const yaw_mid = c.colyseus_predict_value(p, ent, "yaw");
    try testing.expect(@abs(yaw_mid) > 3.0);

    NOW = 1175;
    _ = c.colyseus_predict_tick(p, NOW);
    try testing.expectEqual(@as(f64, 25), c.colyseus_predict_value(p, ent, "a"));
    try testing.expectEqual(@as(f64, 45), c.colyseus_predict_value(p, ent, "c"));

    // idle-resume gap collapse: a idle 1100→1400, resumes at 40; synthetic
    // held sample (1350, 30) → 31 / 35 / 40 at the fixture read instants
    NOW = 1400;
    c.colyseus_room_clock_sample(clock, 1400, -1);
    decodeBytes(decoder, &[_]u8{ 128, 40 });
    NOW = 1455;
    _ = c.colyseus_predict_tick(p, NOW);
    try testing.expectEqual(@as(f64, 31), c.colyseus_predict_value(p, ent, "a"));
    NOW = 1475;
    _ = c.colyseus_predict_tick(p, NOW);
    try testing.expectEqual(@as(f64, 35), c.colyseus_predict_value(p, ent, "a"));
    NOW = 1500;
    _ = c.colyseus_predict_tick(p, NOW);
    try testing.expectEqual(@as(f64, 40), c.colyseus_predict_value(p, ent, "a"));
}

// ─── reckon + valueAt (fixture scenario E) ──────────────────────────────────

fn ballStep(state: ?*c.colyseus_schema_t, dt: f64, elapsed_ms: f64, userdata: ?*anyopaque) callconv(.c) void {
    _ = elapsed_ms;
    _ = userdata;
    const s: *c.reckon_ball_t = @ptrCast(@alignCast(state.?));
    s.x += s.vx * dt;
}

test "reckon_value_at" {
    c.colyseus_room_clock_now_provider = scriptedNow;

    const decoder = c.colyseus_decoder_create(&c.reckon_ball_vtable).?;
    defer c.colyseus_decoder_free(decoder);
    const callbacks = c.colyseus_callbacks_create(decoder).?;
    defer c.colyseus_callbacks_free(callbacks);
    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);

    const p = c.colyseus_predict_create(callbacks, clock).?;
    defer c.colyseus_predict_free(p);
    const ball: *c.colyseus_schema_t = @ptrCast(@alignCast(c.colyseus_decoder_get_state(decoder)));

    const fields = [_][*c]const u8{"x"};
    // smoothing 0 → raw projection (exp()-free); substep 10
    try testing.expectEqual(@as(c_int, 0), c.colyseus_predict_attach_reckon(
        p, ball, &c.reckon_ball_vtable, @ptrCast(&fields), 1, ballStep, 0, 10, 0, null));

    // patch: x=100, vx=50 stamped sNow=1000 (offset 0 → serverNow == NOW)
    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1);
    decodeBytes(decoder, &[_]u8{ 128, 100, 129, 50 });

    // fixture: 1000→100, 1050→102.5, 1100→105, 1200→110
    const expect_x = [_][2]f64{ .{ 1000, 100 }, .{ 1050, 102.5 }, .{ 1100, 105 }, .{ 1200, 110 } };
    for (expect_x) |pair| {
        NOW = pair[0];
        _ = c.colyseus_predict_tick(p, NOW);
        try testing.expectEqual(pair[1], c.colyseus_predict_value(p, ball, "x"));
    }

    // valueAt: arbitrary instant raw; past clamps to the snapshot
    try testing.expectEqual(@as(f64, 107.5), c.colyseus_predict_value_at(p, ball, "x", 1150));
    try testing.expectEqual(@as(f64, 100), c.colyseus_predict_value_at(p, ball, "x", 900));
}

// ─── event channel + spawns (fixture scenarios F/G) ─────────────────────────

const evc = @cImport({
    @cInclude("colyseus/predict/events.h");
    @cInclude("colyseus/predict/spawns.h");
});

var event_log_buf: [16][32]u8 = undefined;
var event_log_len: [16]usize = undefined;
var event_log_count: usize = 0;

fn logEvent(prefix: []const u8, payload: ?*anyopaque) void {
    if (event_log_count >= event_log_buf.len) return;
    const name: [*c]const u8 = @ptrCast(payload orelse return);
    const span = std.mem.span(name);
    var buf = &event_log_buf[event_log_count];
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + span.len], span);
    event_log_len[event_log_count] = prefix.len + span.len;
    event_log_count += 1;
}

fn evPredict(payload: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    logEvent("P:", payload);
}
fn evConfirm(payload: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    logEvent("C:", payload);
}
fn evReject(payload: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    logEvent("R:", payload);
}
var unpredicted_count: i32 = 0;
fn evUnpredicted(key: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = key;
    _ = userdata;
    unpredicted_count += 1;
}

fn expectLog(index: usize, expected: []const u8) !void {
    try testing.expect(index < event_log_count);
    try testing.expectEqualStrings(expected, event_log_buf[index][0..event_log_len[index]]);
}

test "event_channel_settlement" {
    c.colyseus_room_clock_now_provider = scriptedNow;
    event_log_count = 0;
    unpredicted_count = 0;

    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);
    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1); // offset 0 → serverNow == NOW

    var opts = std.mem.zeroes(evc.colyseus_event_channel_options_t);
    opts.on_predict = evPredict;
    opts.on_confirm = evConfirm;
    opts.on_reject = evReject;
    opts.on_unpredicted = evUnpredicted;
    opts.grace_ticks = 3;
    const chan = evc.colyseus_event_channel_create(&opts, @ptrCast(clock)).?;
    defer evc.colyseus_event_channel_free(chan);

    // UI-born predict + confirm; unpredicted confirm
    const goal_a: [*c]const u8 = "goal-a";
    try testing.expect(evc.colyseus_event_channel_predict(chan, "goal-a", @constCast(goal_a)));
    try testing.expectEqual(@as(c_int, 1), evc.colyseus_event_channel_pending_count(chan));
    try testing.expectEqual(@as(c_int, 1), evc.colyseus_event_channel_confirm(chan, "goal-a"));
    try testing.expectEqual(@as(c_int, 0), evc.colyseus_event_channel_confirm(chan, "goal-b"));
    try testing.expectEqual(@as(i32, 1), unpredicted_count);

    // pending dedupe
    const kill_1: [*c]const u8 = "kill-1";
    try testing.expect(evc.colyseus_event_channel_predict(chan, "kill-1", @constCast(kill_1)));
    try testing.expect(!evc.colyseus_event_channel_predict(chan, "kill-1", @constCast(kill_1)));
    try testing.expectEqual(@as(c_int, 1), evc.colyseus_event_channel_pending_count(chan));

    // UI-born TTL: rtt 0 → 600ms on the serverNow axis
    NOW = 1601;
    evc.colyseus_event_channel_prune(chan);
    try testing.expectEqual(@as(c_int, 0), evc.colyseus_event_channel_pending_count(chan));

    try expectLog(0, "P:goal-a");
    try expectLog(1, "C:goal-a");
    try expectLog(2, "P:kill-1");
    try expectLog(3, "R:kill-1");
}

var spawn_rejected_id: i32 = -1;
fn spawnReject(local: ?*anyopaque, id: c_int, userdata: ?*anyopaque) callconv(.c) void {
    _ = local;
    _ = userdata;
    spawn_rejected_id = id;
}
fn spawnOwned(server: ?*c.colyseus_schema_t, userdata: ?*anyopaque) callconv(.c) bool {
    _ = userdata;
    // recon_state doubles as the "rocket": vx > 0 marks "mine"
    const rocket: *c.recon_state_t = @ptrCast(@alignCast(server.?));
    return rocket.vx > 0;
}
fn spawnTime(server: ?*c.colyseus_schema_t, userdata: ?*anyopaque) callconv(.c) f64 {
    _ = userdata;
    const rocket: *c.recon_state_t = @ptrCast(@alignCast(server.?));
    return rocket.x; // x carries bornMs in this fixture
}
fn spawnStep(local: ?*anyopaque, dt: f64, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const v: *f64 = @ptrCast(@alignCast(local.?));
    v.* += 10 * dt;
}

test "spawns_correlation" {
    c.colyseus_room_clock_now_provider = scriptedNow;
    spawn_rejected_id = -1;

    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);
    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1);

    var opts = std.mem.zeroes(evc.colyseus_spawns_options_t);
    opts.owned = @ptrCast(&spawnOwned);
    opts.spawn_time = @ptrCast(&spawnTime);
    opts.has_spawn_time = true;
    opts.step = spawnStep;
    opts.on_reject = spawnReject;
    const store = evc.colyseus_spawns_create(&opts, @ptrCast(clock)).?;
    defer evc.colyseus_spawns_free(store);

    var local_x: f64 = 0;
    const id1 = evc.colyseus_spawns_spawn(store, &local_x);
    try testing.expectEqual(@as(c_int, 1), id1);

    // pending local steps on the serverNow axis: 1000 → 1100 = dt 0.1 → +1
    evc.colyseus_spawns_tick(store, 0);
    NOW = 1100;
    evc.colyseus_spawns_tick(store, 0);
    try testing.expectEqual(@as(f64, 1), local_x);

    // authoritative arrival: fifo match + lead = bornMs(=x) − at = 1080 − 1000
    const server1 = c.recon_state_create().?;
    defer c.recon_state_vtable.destroy.?(@ptrCast(server1));
    server1.*.x = 1080; // bornMs
    server1.*.vx = 1;   // mine
    evc.colyseus_spawns_handle_add(store, @ptrCast(server1));
    const e1 = evc.colyseus_spawns_entry_for(store, @ptrCast(server1)).?;
    try testing.expectEqual(@as(c_int, 1), e1.*.id);
    try testing.expect(e1.*.confirmed);
    try testing.expectEqual(@as(f64, 80), e1.*.lead_ms);

    // foreign entity: never consumes a prediction
    const server2 = c.recon_state_create().?;
    defer c.recon_state_vtable.destroy.?(@ptrCast(server2));
    server2.*.x = 1090;
    server2.*.vx = -1; // not mine
    evc.colyseus_spawns_handle_add(store, @ptrCast(server2));
    const e2 = evc.colyseus_spawns_entry_for(store, @ptrCast(server2)).?;
    try testing.expectEqual(@as(f64, 0), e2.*.lead_ms);
    try testing.expectEqual(@as(?*anyopaque, null), e2.*.local);

    // mispredict prune: unmatched pending at serverNow 1100, TTL 600
    var local2_x: f64 = 0;
    const id2 = evc.colyseus_spawns_spawn(store, &local2_x);
    NOW = 1701;
    evc.colyseus_spawns_prune(store);
    try testing.expectEqual(id2, spawn_rejected_id);
    try testing.expect(!evc.colyseus_spawns_alive(store, id2));

    // remove drops the confirmed entry
    evc.colyseus_spawns_handle_remove(store, @ptrCast(server1));
    try testing.expect(!evc.colyseus_spawns_alive(store, 1));
    try testing.expectEqual(@as(c_int, 1), evc.colyseus_spawns_size(store));
}

// ============================================================================
// SimReconciler — the composite face (fixtures scenario C: sim_reconciler_bound).
// ============================================================================


// step shared with the "server": paddle.vx = cmd; paddle.x += vx·dt; puck += 1
fn simStep(
    ctx: [*c]const c.colyseus_step_ctx_t,
    world: ?*c.colyseus_sim_world_t,
    command: ?*const c.colyseus_schema_t,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = userdata;
    const paddle: *c.sim_paddle_t = @ptrCast(@alignCast(c.colyseus_sim_world_part(world, "paddle").?));
    const puck: *c.sim_puck_t = @ptrCast(@alignCast(c.colyseus_sim_world_part(world, "puck").?));
    const cmd: *const c.accel_input_t = @ptrCast(@alignCast(command.?));
    paddle.vx = cmd.ax;
    paddle.x += paddle.vx * ctx.*.dt;
    puck.px += 1;
}

test "sim_reconciler_bound" {
    c.colyseus_room_clock_now_provider = scriptedNow;

    const input_instance = c.accel_input_create().?;
    input_instance.*.__base.__vtable = &c.accel_input_vtable;
    const encoder = c.colyseus_input_encoder_create(
        @ptrCast(input_instance), &c.accel_input_vtable, false, 0).?;
    var in_opts = std.mem.zeroes(c.colyseus_input_options_t);
    const handle = c.colyseus_input_handle_create(
        @ptrCast(input_instance), &c.accel_input_vtable, encoder,
        false, false, &in_opts, 0, 0, 0,
        stubSend, stubIsOpen, stubGetClock, null).?;
    defer c.colyseus_input_handle_free(handle);

    // Decoded truth sources (the JS fixture gets these from a real
    // encode/decode round trip; here they are set directly).
    const paddle_truth = c.sim_paddle_create().?;
    paddle_truth.*.__base.__vtable = &c.sim_paddle_vtable;
    const puck_truth = c.sim_puck_create().?;
    puck_truth.*.__base.__vtable = &c.sim_puck_vtable;
    defer c.sim_paddle_vtable.destroy.?(@ptrCast(paddle_truth));
    defer c.sim_puck_vtable.destroy.?(@ptrCast(puck_truth));

    const parts = [_]c.colyseus_sim_part_t{
        .{ .name = "paddle", .source = @ptrCast(paddle_truth), .vtable = &c.sim_paddle_vtable, .@"opaque" = null },
        .{ .name = "puck", .source = @ptrCast(puck_truth), .vtable = &c.sim_puck_vtable, .@"opaque" = null },
    };
    var opts = std.mem.zeroes(c.colyseus_sim_reconciler_options_t);
    opts.parts = &parts;
    opts.part_count = 2;
    opts.smoothing = 0;
    opts.step_ms = 50;
    const recon = c.colyseus_sim_reconciler_create(handle, null, simStep, &opts).?;
    defer c.colyseus_reconciler_free(recon);

    const world = c.colyseus_sim_reconciler_world(recon).?;
    const paddle: *c.sim_paddle_t = @ptrCast(@alignCast(c.colyseus_sim_world_part(world, "paddle").?));
    const puck: *c.sim_puck_t = @ptrCast(@alignCast(c.colyseus_sim_world_part(world, "puck").?));

    // The bound mirrors REPLACED the sources in the world — mutating the world
    // must never touch decoded state.
    try testing.expect(@intFromPtr(paddle) != @intFromPtr(paddle_truth));
    try testing.expect(@intFromPtr(puck) != @intFromPtr(puck_truth));

    NOW = 0;
    c.colyseus_reconciler_tick(recon, NOW);

    input_instance.*.ax = 2;
    _ = c.colyseus_input_handle_send(handle);
    _ = c.colyseus_input_handle_send(handle);

    try testing.expectEqual(@as(f64, 0.2), paddle.x);
    try testing.expectEqual(@as(f64, 2), puck.px);
    // renderAlpha is 0 here, so value() reads the previous step's pose.
    try testing.expectEqual(@as(f64, 0.1), c.colyseus_reconciler_value(recon, "paddle.x"));
    try testing.expectEqual(@as(f64, 1), c.colyseus_reconciler_value(recon, "puck.px"));

    // Server truth: applied input 1. The auto-`number` wire rounds through f32,
    // and SimReconciler has NO wire-precision skip — it always adopts — so the
    // correction carries that float noise. Reference behaviour; ports reproduce it.
    paddle_truth.*.x = @as(f64, @as(f32, 0.1));
    paddle_truth.*.vx = 2;
    puck_truth.*.px = 1;
    _ = c.colyseus_input_handle_ack_input(handle, 1);
    NOW = 50;
    c.colyseus_reconciler_tick(recon, NOW);

    const mag = c.colyseus_reconciler_last_correction_mag(recon);
    try testing.expect(mag > 0); // it really did adopt + replay
    try testing.expect(mag < 1e-6);
    // Input 2 replayed on top of the adopted truth.
    try testing.expectEqual(@as(f64, 2), puck.px);
    try testing.expectEqual(@as(c_int, 1), c.colyseus_reconciler_reconcile_seq(recon));
}

// ============================================================================
// Manual pump — the pull-driven face for hosts without C→script callbacks
// (GameMaker). An auto reconciler and a manual one observe the SAME input
// handle and truth; the manual one is drained through pump_begin/next/commit/
// end with the step applied by the host loop. Every number must be
// bit-identical at every checkpoint, including the deferred-decay ordering.
// ============================================================================

fn pumpDrainAccel(recon: *c.colyseus_reconciler_t) void {
    while (c.colyseus_reconciler_pump_begin(recon) > 0) {
        while (true) {
            var ctx_ptr: [*c]const c.colyseus_step_ctx_t = null;
            const cmd = c.colyseus_reconciler_pump_next(recon, &ctx_ptr);
            if (cmd == null) break;
            const s: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(recon)));
            const cmd_t: *const c.accel_input_t = @ptrCast(@alignCast(cmd.?));
            s.vx += cmd_t.ax * ctx_ptr.*.dt;
            s.x += s.vx * ctx_ptr.*.dt;
            c.colyseus_reconciler_pump_commit(recon);
        }
        c.colyseus_reconciler_pump_end(recon);
    }
}

test "reconciler_pull_equals_callback" {
    c.colyseus_room_clock_now_provider = scriptedNow;
    const input_instance = c.accel_input_create().?;
    input_instance.*.__base.__vtable = &c.accel_input_vtable;
    const encoder = c.colyseus_input_encoder_create(
        @ptrCast(input_instance), &c.accel_input_vtable, false, 0).?;
    var in_opts = std.mem.zeroes(c.colyseus_input_options_t);
    const handle = c.colyseus_input_handle_create(
        @ptrCast(input_instance), &c.accel_input_vtable, encoder,
        false, false, &in_opts, 0, 0, 0,
        stubSend, stubIsOpen, stubGetClock, null).?;
    defer c.colyseus_input_handle_free(handle);

    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));

    var ropts = std.mem.zeroes(c.colyseus_reconciler_options_t);
    ropts.smoothing = 15; // exercise the decay path, not just hard snaps
    ropts.step_ms = 50;
    const auto = c.colyseus_reconciler_create(
        @ptrCast(truth), &c.recon_state_vtable, handle, null, accelStep, &ropts).?;
    defer c.colyseus_reconciler_free(auto);
    ropts.manual_step = true;
    const manual = c.colyseus_reconciler_create(
        @ptrCast(truth), &c.recon_state_vtable, handle, null, null, &ropts).?;
    defer c.colyseus_reconciler_free(manual);

    const s_auto: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(auto)));
    const s_manual: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(manual)));

    NOW = 0;
    c.colyseus_reconciler_tick(auto, NOW);
    c.colyseus_reconciler_tick(manual, NOW);
    pumpDrainAccel(manual);

    // the reconciler_core cadence: 6 sends at 50ms, acks trailing by 2
    var sent_ax: [8]f64 = undefined;
    var i: usize = 1;
    while (i <= 6) : (i += 1) {
        NOW = @as(f64, @floatFromInt(i)) * 50;
        c.colyseus_reconciler_tick(auto, NOW);
        c.colyseus_reconciler_tick(manual, NOW);
        pumpDrainAccel(manual);
        const ax: f64 = if (i <= 3) 10 else -5;
        sent_ax[i] = ax;
        input_instance.*.ax = ax;
        _ = c.colyseus_input_handle_send(handle); // auto steps eagerly here
        pumpDrainAccel(manual);                   // manual pumps the live step
        if (i >= 3) {
            serverStep(truth, sent_ax[i - 2]);
            _ = c.colyseus_input_handle_ack_input(handle, @intCast(i - 2));
            c.colyseus_reconciler_tick(auto, NOW);
            c.colyseus_reconciler_tick(manual, NOW);
            pumpDrainAccel(manual);
        }
        try testing.expectEqual(s_auto.x, s_manual.x);
        try testing.expectEqual(s_auto.vx, s_manual.vx);
        try testing.expectEqual(
            c.colyseus_reconciler_value(auto, "x"),
            c.colyseus_reconciler_value(manual, "x"));
        try testing.expectEqual(
            c.colyseus_reconciler_last_correction_mag(auto),
            c.colyseus_reconciler_last_correction_mag(manual));
    }
    try testing.expectEqual(
        c.colyseus_reconciler_reconcile_seq(auto),
        c.colyseus_reconciler_reconcile_seq(manual));

    // divergence + an ack tick that ALSO advances time: the auto path
    // reconciles then decays inside one tick; the manual path must defer the
    // decay to pump_end to keep the rebase-then-decay order — bit-identical.
    serverStep(truth, sent_ax[4]);
    truth.*.x += 100;
    _ = c.colyseus_input_handle_ack_input(handle, 5);
    NOW = 316; // +16ms: dt > 0 on the reconciling tick
    c.colyseus_reconciler_tick(auto, NOW);
    c.colyseus_reconciler_tick(manual, NOW);
    pumpDrainAccel(manual);
    try testing.expectEqual(s_auto.x, s_manual.x);
    try testing.expectEqual(
        c.colyseus_reconciler_value(auto, "x"),
        c.colyseus_reconciler_value(manual, "x"));
    try testing.expectEqual(
        c.colyseus_reconciler_last_correction(auto, "x"),
        c.colyseus_reconciler_last_correction(manual, "x"));

    // the correction offsets must now decay identically frame by frame
    var f: usize = 0;
    while (f < 20) : (f += 1) {
        NOW += 16;
        c.colyseus_reconciler_tick(auto, NOW);
        c.colyseus_reconciler_tick(manual, NOW);
        pumpDrainAccel(manual);
        try testing.expectEqual(
            c.colyseus_reconciler_value(auto, "x"),
            c.colyseus_reconciler_value(manual, "x"));
    }
}

// Like pumpDrainAccel, but tallies how the pump labeled each served step.
fn pumpDrainAccelTally(recon: *c.colyseus_reconciler_t, live: *u32, replayed: *u32) void {
    while (c.colyseus_reconciler_pump_begin(recon) > 0) {
        while (true) {
            var ctx_ptr: [*c]const c.colyseus_step_ctx_t = null;
            const cmd = c.colyseus_reconciler_pump_next(recon, &ctx_ptr);
            if (cmd == null) break;
            if (ctx_ptr.*.is_replay) replayed.* += 1 else live.* += 1;
            const s: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(recon)));
            const cmd_t: *const c.accel_input_t = @ptrCast(@alignCast(cmd.?));
            s.vx += cmd_t.ax * ctx_ptr.*.dt;
            s.x += s.vx * ctx_ptr.*.dt;
            c.colyseus_reconciler_pump_commit(recon);
        }
        c.colyseus_reconciler_pump_end(recon);
    }
}

// The single-drain cadence: tick → send → ONE drain per frame, so an ack and
// a fresh send land in the same drain. The fresh input must be served in the
// LIVE phase (auto steps it live at send()); labeling it a replay skips its
// memo/prev/render bookkeeping and settles against the wrong pose.
test "reconciler_pump_single_drain_cadence" {
    c.colyseus_room_clock_now_provider = scriptedNow;
    const input_instance = c.accel_input_create().?;
    input_instance.*.__base.__vtable = &c.accel_input_vtable;
    const encoder = c.colyseus_input_encoder_create(
        @ptrCast(input_instance), &c.accel_input_vtable, false, 0).?;
    var in_opts = std.mem.zeroes(c.colyseus_input_options_t);
    const handle = c.colyseus_input_handle_create(
        @ptrCast(input_instance), &c.accel_input_vtable, encoder,
        false, false, &in_opts, 0, 0, 0,
        stubSend, stubIsOpen, stubGetClock, null).?;
    defer c.colyseus_input_handle_free(handle);

    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));

    var ropts = std.mem.zeroes(c.colyseus_reconciler_options_t);
    ropts.smoothing = 15;
    ropts.step_ms = 50;
    const auto = c.colyseus_reconciler_create(
        @ptrCast(truth), &c.recon_state_vtable, handle, null, accelStep, &ropts).?;
    defer c.colyseus_reconciler_free(auto);
    ropts.manual_step = true;
    const manual = c.colyseus_reconciler_create(
        @ptrCast(truth), &c.recon_state_vtable, handle, null, null, &ropts).?;
    defer c.colyseus_reconciler_free(manual);

    const s_auto: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(auto)));
    const s_manual: *c.recon_state_t = @ptrCast(@alignCast(c.colyseus_reconciler_state(manual)));

    var live: u32 = 0;
    var replayed: u32 = 0;
    var sent_ax: [10]f64 = undefined;
    NOW = 0;
    c.colyseus_reconciler_tick(auto, NOW);
    c.colyseus_reconciler_tick(manual, NOW);
    pumpDrainAccelTally(manual, &live, &replayed);

    var i: usize = 1;
    while (i <= 8) : (i += 1) {
        NOW = @as(f64, @floatFromInt(i)) * 50;
        // ack BEFORE the tick so tick and send share one drain
        if (i >= 3) {
            serverStep(truth, sent_ax[i - 2]);
            _ = c.colyseus_input_handle_ack_input(handle, @intCast(i - 2));
        }
        c.colyseus_reconciler_tick(auto, NOW);
        c.colyseus_reconciler_tick(manual, NOW);
        const ax: f64 = if (i <= 4) 10 else -5;
        sent_ax[i] = ax;
        input_instance.*.ax = ax;
        const live_before = live;
        _ = c.colyseus_input_handle_send(handle); // auto live-steps here
        pumpDrainAccelTally(manual, &live, &replayed); // ONE drain: replay burst + live
        // the input sent this frame was served live, never as a replay
        try testing.expectEqual(live_before + 1, live);
        try testing.expectEqual(s_auto.x, s_manual.x);
        try testing.expectEqual(s_auto.vx, s_manual.vx);
        try testing.expectEqual(
            c.colyseus_reconciler_value(auto, "x"),
            c.colyseus_reconciler_value(manual, "x"));
        try testing.expectEqual(
            c.colyseus_reconciler_last_correction_mag(auto),
            c.colyseus_reconciler_last_correction_mag(manual));
    }
    try testing.expectEqual(
        c.colyseus_reconciler_reconcile_seq(auto),
        c.colyseus_reconciler_reconcile_seq(manual));
    try testing.expect(replayed > 0); // the reconcile bursts really replayed
}

fn pumpDrainSim(recon: *c.colyseus_reconciler_t) void {
    const world = c.colyseus_sim_reconciler_world(recon).?;
    while (c.colyseus_reconciler_pump_begin(recon) > 0) {
        while (true) {
            var ctx_ptr: [*c]const c.colyseus_step_ctx_t = null;
            const cmd = c.colyseus_reconciler_pump_next(recon, &ctx_ptr);
            if (cmd == null) break;
            const paddle: *c.sim_paddle_t = @ptrCast(@alignCast(c.colyseus_sim_world_part(world, "paddle").?));
            const puck: *c.sim_puck_t = @ptrCast(@alignCast(c.colyseus_sim_world_part(world, "puck").?));
            const cmd_t: *const c.accel_input_t = @ptrCast(@alignCast(cmd.?));
            paddle.vx = cmd_t.ax;
            paddle.x += paddle.vx * ctx_ptr.*.dt;
            puck.px += 1;
            c.colyseus_reconciler_pump_commit(recon);
        }
        c.colyseus_reconciler_pump_end(recon);
    }
}

test "sim_reconciler_pull_equals_callback" {
    c.colyseus_room_clock_now_provider = scriptedNow;
    const input_instance = c.accel_input_create().?;
    input_instance.*.__base.__vtable = &c.accel_input_vtable;
    const encoder = c.colyseus_input_encoder_create(
        @ptrCast(input_instance), &c.accel_input_vtable, false, 0).?;
    var in_opts = std.mem.zeroes(c.colyseus_input_options_t);
    const handle = c.colyseus_input_handle_create(
        @ptrCast(input_instance), &c.accel_input_vtable, encoder,
        false, false, &in_opts, 0, 0, 0,
        stubSend, stubIsOpen, stubGetClock, null).?;
    defer c.colyseus_input_handle_free(handle);

    const paddle_truth = c.sim_paddle_create().?;
    paddle_truth.*.__base.__vtable = &c.sim_paddle_vtable;
    const puck_truth = c.sim_puck_create().?;
    puck_truth.*.__base.__vtable = &c.sim_puck_vtable;
    defer c.sim_paddle_vtable.destroy.?(@ptrCast(paddle_truth));
    defer c.sim_puck_vtable.destroy.?(@ptrCast(puck_truth));

    const parts = [_]c.colyseus_sim_part_t{
        .{ .name = "paddle", .source = @ptrCast(paddle_truth), .vtable = &c.sim_paddle_vtable, .@"opaque" = null },
        .{ .name = "puck", .source = @ptrCast(puck_truth), .vtable = &c.sim_puck_vtable, .@"opaque" = null },
    };
    var opts = std.mem.zeroes(c.colyseus_sim_reconciler_options_t);
    opts.parts = &parts;
    opts.part_count = 2;
    opts.smoothing = 0;
    opts.step_ms = 50;
    const auto = c.colyseus_sim_reconciler_create(handle, null, simStep, &opts).?;
    defer c.colyseus_reconciler_free(auto);
    opts.manual_step = true;
    const manual = c.colyseus_sim_reconciler_create(handle, null, null, &opts).?;
    defer c.colyseus_reconciler_free(manual);

    NOW = 0;
    c.colyseus_reconciler_tick(auto, NOW);
    c.colyseus_reconciler_tick(manual, NOW);
    pumpDrainSim(manual);

    input_instance.*.ax = 2;
    _ = c.colyseus_input_handle_send(handle);
    _ = c.colyseus_input_handle_send(handle);
    pumpDrainSim(manual);

    try testing.expectEqual(
        c.colyseus_reconciler_value(auto, "paddle.x"),
        c.colyseus_reconciler_value(manual, "paddle.x"));
    try testing.expectEqual(
        c.colyseus_reconciler_value(auto, "puck.px"),
        c.colyseus_reconciler_value(manual, "puck.px"));

    // scenario C's adopt+replay (f32 wire noise correction) through the pump
    paddle_truth.*.x = @as(f64, @as(f32, 0.1));
    paddle_truth.*.vx = 2;
    puck_truth.*.px = 1;
    _ = c.colyseus_input_handle_ack_input(handle, 1);
    NOW = 50;
    c.colyseus_reconciler_tick(auto, NOW);
    c.colyseus_reconciler_tick(manual, NOW);
    pumpDrainSim(manual);

    try testing.expectEqual(
        c.colyseus_reconciler_last_correction_mag(auto),
        c.colyseus_reconciler_last_correction_mag(manual));
    try testing.expect(c.colyseus_reconciler_last_correction_mag(manual) > 0);
    try testing.expect(c.colyseus_reconciler_last_correction_mag(manual) < 1e-6);
    try testing.expectEqual(
        c.colyseus_reconciler_value(auto, "puck.px"),
        c.colyseus_reconciler_value(manual, "puck.px"));
    try testing.expectEqual(
        c.colyseus_reconciler_reconcile_seq(auto),
        c.colyseus_reconciler_reconcile_seq(manual));
}

test "predict_tick_paces_input" {
    // tick() returns the fixed input steps due this frame — the pacing source
    // an app sends one input per. Mirrors Predictor.tick's accumulator.
    c.colyseus_room_clock_now_provider = scriptedNow;
    const ctx = makeCtx(0);
    defer destroyCtx(ctx);

    const p = c.colyseus_predict_create(null, null).?;
    defer c.colyseus_predict_free(p);

    var ropts = std.mem.zeroes(c.colyseus_reconciler_options_t);
    ropts.smoothing = 0;
    ropts.step_ms = 50;
    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));
    // Born from the Predict: driven by its tick, and it donates the fixed step.
    const recon = c.colyseus_predict_reconciler(
        p, @ptrCast(truth), &c.recon_state_vtable, ctx.handle, accelStep, &ropts).?;

    // First tick has no previous frame: no elapsed time, no steps.
    try testing.expectEqual(@as(c_int, 0), c.colyseus_predict_tick(p, 0));
    try testing.expectEqual(@as(c_int, 0), c.colyseus_predict_tick(p, 20));  // 20ms < 50
    try testing.expectEqual(@as(c_int, 1), c.colyseus_predict_tick(p, 60));  // 60ms -> 1, 10 left
    try testing.expectEqual(@as(c_int, 0), c.colyseus_predict_tick(p, 90));  // 40ms -> 0, 40 left
    try testing.expectEqual(@as(c_int, 3), c.colyseus_predict_tick(p, 200)); // 150ms -> 3, 0 left
    // A hitch emits a bounded count and drops the backlog rather than bursting.
    try testing.expectEqual(@as(c_int, 5), c.colyseus_predict_tick(p, 5000));
    try testing.expectEqual(@as(c_int, 0), c.colyseus_predict_tick(p, 5000));

    // Freeing a driven child deregisters it — a later tick must not touch it.
    c.colyseus_reconciler_free(recon);
    _ = c.colyseus_predict_tick(p, 5100);
}

test "value_of_unknown_field_is_nan" {
    // A typo'd field name must never read as a plausible 0.
    const ctx = makeCtx(0);
    defer destroyCtx(ctx);
    try testing.expect(std.math.isNan(c.colyseus_reconciler_value(ctx.recon, "nope")));
    try testing.expect(!std.math.isNan(c.colyseus_reconciler_value(ctx.recon, "x")));
}
