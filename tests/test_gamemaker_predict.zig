// Bridge tests for the GameMaker prediction layer (platforms/gamemaker/src/
// gamemaker_predict.c + gamemaker_export.c, compiled into this test exe).
//
// Every interaction crosses the bridge exactly as GML would: doubles and
// strings only, mirrors mutated via colyseus_gm_mirror_set, commands read via
// colyseus_gm_step_cmd, replay driven through the manual pump, settlement
// consumed from the polled event queue. The scenarios transpose the
// test_predict.zig fixtures — every number must match them.
//
// The bridge has file-scope state (event queue, registries) shared across
// tests in this process: each test drains the queue up front and frees every
// handle it creates.

const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/input_handle.h");
    @cInclude("colyseus/room_clock.h");
    @cInclude("colyseus/predict/predict.h");
    @cInclude("colyseus/predict/reconciler.h");
    @cInclude("colyseus/schema/dynamic_schema.h");
    @cInclude("colyseus/schema/decoder.h");
    @cInclude("colyseus/schema/callbacks.h");
    @cInclude("schema/recon_state.h");
    @cInclude("schema/accel_input.h");
    @cInclude("schema/passive_ent.h");
    @cInclude("schema/reckon_ball.h");
    @cInclude("schema/sim_paddle.h");
    @cInclude("schema/sim_puck.h");
});

// ── bridge exports (no public header — the .yy is the contract) ─────────
extern fn colyseus_gm_predict_abi_version() f64;
extern fn colyseus_gm_now() f64;
extern fn colyseus_gm_poll_event() f64;
extern fn colyseus_gm_event_get_code() f64;
extern fn colyseus_gm_event_get_message() [*c]const u8;
extern fn colyseus_gm_event_get_callback_handle() f64;
extern fn colyseus_gm_input_set(input_h: f64, field: [*c]const u8, value: f64) f64;
extern fn colyseus_gm_input_get(input_h: f64, field: [*c]const u8) f64;
extern fn colyseus_gm_input_send(input_h: f64) f64;
extern fn colyseus_gm_input_stat(input_h: f64, which: f64) f64;
extern fn colyseus_gm_input_reset(input_h: f64) void;
extern fn colyseus_gm_predict_create_with(callbacks_ptr: f64, clock_ptr: f64) f64;
extern fn colyseus_gm_predict_free(predict_id: f64) void;
extern fn colyseus_gm_predict_tick(predict_id: f64, now: f64) f64;
extern fn colyseus_gm_predict_attach(predict_id: f64, instance: f64, config_json: [*c]const u8) f64;
extern fn colyseus_gm_predict_attach_reckon(predict_id: f64, instance: f64, spec_json: [*c]const u8) f64;
extern fn colyseus_gm_predict_value(predict_id: f64, instance: f64, field: [*c]const u8) f64;
extern fn colyseus_gm_predict_value_at(predict_id: f64, instance: f64, field: [*c]const u8, time: f64) f64;
extern fn colyseus_gm_predict_reconciler(predict_id: f64, truth_instance: f64, input_h: f64, spec_json: [*c]const u8) f64;
extern fn colyseus_gm_sim_begin(predict_id: f64) f64;
extern fn colyseus_gm_sim_part(name: [*c]const u8, instance: f64) f64;
extern fn colyseus_gm_sim_create(input_h: f64, smoothing: f64, snap: f64, step_ms: f64, sub_steps: f64) f64;
extern fn colyseus_gm_sim_part_mirror(recon_id: f64, name: [*c]const u8) f64;
extern fn colyseus_gm_recon_free(recon_id: f64) void;
extern fn colyseus_gm_recon_pump_begin(recon_id: f64) f64;
extern fn colyseus_gm_recon_pump_next(recon_id: f64) f64;
extern fn colyseus_gm_recon_pump_commit(recon_id: f64) void;
extern fn colyseus_gm_recon_pump_end(recon_id: f64) void;
extern fn colyseus_gm_step_ctx(which: f64) f64;
extern fn colyseus_gm_step_cmd(field: [*c]const u8) f64;
extern fn colyseus_gm_recon_value(recon_id: f64, field: [*c]const u8) f64;
extern fn colyseus_gm_recon_state(recon_id: f64) f64;
extern fn colyseus_gm_recon_stat(recon_id: f64, which: f64) f64;
extern fn colyseus_gm_recon_last_correction(recon_id: f64, field: [*c]const u8) f64;
extern fn colyseus_gm_mirror_set(instance: f64, field: [*c]const u8, value: f64) f64;
extern fn colyseus_gm_mirror_get(instance: f64, field: [*c]const u8) f64;
extern fn colyseus_gm_step_memo_peek(key: [*c]const u8) f64;
extern fn colyseus_gm_step_memo_store(key: [*c]const u8, value: f64) f64;
extern fn colyseus_gm_events_create(clock_h: f64, grace_ticks: f64, ttl_ms: f64, cooldown_ms: f64) f64;
extern fn colyseus_gm_events_free(channel_id: f64) void;
extern fn colyseus_gm_predict_drive_events(predict_id: f64, channel_id: f64) void;
extern fn colyseus_gm_events_predict(channel_id: f64, key: [*c]const u8) f64;
extern fn colyseus_gm_events_confirm(channel_id: f64, key: [*c]const u8) f64;
extern fn colyseus_gm_events_pending(channel_id: f64) f64;
extern fn colyseus_gm_spawns_create(clock_h: f64, spec_json: [*c]const u8) f64;
extern fn colyseus_gm_spawns_free(spawns_id: f64) void;
extern fn colyseus_gm_spawns_spawn_set(spawns_id: f64, field: [*c]const u8, value: f64) f64;
extern fn colyseus_gm_spawns_spawn(spawns_id: f64) f64;
extern fn colyseus_gm_spawns_size(spawns_id: f64) f64;
extern fn colyseus_gm_spawns_alive(spawns_id: f64, id: f64) f64;
extern fn colyseus_gm_spawns_handle_add(spawns_id: f64, server_instance: f64) void;
extern fn colyseus_gm_spawns_handle_remove(spawns_id: f64, server_instance: f64) void;
extern fn colyseus_gm_spawns_tick(spawns_id: f64, now: f64) void;
extern fn colyseus_gm_spawns_iter_begin(spawns_id: f64) f64;
extern fn colyseus_gm_spawns_iter_next(spawns_id: f64) f64;
extern fn colyseus_gm_spawns_entry_stat(spawns_id: f64, which: f64) f64;
extern fn colyseus_gm_spawns_entry_value(spawns_id: f64, field: [*c]const u8) f64;
extern fn colyseus_gm_spawns_seek(spawns_id: f64, id: f64) f64;

