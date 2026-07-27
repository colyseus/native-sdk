#ifndef COLYSEUS_PREDICT_PREDICT_H
#define COLYSEUS_PREDICT_PREDICT_H

#include "colyseus/schema/types.h"
#include "colyseus/schema/callbacks.h"
#include "colyseus/room_clock.h"
#include "colyseus/predict/reconciler.h"
#include "colyseus/predict/events.h"
#include "colyseus/predict/spawns.h"

struct colyseus_room;

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Predict — passive smoothing of the server stream for entities you DON'T
 * control (port of predict/Predictor.ts, passive engine). One read idiom:
 * colyseus_predict_value(p, instance, field) — lerp / extrapolate / damped /
 * reckon / raw per tracked field, raw instance fallback when untracked.
 *
 * Samples arrive via the schema callbacks layer (listen), stamped on the
 * server-time axis when a clock is present. Call colyseus_predict_tick once
 * per render frame.
 */
typedef struct colyseus_predict colyseus_predict_t;

typedef enum {
    COLYSEUS_PREDICT_LERP,
    COLYSEUS_PREDICT_EXTRAPOLATE,
    COLYSEUS_PREDICT_DAMPED,
    COLYSEUS_PREDICT_RECKON,
    COLYSEUS_PREDICT_RAW,
} colyseus_predict_mode_t;

/* Per-field smoothing options. Zero-init + set `mode`; 0/false members take
 * the reference defaults (delay 100, damping 15, max_extrapolate 200). */
typedef struct {
    colyseus_predict_mode_t mode;
    double delay;            /* lerp render-time lag (ms) */
    double damping;          /* damped/extrapolate spring (1/s); < 0 = 0 (raw projection) */
    double max_extrapolate;  /* extrapolate overshoot cap (ms) */
    double tick_interval;    /* arrival-grid snap (ms); 0 off */
    double snap;             /* value-space teleport threshold; 0 off */
    bool angle;              /* radian angle — unwrap samples over the shortest arc */
} colyseus_predict_field_options_t;

/* Dead-reckoning step: advance `state` (a scratch schema instance) in place
 * by `dt` seconds; `elapsed_ms` is the absolute server-time at the END of
 * the substep (for time-sampled formulas). */
typedef void (*colyseus_predict_step_fn)(
    colyseus_schema_t* state, double dt, double elapsed_ms, void* userdata);

/*
 * Create a Predict over a callbacks layer (`colyseus_callbacks_create(decoder)`)
 * and an optional server-synced clock. The clock drives the sample timestamp
 * axis, the lerp render target and the reckon horizon; NULL falls back to
 * local time (no server-time interpolation).
 */
colyseus_predict_t* colyseus_predict_create(
    colyseus_callbacks_t* callbacks,
    colyseus_room_clock_t* clock);

/**
 * The one-call entry point: a Predict scoped to `room`, owning the callbacks
 * layer it needs and wired to the room clock and fixed step. This is what an
 * app should use — colyseus_predict_create() is for tests and for sharing one
 * callbacks layer across several Predicts (lab-style per-mode overlays).
 */
colyseus_predict_t* colyseus_predict_for_room(struct colyseus_room* room);

void colyseus_predict_free(colyseus_predict_t* p);

/* One field of an attach config: which field, and how to smooth it.
 *
 * The reference takes a per-field MAP (`{ x: "lerp", yaw: { mode: "damped",
 * angle: true } }`); C has no map literal, so the same thing is an array of
 * these. `opts` NULL = lerp with defaults. */
typedef struct {
    const char* field;
    const colyseus_predict_field_options_t* opts;
} colyseus_attach_field_t;

/*
 * Attach prediction to ONE instance from a declarative config — each field
 * picks its OWN mode, which the old (fields, options) pair could not express:
 *
 *   colyseus_predict_field_options_t yaw = { .mode = COLYSEUS_PREDICT_DAMPED,
 *                                            .angle = true };
 *   colyseus_attach_field_t cfg[] = { { "x", NULL }, { "yaw", &yaw } };
 *   colyseus_predict_attach(p, boss, cfg, 2);
 *
 * Fields the instance's schema doesn't declare are DROPPED, not an error: one
 * config can cover a heterogeneous collection. Returns 0 on success.
 *
 * NOTE the reference folds dead reckoning into this same call via a config
 * union; C has no overloading, so reckon keeps its own name below
 * (colyseus_predict_attach_reckon). That divergence is the language's, not a
 * design choice.
 */
int colyseus_predict_attach(
    colyseus_predict_t* p,
    colyseus_schema_t* instance,
    const colyseus_attach_field_t* config, int count);

/*
 * @internal Track one numeric field for smoothing (modes
 * lerp/extrapolate/damped/raw). `options` NULL = lerp with defaults. The
 * primitive under colyseus_predict_attach — PORTING.md strips
 * track/untrack/trackStepped from the published surface; it stays exported here
 * because C has no other way to keep it reachable from the library's own
 * translation units. Returns 0 on success.
 */
int colyseus_predict_track(
    colyseus_predict_t* p,
    colyseus_schema_t* instance,
    const char* field,
    const colyseus_predict_field_options_t* options);

