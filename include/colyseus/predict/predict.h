#ifndef COLYSEUS_PREDICT_PREDICT_H
#define COLYSEUS_PREDICT_PREDICT_H

#include "colyseus/schema/types.h"
#include "colyseus/schema/callbacks.h"
#include "colyseus/room_clock.h"

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

void colyseus_predict_free(colyseus_predict_t* p);

/*
 * Track one numeric field for smoothing (modes lerp/extrapolate/damped/raw).
 * `options` NULL = lerp with defaults. Returns 0 on success.
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
 */
int colyseus_predict_track_reckon(
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

/* Advance one render frame (drives damped/extrapolate clocks + reckon cache). */
void colyseus_predict_tick(colyseus_predict_t* p, double now);

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