// GM event type codes mirrored from gamemaker_internal.h
const GM_EVENT_PREDICT_SETTLE: f64 = 19;
const GM_EVENT_SPAWN_REJECT: f64 = 20;

// ── harness ─────────────────────────────────────────────────────────────

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

fn h(ptr: anytype) f64 {
    return @floatFromInt(@intFromPtr(ptr));
}

/// Drain the bridge's shared event queue — every test's prologue.
fn gmDrain() void {
    while (colyseus_gm_poll_event() != 0) {}
}

const InputRig = struct {
    input_instance: *c.accel_input_t,
    handle: *c.colyseus_input_handle_t,
};

fn makeInput() InputRig {
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
    return .{ .input_instance = input_instance, .handle = handle };
}

/// The GML step for the accel fixture, run through bridge calls only:
/// vx += cmd.ax * ctx.dt; x += vx * ctx.dt — plus the pump loop protocol.
fn gmPumpAccel(recon_id: f64) void {
    while (colyseus_gm_recon_pump_begin(recon_id) > 0) {
        while (colyseus_gm_recon_pump_next(recon_id) != 0) {
            const dt = colyseus_gm_step_ctx(0);
            const ax = colyseus_gm_step_cmd("ax");
            const mirror = colyseus_gm_recon_state(recon_id);
            const vx = colyseus_gm_mirror_get(mirror, "vx") + ax * dt;
            _ = colyseus_gm_mirror_set(mirror, "vx", vx);
            _ = colyseus_gm_mirror_set(mirror, "x",
                colyseus_gm_mirror_get(mirror, "x") + vx * dt);
            colyseus_gm_recon_pump_commit(recon_id);
        }
        colyseus_gm_recon_pump_end(recon_id);
    }
}

fn serverStep(truth: *c.recon_state_t, ax: f64) void {
    truth.vx += ax * 0.05;
    truth.x += truth.vx * 0.05;
}

// ── 1. the reconciler_core fixture through the bridge ───────────────────

