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
    @cInclude("colyseus/schema/input_encoder.h");
    @cInclude("schema/recon_state.h");
    @cInclude("schema/accel_input.h");
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