/*
 * Dead-reckon `fields` of `instance` with a step function SHARED with the
 * server: each read forwards a scratch copy from the latest snapshot by the
 * snapshot age (serverNow − lastServerTime) in `substep_ms` sub-steps, then
 * offset-decay smooths the result (steady-state exact; rebase discontinuities
 * decay out; `snap` pops teleports). `smoothing 0` = raw projection.
 * Static vtables only. Returns 0 on success.
 *
 * The reckon arm of the attach config. Named apart from
 * colyseus_predict_attach only because C cannot overload.
 */
int colyseus_predict_attach_reckon(
    colyseus_predict_t* p,
    colyseus_schema_t* instance,
    const colyseus_schema_vtable_t* vtable,
    const char* const* fields, int field_count,
    colyseus_predict_step_fn step,
    double smoothing, double substep_ms, double snap,
    void* userdata);

/* Stop tracking every field of `instance` (called automatically when the
 * entity is removed if you wire on_remove to it). */
void colyseus_predict_detach(colyseus_predict_t* p, colyseus_schema_t* instance);

/**
 * Track EVERY entry of a collection — the ones present now and the ones that
 * arrive later — and stop tracking them as they are removed. This is the
 * common case: remote entities you smooth but do not control.
 *
 * Takes the same per-field config as colyseus_predict_attach. `config` NULL
 * tracks every numeric field of each entry with `fallback` (itself NULL =
 * lerp defaults). `except_key` skips one entry by map key (your own session
 * id); NULL tracks all. Returns 0 on success.
 */
int colyseus_predict_attach_all(
    colyseus_predict_t* p,
    colyseus_schema_t* state,
    const char* collection,
    const colyseus_attach_field_t* config, int count,
    const char* except_key,
    const colyseus_predict_field_options_t* fallback);

/*
 * ── Children ────────────────────────────────────────────────────────────
 * Objects created or registered here are DRIVEN by colyseus_predict_tick():
 * one call per frame advances the whole prediction stack instead of four.
 * Predict never frees them — it only drives them — and a child deregisters
 * itself when you free it.
 */

/**
 * Create a reconciler driven by this Predict, and bind the input handle's
 * lag-comp render delay to this Predict's lerp delay (so the server rewinds
 * to the instant this client actually displayed). Prefer this over
 * colyseus_reconciler_create().
 */
colyseus_reconciler_t* colyseus_predict_reconciler(
    colyseus_predict_t* p,
    colyseus_schema_t* truth,
    const colyseus_schema_vtable_t* vtable,
    colyseus_input_handle_t* input,
    colyseus_reconciler_step_fn step,
    const colyseus_reconciler_options_t* options);

/**
 * Like colyseus_predict_attach_all, but DEAD-RECKONS every entry through a step
 * function shared with the server (the bot patterns in a lab, an NPC's mover)
 * instead of smoothing samples.
 */
int colyseus_predict_attach_all_reckon(
    colyseus_predict_t* p,
    colyseus_schema_t* state,
    const char* collection,
    const colyseus_schema_vtable_t* entry_vtable,
    const char* const* fields, int field_count,
    colyseus_predict_step_fn step,
    double smoothing, double substep_ms, double snap,
    void* userdata);

/**
 * The callbacks layer this Predict uses. It belongs to the ROOM and outlives
 * this Predict, so anything you register on it directly you must also remove
 * yourself — prefer the attach_* helpers above, which are torn down with the
 * Predict.
 */
colyseus_callbacks_t* colyseus_predict_callbacks(colyseus_predict_t* p);

/**
 * Route a collection's adds/removes into a spawn store AND drive the store
 * from tick(). This is the whole wiring a predicted-spawn collection needs.
 */
void colyseus_predict_bind_spawns(colyseus_predict_t* p, colyseus_spawns_t* spawns,
    colyseus_schema_t* state, const char* collection);

/** Drive an event channel's settlement (its prune) from tick(). */
void colyseus_predict_drive_events(colyseus_predict_t* p, colyseus_event_channel_t* channel);
/** Drive a spawn store's local-step + TTL eviction from tick(). */
void colyseus_predict_drive_spawns(colyseus_predict_t* p, colyseus_spawns_t* spawns);
/** Stop driving a child (called for you by the child's own free()). */
void colyseus_predict_undrive(colyseus_predict_t* p, void* child);

/**
 * Advance one render frame: drive every child, then the damped/extrapolate
 * clocks and the reckon cache.
 *
 * RETURNS the number of fixed input steps due this frame — send exactly one
 * input per returned step and the client stays on the server's cadence:
 *
 *     int steps = colyseus_predict_tick(predict, now);
 *     for (int i = 0; i < steps; i++) { cmd->moveX = ...; colyseus_input_handle_send(input); }
 *
 * The count is 0 until a reconciler advertises the fixed step, and is capped at
 * 5 per frame (a hitch drops the backlog rather than firing a burst).
 */
int colyseus_predict_tick(colyseus_predict_t* p, double now);

/* Smoothed/predicted RENDER value; falls back to the raw instance field when
 * untracked. */
double colyseus_predict_value(colyseus_predict_t* p, colyseus_schema_t* instance, const char* field);

/* RAW reckoned value at an arbitrary server-time instant (no smoothing
 * offset) — for game logic / lag-comp hit tests. Non-reckon fields ignore
 * `time` and read as colyseus_predict_value. Reckoning into the past clamps
 * to the snapshot. */
double colyseus_predict_value_at(colyseus_predict_t* p, colyseus_schema_t* instance, const char* field, double time);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_PREDICT_PREDICT_H */