test "gm_reconciler_core" {
    gmDrain();
    const rig = makeInput();
    defer c.colyseus_input_handle_free(rig.handle);

    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));

    const pid = colyseus_gm_predict_create_with(0, 0);
    try testing.expect(pid > 0);
    defer colyseus_gm_predict_free(pid);

    const rid = colyseus_gm_predict_reconciler(pid, h(truth), h(rig.handle), "{\"smoothing\":0,\"step_ms\":50}");
    try testing.expect(rid > 0);

    NOW = 0;
    _ = colyseus_gm_predict_tick(pid, NOW);
    gmPumpAccel(rid);

    const expected_x = [_]f64{ 0.025, 0.07500000000000001, 0.15000000000000002, 0.21250000000000002, 0.2625, 0.30000000000000004 };
    const expected_vx = [_]f64{ 0.5, 1, 1.5, 1.25, 1, 0.75 };
    var sent_ax: [8]f64 = undefined;
    var i: usize = 1;
    while (i <= 6) : (i += 1) {
        NOW = @as(f64, @floatFromInt(i)) * 50;
        _ = colyseus_gm_predict_tick(pid, NOW);
        gmPumpAccel(rid);
        const ax: f64 = if (i <= 3) 10 else -5;
        sent_ax[i] = ax;
        _ = colyseus_gm_input_set(h(rig.handle), "ax", ax);
        _ = colyseus_gm_input_send(h(rig.handle));
        gmPumpAccel(rid);
        if (i >= 3) {
            serverStep(truth, sent_ax[i - 2]);
            _ = c.colyseus_input_handle_ack_input(rig.handle, @intCast(i - 2));
            _ = colyseus_gm_predict_tick(pid, NOW);
            gmPumpAccel(rid);
        }
        const mirror = colyseus_gm_recon_state(rid);
        try testing.expectEqual(expected_x[i - 1], colyseus_gm_mirror_get(mirror, "x"));
        try testing.expectEqual(expected_vx[i - 1], colyseus_gm_mirror_get(mirror, "vx"));
        try testing.expectEqual(@as(f64, 0), colyseus_gm_recon_stat(rid, 2)); // correction mag
    }
    try testing.expectEqual(@as(f64, 4), colyseus_gm_recon_stat(rid, 3)); // reconcile_seq

    // divergent truth: server-side teleport
    serverStep(truth, sent_ax[4]);
    truth.*.x += 100;
    _ = c.colyseus_input_handle_ack_input(rig.handle, 5);
    NOW = 350;
    _ = colyseus_gm_predict_tick(pid, NOW);
    gmPumpAccel(rid);
    const mirror = colyseus_gm_recon_state(rid);
    try testing.expectEqual(@as(f64, 100.3), colyseus_gm_mirror_get(mirror, "x"));
    try testing.expectEqual(@as(f64, 0.75), colyseus_gm_mirror_get(mirror, "vx"));
    try testing.expectEqual(@as(f64, -100), colyseus_gm_recon_last_correction(rid, "x"));
    try testing.expectEqual(@as(f64, 100), colyseus_gm_recon_stat(rid, 2));
    try testing.expectEqual(@as(f64, 100.3), colyseus_gm_recon_value(rid, "x"));
    // input stats readable through the bridge
    try testing.expectEqual(@as(f64, 6), colyseus_gm_input_stat(h(rig.handle), 0));
    try testing.expectEqual(@as(f64, 5), colyseus_gm_input_stat(h(rig.handle), 1));
}

// ── 2. dynamic-vtable twin (the reflection path GM production uses) ─────

test "gm_reconciler_dynamic_truth" {
    gmDrain();
    const dvt = c.colyseus_dynamic_vtable_create("recon_state_dyn").?;
    defer c.colyseus_dynamic_vtable_free(dvt);
    c.colyseus_dynamic_vtable_add_field(dvt, c.colyseus_dynamic_field_create(0, "x", c.COLYSEUS_FIELD_NUMBER, "number"));
    c.colyseus_dynamic_vtable_add_field(dvt, c.colyseus_dynamic_field_create(1, "vx", c.COLYSEUS_FIELD_NUMBER, "number"));

    const rig = makeInput();
    defer c.colyseus_input_handle_free(rig.handle);

    const truth = c.colyseus_dynamic_schema_create(dvt).?;
    defer c.colyseus_dynamic_schema_free(truth);

    const pid = colyseus_gm_predict_create_with(0, 0);
    defer colyseus_gm_predict_free(pid);
    const rid = colyseus_gm_predict_reconciler(pid, h(truth), h(rig.handle), "{\"smoothing\":0,\"step_ms\":50}");
    try testing.expect(rid > 0);

    NOW = 0;
    _ = colyseus_gm_predict_tick(pid, NOW);
    gmPumpAccel(rid);

    const expected_x = [_]f64{ 0.025, 0.07500000000000001, 0.15000000000000002, 0.21250000000000002, 0.2625, 0.30000000000000004 };
    const expected_vx = [_]f64{ 0.5, 1, 1.5, 1.25, 1, 0.75 };
    var sent_ax: [8]f64 = undefined;
    var i: usize = 1;
    while (i <= 6) : (i += 1) {
        NOW = @as(f64, @floatFromInt(i)) * 50;
        _ = colyseus_gm_predict_tick(pid, NOW);
        gmPumpAccel(rid);
        const ax: f64 = if (i <= 3) 10 else -5;
        sent_ax[i] = ax;
        _ = colyseus_gm_input_set(h(rig.handle), "ax", ax);
        _ = colyseus_gm_input_send(h(rig.handle));
        gmPumpAccel(rid);
        if (i >= 3) {
            // dynamic server step through the same bridge writes GML would use
            const tvx = colyseus_gm_mirror_get(h(truth), "vx") + sent_ax[i - 2] * 0.05;
            _ = colyseus_gm_mirror_set(h(truth), "vx", tvx);
            _ = colyseus_gm_mirror_set(h(truth), "x",
                colyseus_gm_mirror_get(h(truth), "x") + tvx * 0.05);
            _ = c.colyseus_input_handle_ack_input(rig.handle, @intCast(i - 2));
            _ = colyseus_gm_predict_tick(pid, NOW);
            gmPumpAccel(rid);
        }
        const mirror = colyseus_gm_recon_state(rid);
        try testing.expectEqual(expected_x[i - 1], colyseus_gm_mirror_get(mirror, "x"));
        try testing.expectEqual(expected_vx[i - 1], colyseus_gm_mirror_get(mirror, "vx"));
    }
    try testing.expectEqual(@as(f64, 4), colyseus_gm_recon_stat(rid, 3));

    // a bare mirror must have NO userdata shadow
    const mirror_dyn: *c.colyseus_dynamic_schema_t =
        @ptrFromInt(@as(usize, @intFromFloat(colyseus_gm_recon_state(rid))));
    try testing.expect(mirror_dyn.*.userdata == null);
}

