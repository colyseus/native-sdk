# Plan: predict layer for the Godot GDExtension (GDScript surface)

Phase 2 of the Godot playground effort (Phase 1 = `demos/prediction-tools/
clients/godot-app`, the C#/Mono build — DONE, acceptance 15/15). This document
is self-contained for a fresh session: it records the API design, the one
architectural constraint that shapes everything, and the milestones.

Authorities, in order:
1. `colyseus-0.18/packages/sdk/src/predict/Predictor.ts` — the reference
   surface. The bar: "the elegance and simplicity of the JS one".
2. `colyseus-0.18/PORTING.md` — what is deliberately NOT ported
   (track/untrack/trackStepped are internal; no deprecated aliases, ever).
3. `colyseus-0.18/PORTING/sdk-ports-predict-layer.md` — the algorithm
   contract; scenario C in `PORTING/generate-predict-fixtures.cts`
   (`sim_reconciler_bound`) is the fixture every port pins.
4. `native-sdk/include/colyseus/predict/*.h` — the C core being bound
   (~1050 lines across predict/reconciler/sim_reconciler/events/spawns +
   input_handle + room_clock). The core is COMPLETE and lab-proven
   (native-app runs all 12 labs on it). Phase 2 adds no algorithm work.

## 0. The constraint that shapes the design

The GDExtension decodes state through **dynamic vtables**
(`colyseus_dynamic_vtable_t`): instances are `colyseus_dynamic_schema_t` —
hash-table field storage plus a shadow **GDScript object** kept in sync via
`set_field_userdata`. Layout-compatible with `colyseus_schema_t` (base vtable
first member), so they pass through every API that takes a schema pointer.

The predict core, however, reads and writes fields **by struct offset**
(`colyseus_field_t.offset`) — that is what the "static vtables only" notes on
`attach_reckon` and sim parts mean. On a dynamic instance the offset path is
garbage. So the enabling work is:

**P2.1 — dynamic-field access in the predict core.** One internal
read/write helper (get/set double by `colyseus_field_t*`) that branches on
`colyseus_vtable_is_dynamic(vtable)` → `colyseus_dynamic_schema_get/_set`.
Everywhere the core touches instance fields (track sampling, reconciler
adopt/mirror copy, reckon scratch seed/readback, spawns reckon, bound-pose
reads) goes through it. Mirror/scratch creation calls `vtable->create()`,
which for a dynamic vtable creates a dynamic instance — **but mirrors and
scratches must NOT get a GDScript shadow object** (replay would push every
intermediate write through a Godot variant set). Add a "bare" dynamic-create
path (skip `create_userdata`) for internal instances; the GDScript-facing
wrapper below is the only bridge.

Everything else in Phase 2 is bindings and app.

## 1. GDScript API surface

Godot convention is snake_case and `X.of(room)` factories (the extension
already ships `Colyseus.Callbacks.of(room)`). Mapping from Predictor.ts:

```gdscript
# ── input (prerequisite — the extension has no input binding today) ──────
var input = room.input(MoveInput)          # -> ColyseusInputHandle
input.data.move_x = 1                      # the bound GDScript instance
var seq = input.send()                     # 0 = nothing sent
# handle: pending_count, last_processed, epoch, render_delay, reset()
# options dict: { unreliable, history_size, render_delay, allow_rewind: Callable }

# ── predict ──────────────────────────────────────────────────────────────
var predict = Colyseus.Predict.of(room)    # Predict.For(room)

predict.attach_all("players", {            # AttachConfig — per-field mode
    "x": Colyseus.Predict.DAMPED,          # bare mode enum, or
    "y": { "mode": Colyseus.Predict.LERP, "delay": 100 },
}, room.get_session_id())                  # optional except_key

predict.attach(bot, { "x": ..., "yaw": { "mode": ..., "angle": true } })

# reckon arm — the config carries a step Callable instead of a mode
predict.attach_all_reckon("bots", ["x", "y"],
    func(bot, dt, elapsed_ms): ...,        # SHARED with the server
    { "smoothing": 25, "snap": 8 })

var steps = predict.tick(now)              # returns fixed steps due
var x = predict.value(player, "x")         # THE read idiom
var bx = predict.value_at(bot, "x", ctx.reckon_time)

# ── reconciler (flat) ────────────────────────────────────────────────────
var recon = predict.reconciler(me, {
    "input": input,
    "fields": ["x", "y", "vx", "vy"],
    "smoothing": 15,
    "step": func(ctx, s, cmd):             # s = mirror wrapper, C storage
        # transliterated shared sim — same op order as the server
        s.x += s.vx * ctx.dt,
})
recon.value("x"); recon.state; recon.pending_count; recon.reconcile_seq
recon.last_correction_mag; recon.drift_ema; recon.reset()

# ── sim reconciler (composite) ───────────────────────────────────────────
var sim = predict.sim({
    "input": input,
    "world": { "paddle": me, "puck": room.get_state().puck },  # bound parts
    "step": func(ctx, w, cmd):
        # w.paddle / w.puck are mirror wrappers; server's step order
        ...,
})
# bound poses read back through predict.value(state.puck, "x");
# sim.value("part.field") stays the opaque-part escape hatch.

# ── optimistic events ────────────────────────────────────────────────────
var goals = predict.define_event({
    "on_predict": func(payload): ...,
    "on_confirm": func(payload): ...,
    "on_reject":  func(payload): ...,
})
# inside a step: ctx.predict(goals, "goal")  (live-only, replay-safe)
goals.confirm(); goals.pending_count

# ── predicted spawns ─────────────────────────────────────────────────────
var spawns = predict.spawns("projectiles", {
    "owned": func(p): return p.owner == sid,
    "spawn_time": func(p): return p.born_ms,
    "step": func(local, dt): ...,          # local = a Dictionary or object
    "fields": ["x", "y"],
    "reckon_step": func(p, dt, _t): ...,
    "read_local": func(local, f): ...,
})
var id = spawns.spawn(local)
for e in spawns.entries():                 # { id, server, local, confirmed, lead_ms }
    var x = spawns.value(e, "x")

# ── step context (inside step Callables) ─────────────────────────────────
ctx.dt; ctx.dt_ms; ctx.tick; ctx.is_replay; ctx.reckon_time
ctx.memo("bump", func(): return verdict)          # scalar
ctx.memo_vec("knock", func(): return [vx, vy])    # tuple, one derivation
ctx.predict(channel, key)
```

Excluded per PORTING.md: `track`/`untrack`/`trackStepped` (internal under
attach), custom `interpolate`/`pose` overlays for opaque parts. No aliases.

## 2. Binding architecture

New C files in `platforms/godot/src/` following the existing idioms
(register_types.c class registration, colyseus_room.c method style,
msgpack_variant helpers):

- `colyseus_input.c` — ColyseusInputHandle over `colyseus_room_input()`.
  Needs the input ENCODER to walk dynamic vtables too (check
  `input_encoder.c` for the same offset assumption — part of P2.1).
- `colyseus_predict.c` — ColyseusPredict (`of`, attach/attach_all/
  attach_all_reckon, tick, value, value_at, define_event, spawns,
  reconciler, sim). Owns the Callable refs for step functions.
- `colyseus_reconciler.c` — ColyseusReconciler + ColyseusSimWorld +
  ColyseusStepContext + the mirror wrapper (below).
- `colyseus_netdelay.c` — the latency injector at the C transport seam
  (fn-pointer swap, both directions, no reorder), surfaced as
  `Colyseus.set_latency(delay, jitter)` / `Colyseus.drop()`. The probe
  interposer in native-app shows the seam.

**The mirror wrapper** is the heart of the binding. Step Callables receive
mirrors/scratches as a registered `ColyseusSimState` object implementing
`_get`/`_set` by StringName → the C dynamic instance's hash slots. GDScript
then reads naturally (`s.x`, `w.paddle.vx`) while every write lands in C
storage — no GDScript shadow, no two-way sync, and `value()` reads never
touch the Godot object system. One wrapper instance per mirror, created at
construction (not per step).

**Callable dispatch budget**: a rollback replay at 400 ms latency is ~8-12
pending inputs × (1 step Callable + ~10 `_get`/`_set` round trips) per
reconcile. Measure with a synthetic backlog before writing all 12 labs
(P2.4 gate); if `_get`/`_set` StringName dispatch dominates, fall back to
pre-resolved field-index accessors (`s.get_f(0)`) — uglier, so only if
measured.

Threading: the extension's socket polling already marshals to the main
thread (`Colyseus.poll()` / autoload node). Predict/reconciler calls are
main-thread only, same as every other port.

## 3. Milestones

- **P2.1 core** — dynamic-field access helper in `native-sdk/src` predict
  core + input encoder; bare dynamic-create for mirrors/scratches.
  Gate: `zig build && zig build test` (static-vtable fixtures untouched),
  plus a new C test decoding a dynamic vtable and reconciling over it
  (mirror scenario C shape).
- **P2.2 bindings** — input handle + clock readouts, then Predict/
  Reconciler/StepContext, then events/spawns/sim world.
  Gate: headless GUT test in `platforms/godot/tests/` pinning scenario C
  (`value("paddle.x") == 0.1`, `value("puck.px") == 1`, ack-1 noise < 1e-6)
  against the example server, plus mulberry32/shotSeed canaries.
- **P2.3 injector** — `Colyseus.set_latency/drop` debug seam.
  Gate: an echo test showing RTT tracks the injected delay.
- **P2.4 app** — `demos/prediction-tools/clients/godot-gd-app`: GDScript
  sim port (f64 doubles — joins the bit-exact club; ints are 64-bit so
  `Math.imul` is wrapping multiply + `& 0xFFFFFFFF`, verify the wrap), the
  12 labs (crib scene structure + acceptance harness shape from godot-app),
  APPS_PLAN §7 milestones M1→M3.

## 4. Risks

- **Two-way sync temptation**: decoded truth instances DO have GDScript
  shadows; mirrors must not. Keep the rule crisp: *truth = shadowed,
  predicted = wrapper over C storage*.
- **Callable overhead** (above — measure at P2.2 exit, not P2.4).
- **Input encoder on dynamic vtables** may be a bigger lift than the predict
  helper if it leans on offsets deeply — scope it first thing in P2.1.
- **Web export**: wasm32-emscripten build must keep linking after the new
  files (no new libc deps); check early, it is the lane's headline feature.
