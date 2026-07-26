#ifndef COLYSEUS_PREDICT_SIM_RECONCILER_H
#define COLYSEUS_PREDICT_SIM_RECONCILER_H

#include "colyseus/predict/reconciler.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * SimReconciler — the COMPOSITE face of the same rollback engine that drives
 * colyseus_reconciler_t (port of predict/simReconciler.ts). Where the flat
 * Reconciler predicts ONE decoded entity's scalar fields, this one predicts a
 * WORLD of parts and reads back a POSE keyed "<part>.<field>".
 *
 * Two kinds of part:
 *
 *   BOUND   — `source` is a decoded schema instance. The store builds a MIRROR
 *             of the same vtable and hands the mirror to your step; on every
 *             reconcile each mirror is pulled back from its source
 *             unconditionally (there is no wire-precision short-circuit here —
 *             a composite sim always adopts).
 *   OPAQUE  — `source` is NULL and `opaque` is your own struct. The store never
 *             touches it; your `adopt` callback restores it from whatever
 *             authority you have.
 *
 * Everything else — tick(), value(), reset(), free(), the drift/correction
 * telemetry — is the shared colyseus_reconciler_* surface.
 *
 * NOT ported (see PORTING.md): custom `pose`/`interpolate` overlays, and the
 * boundRegistrations hook into Predict.value — read poses through
 * colyseus_reconciler_value() instead.
 */

/** Opaque handle to the world, passed to the step and adopt callbacks. */
typedef struct colyseus_sim_world colyseus_sim_world_t;

typedef struct {
    /** Pose-key prefix, e.g. "paddle" -> "paddle.x". Must be unique. */
    const char* name;
    /** Decoded truth instance; NULL makes the part opaque. */
    colyseus_schema_t* source;
    /** Required when `source` is set (static vtables only). */
    const colyseus_schema_vtable_t* vtable;
    /** App pointer for an opaque part; ignored when `source` is set. */
    void* opaque;
} colyseus_sim_part_t;

/**
 * Deterministic step over the whole world, SHARED with the server. Fetch parts
 * with colyseus_sim_world_part(); mutate them in place.
 */
typedef void (*colyseus_sim_step_fn)(const colyseus_step_ctx_t* ctx,
    colyseus_sim_world_t* world, const colyseus_schema_t* command, void* userdata);

typedef struct {
    const colyseus_sim_part_t* parts;
    int part_count;

    /* Same semantics as colyseus_reconciler_options_t. */
    double smoothing;      /* negative = default; 0 = hard snap */
    double snap;
    double step_ms;
    double step_seconds;
    int sub_steps;

    /**
     * Restore the OPAQUE parts from authority before each replay. Bound parts
     * are pulled from their sources first, unconditionally. Required when no
     * part is bound — otherwise there is no restore point and creation fails.
     */
    void (*adopt)(colyseus_sim_world_t* world, void* userdata);
    void (*on_reconcile)(int acked, void* userdata);
    void* userdata;       /* passed to step/adopt/on_reconcile/memo computes */
} colyseus_sim_reconciler_options_t;

/**
 * Create a composite reconciler. Returns a colyseus_reconciler_t — free it with
 * colyseus_reconciler_free(), tick it with colyseus_reconciler_tick(), and read
 * poses with colyseus_reconciler_value(r, "part.field").
 *
 * Returns NULL when the fixed step can't be determined, a bound part has no
 * scalar fields, or nothing is bound and no `adopt` was supplied.
 */
colyseus_reconciler_t* colyseus_sim_reconciler_create(
    colyseus_input_handle_t* input,
    colyseus_room_clock_t* clock,          /* resolves reckon_time; may be NULL */
    colyseus_sim_step_fn step,
    const colyseus_sim_reconciler_options_t* options);

/**
 * The live object for `name`: the MIRROR (a colyseus_schema_t* of the part's
 * vtable) for a bound part, or your `opaque` pointer. NULL when unknown.
 */
void* colyseus_sim_world_part(colyseus_sim_world_t* world, const char* name);

/** The world handle of a sim reconciler (NULL for the flat face). */
colyseus_sim_world_t* colyseus_sim_reconciler_world(colyseus_reconciler_t* r);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_PREDICT_SIM_RECONCILER_H */