// ── 3. scenario C (sim_reconciler_bound) through the bridge ─────────────

fn gmPumpSim(recon_id: f64, paddle: f64, puck: f64) void {
    while (colyseus_gm_recon_pump_begin(recon_id) > 0) {
        while (colyseus_gm_recon_pump_next(recon_id) != 0) {
            const dt = colyseus_gm_step_ctx(0);
            const ax = colyseus_gm_step_cmd("ax");
            _ = colyseus_gm_mirror_set(paddle, "vx", ax);
            _ = colyseus_gm_mirror_set(paddle, "x",
                colyseus_gm_mirror_get(paddle, "x") + ax * dt);
            _ = colyseus_gm_mirror_set(puck, "px",
                colyseus_gm_mirror_get(puck, "px") + 1);
            colyseus_gm_recon_pump_commit(recon_id);
        }
        colyseus_gm_recon_pump_end(recon_id);
    }
}

test "gm_sim_reconciler_bound" {
    gmDrain();
    const rig = makeInput();
    defer c.colyseus_input_handle_free(rig.handle);

    const paddle_truth = c.sim_paddle_create().?;
    paddle_truth.*.__base.__vtable = &c.sim_paddle_vtable;
    const puck_truth = c.sim_puck_create().?;
    puck_truth.*.__base.__vtable = &c.sim_puck_vtable;
    defer c.sim_paddle_vtable.destroy.?(@ptrCast(paddle_truth));
    defer c.sim_puck_vtable.destroy.?(@ptrCast(puck_truth));

    const pid = colyseus_gm_predict_create_with(0, 0);
    defer colyseus_gm_predict_free(pid);

    try testing.expectEqual(@as(f64, 1), colyseus_gm_sim_begin(pid));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_sim_part("paddle", h(paddle_truth)));
    try testing.expectEqual(@as(f64, 2), colyseus_gm_sim_part("puck", h(puck_truth)));
    const rid = colyseus_gm_sim_create(h(rig.handle), 0, 0, 50, 0);
    try testing.expect(rid > 0);

    const paddle = colyseus_gm_sim_part_mirror(rid, "paddle");
    const puck = colyseus_gm_sim_part_mirror(rid, "puck");
    try testing.expect(paddle != 0 and paddle != h(paddle_truth));
    try testing.expect(puck != 0 and puck != h(puck_truth));

    NOW = 0;
    _ = colyseus_gm_predict_tick(pid, NOW);
    gmPumpSim(rid, paddle, puck);

    _ = colyseus_gm_input_set(h(rig.handle), "ax", 2);
    _ = colyseus_gm_input_send(h(rig.handle));
    _ = colyseus_gm_input_send(h(rig.handle));
    gmPumpSim(rid, paddle, puck);

    // three read paths onto one pose: mirror, pose key, bound overlay
    try testing.expectEqual(@as(f64, 0.2), colyseus_gm_mirror_get(paddle, "x"));
    try testing.expectEqual(@as(f64, 2), colyseus_gm_mirror_get(puck, "px"));
    try testing.expectEqual(@as(f64, 0.1), colyseus_gm_recon_value(rid, "paddle.x"));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_recon_value(rid, "puck.px"));
    try testing.expectEqual(@as(f64, 0.1), colyseus_gm_predict_value(pid, h(paddle_truth), "x"));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_predict_value(pid, h(puck_truth), "px"));

    // f32 wire-rounded truth ack: adopt + replay carries the float noise
    paddle_truth.*.x = @as(f64, @as(f32, 0.1));
    paddle_truth.*.vx = 2;
    puck_truth.*.px = 1;
    _ = c.colyseus_input_handle_ack_input(rig.handle, 1);
    NOW = 50;
    _ = colyseus_gm_predict_tick(pid, NOW);
    gmPumpSim(rid, paddle, puck);

    const mag = colyseus_gm_recon_stat(rid, 2);
    try testing.expect(mag > 0);
    try testing.expect(mag < 1e-6);
    try testing.expectEqual(@as(f64, 2), colyseus_gm_mirror_get(puck, "px"));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_recon_stat(rid, 3));
}

// ── 4. tick pacing + freed-child safety ─────────────────────────────────

test "gm_predict_tick_paces" {
    gmDrain();
    const rig = makeInput();
    defer c.colyseus_input_handle_free(rig.handle);
    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));

    const pid = colyseus_gm_predict_create_with(0, 0);
    defer colyseus_gm_predict_free(pid);
    const rid = colyseus_gm_predict_reconciler(pid, h(truth), h(rig.handle), "{\"smoothing\":0,\"step_ms\":50}");
    try testing.expect(rid > 0);

    try testing.expectEqual(@as(f64, 0), colyseus_gm_predict_tick(pid, 0));
    try testing.expectEqual(@as(f64, 0), colyseus_gm_predict_tick(pid, 20));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_predict_tick(pid, 60));
    try testing.expectEqual(@as(f64, 0), colyseus_gm_predict_tick(pid, 90));
    try testing.expectEqual(@as(f64, 3), colyseus_gm_predict_tick(pid, 200));
    try testing.expectEqual(@as(f64, 5), colyseus_gm_predict_tick(pid, 5000)); // hitch cap
    try testing.expectEqual(@as(f64, 0), colyseus_gm_predict_tick(pid, 5000));

    // freeing a driven child must deregister it
    colyseus_gm_recon_free(rid);
    _ = colyseus_gm_predict_tick(pid, 5100);
    try testing.expect(std.math.isNan(colyseus_gm_recon_value(rid, "x"))); // stale id
}

// ── 5. scenario D: passive smoothing via JSON attach config ─────────────

fn decodeBytes(decoder: *c.colyseus_decoder_t, bytes: []const u8) void {
    var it = c.colyseus_iterator_t{ .offset = 0 };
    c.colyseus_decoder_decode(decoder, bytes.ptr, bytes.len, &it);
}

test "gm_passive_smoothing" {
    gmDrain();
    c.colyseus_room_clock_now_provider = scriptedNow;

    const decoder = c.colyseus_decoder_create(&c.passive_ent_vtable).?;
    defer c.colyseus_decoder_free(decoder);
    const callbacks = c.colyseus_callbacks_create(decoder).?;
    defer c.colyseus_callbacks_free(callbacks);
    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);
    c.colyseus_room_clock_set_patch_interval(clock, 50);

    const pid = colyseus_gm_predict_create_with(h(callbacks), h(clock));
    try testing.expect(pid > 0);
    defer colyseus_gm_predict_free(pid);
    const ent: *c.colyseus_schema_t = @ptrCast(@alignCast(c.colyseus_decoder_get_state(decoder)));

    // modes as ints: 0 lerp, 1 extrapolate, 2 damped, 4 raw
    const cfg = "{\"a\":0,\"b\":2,\"c\":{\"mode\":1,\"damping\":-1},\"d\":4,\"yaw\":{\"mode\":0,\"angle\":true}}";
    try testing.expectEqual(@as(f64, 0), colyseus_gm_predict_attach(pid, h(ent), cfg));

    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1);
    decodeBytes(decoder, &[_]u8{ 128, 10, 129, 10, 130, 10, 131, 10, 132, 3 });
    NOW = 1050;
    c.colyseus_room_clock_sample(clock, 1050, -1);
    decodeBytes(decoder, &[_]u8{ 128, 20, 129, 20, 130, 20, 131, 20, 132, 253 });
    NOW = 1100;
    c.colyseus_room_clock_sample(clock, 1100, -1);
    decodeBytes(decoder, &[_]u8{ 128, 30, 129, 30, 130, 30, 131, 30 });

    NOW = 1150;
    _ = colyseus_gm_predict_tick(pid, NOW);
    try testing.expectEqual(@as(f64, 20), colyseus_gm_predict_value(pid, h(ent), "a"));
    try testing.expectEqual(@as(f64, 30), colyseus_gm_predict_value(pid, h(ent), "d"));
    try testing.expectEqual(@as(f64, 40), colyseus_gm_predict_value(pid, h(ent), "c"));
    try testing.expect(@abs(colyseus_gm_predict_value(pid, h(ent), "yaw")) > 3.0);

    NOW = 1175;
    _ = colyseus_gm_predict_tick(pid, NOW);
    try testing.expectEqual(@as(f64, 25), colyseus_gm_predict_value(pid, h(ent), "a"));
    try testing.expectEqual(@as(f64, 45), colyseus_gm_predict_value(pid, h(ent), "c"));

    // unknown field crosses the FFI as NAN, never a plausible 0
    try testing.expect(std.math.isNan(colyseus_gm_predict_value(pid, h(ent), "nope")));
}

// ── 6. scenario E: reckon + value_at through the built-in INTEGRATE step ─

test "gm_reckon_value_at" {
    gmDrain();
    c.colyseus_room_clock_now_provider = scriptedNow;

    const decoder = c.colyseus_decoder_create(&c.reckon_ball_vtable).?;
    defer c.colyseus_decoder_free(decoder);
    const callbacks = c.colyseus_callbacks_create(decoder).?;
    defer c.colyseus_callbacks_free(callbacks);
    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);

    const pid = colyseus_gm_predict_create_with(h(callbacks), h(clock));
    defer colyseus_gm_predict_free(pid);
    const ball: *c.colyseus_schema_t = @ptrCast(@alignCast(c.colyseus_decoder_get_state(decoder)));

    // INTEGRATE defaults (x += vx·dt; y/vy absent on this schema = no-ops)
    try testing.expectEqual(@as(f64, 0),
        colyseus_gm_predict_attach_reckon(pid, h(ball), "{\"fields\":\"x\",\"step_id\":1,\"substep_ms\":10}"));

    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1);
    decodeBytes(decoder, &[_]u8{ 128, 100, 129, 50 });

    const expect_x = [_][2]f64{ .{ 1000, 100 }, .{ 1050, 102.5 }, .{ 1100, 105 }, .{ 1200, 110 } };
    for (expect_x) |pair| {
        NOW = pair[0];
        _ = colyseus_gm_predict_tick(pid, NOW);
        try testing.expectEqual(pair[1], colyseus_gm_predict_value(pid, h(ball), "x"));
    }

    try testing.expectEqual(@as(f64, 107.5), colyseus_gm_predict_value_at(pid, h(ball), "x", 1150));
    try testing.expectEqual(@as(f64, 100), colyseus_gm_predict_value_at(pid, h(ball), "x", 900));
}

// ── 7. memo peek/store across live + replay ─────────────────────────────

var memo_evals: i32 = 0;

fn gmPumpMemo(recon_id: f64) void {
    while (colyseus_gm_recon_pump_begin(recon_id) > 0) {
        while (colyseus_gm_recon_pump_next(recon_id) != 0) {
            const ax = colyseus_gm_step_cmd("ax");
            const mirror = colyseus_gm_recon_state(recon_id);
            var bonus: f64 = std.math.nan(f64);
            if (colyseus_gm_step_ctx(6) != 0) {
                bonus = colyseus_gm_step_memo_peek(""); // replay: frozen or NAN
            } else {
                memo_evals += 1; // "the expensive derivation" runs live-only
                if (ax >= 2) bonus = colyseus_gm_step_memo_store("", 5);
            }
            const add: f64 = if (std.math.isNan(bonus)) 0 else bonus;
            _ = colyseus_gm_mirror_set(mirror, "x",
                colyseus_gm_mirror_get(mirror, "x") + ax + add);
            colyseus_gm_recon_pump_commit(recon_id);
        }
        colyseus_gm_recon_pump_end(recon_id);
    }
}

test "gm_memo_epoch" {
    gmDrain();
    memo_evals = 0;
    const rig = makeInput();
    defer c.colyseus_input_handle_free(rig.handle);
    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));

    const pid = colyseus_gm_predict_create_with(0, 0);
    defer colyseus_gm_predict_free(pid);
    const rid = colyseus_gm_predict_reconciler(pid, h(truth), h(rig.handle), "{\"fields\":\"x\",\"smoothing\":0,\"step_ms\":50}");
    try testing.expect(rid > 0);
    const mirror = colyseus_gm_recon_state(rid);

    NOW = 0;
    _ = colyseus_gm_predict_tick(pid, NOW);
    _ = colyseus_gm_input_set(h(rig.handle), "ax", 1);
    _ = colyseus_gm_input_send(h(rig.handle));
    gmPumpMemo(rid);
    _ = colyseus_gm_input_set(h(rig.handle), "ax", 2); // memoizes 5
    _ = colyseus_gm_input_send(h(rig.handle));
    gmPumpMemo(rid);
    _ = colyseus_gm_input_set(h(rig.handle), "ax", 1);
    _ = colyseus_gm_input_send(h(rig.handle));
    gmPumpMemo(rid);
    try testing.expectEqual(@as(f64, 9), colyseus_gm_mirror_get(mirror, "x")); // 1 + 7 + 1
    try testing.expectEqual(@as(i32, 3), memo_evals);

    // ack 1 with matching truth → adopt + replay of 2..3; memo frozen
    truth.*.x = 1;
    _ = c.colyseus_input_handle_ack_input(rig.handle, 1);
    NOW = 50;
    _ = colyseus_gm_predict_tick(pid, NOW);
    gmPumpMemo(rid);
    try testing.expectEqual(@as(f64, 9), colyseus_gm_mirror_get(mirror, "x"));
    try testing.expectEqual(@as(i32, 3), memo_evals); // replay did NOT re-derive

    // epoch follow: handle reset → controller self-resets from truth
    truth.*.x = 42;
    colyseus_gm_input_reset(h(rig.handle));
    NOW = 100;
    _ = colyseus_gm_predict_tick(pid, NOW);
    gmPumpMemo(rid);
    try testing.expectEqual(@as(f64, 42), colyseus_gm_mirror_get(mirror, "x"));
    try testing.expectEqual(@as(f64, 0), colyseus_gm_recon_stat(rid, 0)); // pending
}

// ── 8. event settlement via the polled queue (the GM-specific contract) ─

const SettleEvent = struct { kind: i32, key: [64]u8, key_len: usize, channel: f64 };

fn pollSettle(out: []SettleEvent) usize {
    var n: usize = 0;
    while (n < out.len) {
        const t = colyseus_gm_poll_event();
        if (t == 0) break;
        if (t != GM_EVENT_PREDICT_SETTLE) continue;
        out[n].kind = @intFromFloat(colyseus_gm_event_get_code());
        out[n].channel = colyseus_gm_event_get_callback_handle();
        const msg = std.mem.span(colyseus_gm_event_get_message());
        out[n].key_len = @min(msg.len, 63);
        @memcpy(out[n].key[0..out[n].key_len], msg[0..out[n].key_len]);
        n += 1;
    }
    return n;
}

fn expectSettle(ev: SettleEvent, kind: i32, key: []const u8) !void {
    try testing.expectEqual(kind, ev.kind);
    try testing.expectEqualStrings(key, ev.key[0..ev.key_len]);
}

test "gm_events_via_queue" {
    gmDrain();
    c.colyseus_room_clock_now_provider = scriptedNow;
    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);
    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1);

    const pid = colyseus_gm_predict_create_with(0, h(clock));
    defer colyseus_gm_predict_free(pid);
    const cid = colyseus_gm_events_create(h(clock), 3, 0, 0);
    try testing.expect(cid > 0);
    colyseus_gm_predict_drive_events(pid, cid);

    // UI-born predict + confirm; unpredicted confirm
    try testing.expectEqual(@as(f64, 1), colyseus_gm_events_predict(cid, "goal-a"));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_events_pending(cid));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_events_confirm(cid, "goal-a"));
    try testing.expectEqual(@as(f64, 0), colyseus_gm_events_confirm(cid, "goal-b"));

    // pending dedupe
    try testing.expectEqual(@as(f64, 1), colyseus_gm_events_predict(cid, "kill-1"));
    try testing.expectEqual(@as(f64, 0), colyseus_gm_events_predict(cid, "kill-1"));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_events_pending(cid));

    // UI-born TTL: rtt 0 → 600ms; the predict's tick drives the prune
    NOW = 1601;
    _ = colyseus_gm_predict_tick(pid, NOW);
    try testing.expectEqual(@as(f64, 0), colyseus_gm_events_pending(cid));

    var events: [8]SettleEvent = undefined;
    const n = pollSettle(&events);
    try testing.expectEqual(@as(usize, 5), n);
    try expectSettle(events[0], 0, "goal-a"); // predict
    try expectSettle(events[1], 1, "goal-a"); // confirm
    try expectSettle(events[2], 3, "goal-b"); // unpredicted
    try expectSettle(events[3], 0, "kill-1"); // predict
    try expectSettle(events[4], 2, "kill-1"); // reject (TTL)
    try testing.expectEqual(cid, events[0].channel);

    colyseus_gm_events_free(cid);
}

// ── 9. scenario G: spawn correlation + reject via the queue ─────────────

test "gm_spawns_correlation" {
    gmDrain();
    c.colyseus_room_clock_now_provider = scriptedNow;
    const clock = c.colyseus_room_clock_create().?;
    defer c.colyseus_room_clock_free(clock);
    NOW = 1000;
    c.colyseus_room_clock_sample(clock, 1000, -1);

    // recon_state doubles as the "rocket": x carries bornMs, vx == 1 marks mine
    const sid = colyseus_gm_spawns_create(h(clock), "{\"ttl_ms\":600,\"fields\":\"x,vx\",\"owned_field\":\"vx\",\"owned_value\":\"1\",\"spawn_time_field\":\"x\",\"step_id\":1}");
    try testing.expect(sid > 0);
    defer colyseus_gm_spawns_free(sid);

    _ = colyseus_gm_spawns_spawn_set(sid, "x", 0);
    _ = colyseus_gm_spawns_spawn_set(sid, "vx", 10);
    const id1 = colyseus_gm_spawns_spawn(sid);
    try testing.expectEqual(@as(f64, 1), id1);

    // pending local steps on the serverNow axis: dt 0.1 → x += 10·0.1 = 1
    colyseus_gm_spawns_tick(sid, 0);
    NOW = 1100;
    colyseus_gm_spawns_tick(sid, 0);
    try testing.expectEqual(@as(f64, 1), colyseus_gm_spawns_seek(sid, id1));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_spawns_entry_value(sid, "x"));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_spawns_entry_stat(sid, 4)); // has_local
    try testing.expectEqual(@as(f64, 0), colyseus_gm_spawns_entry_stat(sid, 1)); // !confirmed

    // authoritative arrival: fifo match + lead = bornMs − at = 1080 − 1000
    const server1 = c.recon_state_create().?;
    server1.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(server1));
    server1.*.x = 1080;
    server1.*.vx = 1;
    colyseus_gm_spawns_handle_add(sid, h(server1));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_spawns_seek(sid, id1));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_spawns_entry_stat(sid, 1)); // confirmed
    try testing.expectEqual(@as(f64, 80), colyseus_gm_spawns_entry_stat(sid, 2)); // lead_ms
    try testing.expectEqual(h(server1), colyseus_gm_spawns_entry_stat(sid, 3));

    // foreign entity (vx != 1): never consumes a prediction
    const server2 = c.recon_state_create().?;
    server2.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(server2));
    server2.*.x = 1090;
    server2.*.vx = -1;
    colyseus_gm_spawns_handle_add(sid, h(server2));
    var found_foreign = false;
    var iter = colyseus_gm_spawns_iter_begin(sid);
    while (iter != 0) : (iter = colyseus_gm_spawns_iter_next(sid)) {
        if (colyseus_gm_spawns_entry_stat(sid, 3) == h(server2)) {
            found_foreign = true;
            try testing.expectEqual(@as(f64, 0), colyseus_gm_spawns_entry_stat(sid, 2));
            try testing.expectEqual(@as(f64, 0), colyseus_gm_spawns_entry_stat(sid, 4));
        }
    }
    try testing.expect(found_foreign);

    // mispredict prune: unmatched pending, TTL 600 → SPAWN_REJECT in the queue
    _ = colyseus_gm_spawns_spawn_set(sid, "x", 0);
    _ = colyseus_gm_spawns_spawn_set(sid, "vx", 5);
    const id2 = colyseus_gm_spawns_spawn(sid);
    try testing.expect(id2 > 0);
    NOW = 1701;
    colyseus_gm_spawns_tick(sid, 0);
    try testing.expectEqual(@as(f64, 0), colyseus_gm_spawns_alive(sid, id2));
    var saw_reject = false;
    while (true) {
        const t = colyseus_gm_poll_event();
        if (t == 0) break;
        if (t == GM_EVENT_SPAWN_REJECT and
            colyseus_gm_event_get_code() == id2 and
            colyseus_gm_event_get_callback_handle() == sid) saw_reject = true;
    }
    try testing.expect(saw_reject);

    // remove drops the confirmed entry
    colyseus_gm_spawns_handle_remove(sid, h(server1));
    try testing.expectEqual(@as(f64, 0), colyseus_gm_spawns_alive(sid, 1));
    try testing.expectEqual(@as(f64, 1), colyseus_gm_spawns_size(sid));
}

// ── 10. stale handles + NAN discipline ──────────────────────────────────

test "gm_value_nan_and_stale_handles" {
    gmDrain();
    // stale/invalid registry ids: NAN or 0, never a crash
    try testing.expect(std.math.isNan(colyseus_gm_recon_value(99, "x")));
    try testing.expect(std.math.isNan(colyseus_gm_predict_value(99, 1, "x")));
    try testing.expectEqual(@as(f64, 0), colyseus_gm_recon_pump_begin(99));
    colyseus_gm_recon_free(99);
    colyseus_gm_predict_free(99);
    colyseus_gm_events_free(99);
    colyseus_gm_spawns_free(99);

    // a freed recon id goes stale immediately; double free is a no-op
    const rig = makeInput();
    defer c.colyseus_input_handle_free(rig.handle);
    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));
    const pid = colyseus_gm_predict_create_with(0, 0);
    const rid = colyseus_gm_predict_reconciler(pid, h(truth), h(rig.handle), "{\"smoothing\":0,\"step_ms\":50}");
    try testing.expect(!std.math.isNan(colyseus_gm_recon_value(rid, "x")));
    colyseus_gm_recon_free(rid);
    try testing.expect(std.math.isNan(colyseus_gm_recon_value(rid, "x")));
    colyseus_gm_recon_free(rid);
    colyseus_gm_predict_free(pid);
}

// ── 11. lifecycle: no cap exhaustion, children swept with their predict ─

test "gm_lifecycle_and_queue_isolation" {
    gmDrain();
    const rig = makeInput();
    defer c.colyseus_input_handle_free(rig.handle);
    const truth = c.recon_state_create().?;
    truth.*.__base.__vtable = &c.recon_state_vtable;
    defer c.recon_state_vtable.destroy.?(@ptrCast(truth));

    // create/free ×20 over caps of 8/8/16: slots must recycle
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        const pid = colyseus_gm_predict_create_with(0, 0);
        try testing.expect(pid > 0);
        const rid = colyseus_gm_predict_reconciler(pid, h(truth), h(rig.handle), "{\"smoothing\":0,\"step_ms\":50}");
        try testing.expect(rid > 0);
        const cid = colyseus_gm_events_create(0, 0, 0, 0);
        try testing.expect(cid > 0);
        colyseus_gm_predict_drive_events(pid, cid);
        // freeing the predict sweeps its driven children out of the registries
        colyseus_gm_predict_free(pid);
        try testing.expect(std.math.isNan(colyseus_gm_recon_value(rid, "x")));
        try testing.expectEqual(@as(f64, 0), colyseus_gm_events_pending(cid));
    }
    try testing.expectEqual(@as(f64, 0), colyseus_gm_poll_event());
    try testing.expect(colyseus_gm_predict_abi_version() >= 1);
}
