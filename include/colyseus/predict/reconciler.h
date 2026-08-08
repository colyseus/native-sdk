#ifndef COLYSEUS_PREDICT_RECONCILER_H
#define COLYSEUS_PREDICT_RECONCILER_H

#include "colyseus/schema/types.h"
#include "colyseus/input_handle.h"
#include "colyseus/room_clock.h"
#include "colyseus/predict/drift.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Reconciler — server-reconciled rollback for a locally-controlled entity
 * (port of predict/rollback.ts + reconciler.ts, flat-fields face).
 *
 * A pure OBSERVER of an input handle: you mutate + send through the handle
 * (`input->data.x = …; colyseus_input_handle_send(input)`) and the reconciler
 * steps its predicted simulation for each send, buffers nothing itself (the
 * handle's replay ring holds the unacked inputs), and when the server ack
 * advances it rewinds to the authoritative instance + replays the still-
 * unacked inputs — smoothly absorbing mispredictions into per-field visual
 * offsets that decay to zero.
 *
 * The PREDICTED STATE is a schema-instance MIRROR (same vtable as the truth
 * instance): your `step` receives it as a plain struct pointer and mutates
 * fields directly — `((my_player_t*)state)->vy = …`. Numeric and boolean
 * fields participate; the mirror is seeded from the truth instance at
 * construction (string/ref/collection fields stay untouched on the mirror and
 * are NOT reconciled — read those off the raw instance).
 */
typedef struct colyseus_reconciler colyseus_reconciler_t;
struct colyseus_predict;

/* Per-step context (mirrors the server's StepContext — one fixed dt drives
 * both sides). Reused across steps; read inside `step` only. */
typedef struct colyseus_step_ctx {
    double dt;        /* fixed step in SECONDS (1/tickRate) */
    double dt_ms;     /* fixed step in MILLISECONDS */
    int tick;         /* the input's seq — the index of the step being simulated */
    int sub_steps;    /* physics sub-steps per fixed step (>= 1) */
    double sub_dt;    /* dt / sub_steps */
    double sub_dt_ms; /* dt_ms / sub_steps */
    /* true while re-simulating an already-applied input during rollback —
     * one-shot presentation must branch on this (`if (!ctx->is_replay) …`) */
    bool is_replay;
    /* the input's reckon instant (server-clock ms): the per-seq lag-comp stamp
     * when present (replay-deterministic), else the live serverNow() */
    double reckon_time;
    bool lag_comp_active;
    /* backing for colyseus_step_memo (opaque) */
    void* _memo_backing;
} colyseus_step_ctx_t;

/*
 * Memoize a NUMBER on the rollback timeline that replay can't re-derive (an
 * RNG roll, a lag-comp'd collision scalar). `compute(userdata)` runs exactly
 * ONCE — on the live step for this seq — and its result is frozen; every
 * replay of the seq returns the frozen value WITHOUT re-running compute.
 * Return NAN from compute for "nothing this seq". `key` disambiguates
 * multiple memos in one step ("" = the shared key-less slot).
 */
double colyseus_step_memo(const colyseus_step_ctx_t* ctx, const char* key,
    double (*compute)(void* userdata), void* userdata);

/**
 * Vector form: memoize up to COLYSEUS_MEMO_VEC_MAX doubles under one key —
 * a position, a velocity, a verdict plus its payload. Splitting a single
 * outcome across several scalar memos works but re-runs the derivation once
 * per component; this runs `compute` exactly once for the whole tuple.
 *
 * `compute` fills `out` and returns the number of values written (0 = nothing
 * this seq). Returns the count replayed (0 when the seq memoized nothing).
 */
#define COLYSEUS_MEMO_VEC_MAX 4
int colyseus_step_memo_vec(const colyseus_step_ctx_t* ctx, const char* key,
    int (*compute)(double* out, void* userdata), void* userdata, double* out);

/* Deterministic input-application step, SHARED with the server: mutate
 * `state` (the schema-instance mirror) by applying `command` over `ctx->dt`. */
typedef void (*colyseus_reconciler_step_fn)(
    const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata);

typedef struct {
    /* Error-decay rate (spring 1/s; 0 = hard snap). Default: the server's
     * correction cadence (1000/patchRate) when advertised, else 20. Pass a
     * NEGATIVE value to take the default; 0 means hard snap. */
    double smoothing;
    /* Teleport threshold (world units): a reconcile whose max |correction|
     * exceeds it POPS instead of decaying. 0/negative = off. */
    double snap;
    /* Fixed step overrides (0 = adopt from the handle's advertised rate;
     * construction FAILS when neither source yields a step). */
    double step_ms;
    double step_seconds;
    int sub_steps;
    /* Explicit field subset (names on the schema; NULL = every numeric/boolean
     * field of the vtable, declaration order). */
    const char* const* fields;
    int field_count;
    /* End-of-reconcile hook (after adopt+replay), with the acked seq. */
    void (*on_reconcile)(int acked, void* userdata);
    /* Manual pump mode: the reconciler never invokes a step callback (`step`
     * may be NULL) — the host drains due steps through the pump API below.
     * For hosts whose FFI cannot call back into script (GameMaker). */
    bool manual_step;
    /* Divergence warning tolerance (world units); 0/negative = telemetry
     * armed but never warns; NAN = telemetry off (production default is
     * simply 0 — the C port always records telemetry, it's two flops). */
    void* userdata; /* passed to step/on_reconcile/memo computes */
} colyseus_reconciler_options_t;

/*
 * Create a reconciler for `truth` (the decoded authoritative instance) whose
 * predicted mirror is a fresh instance of the same vtable. `step` is required.
 * Returns NULL when the fixed step can't be determined or a named field is
 * unknown/unsupported.
 */
colyseus_reconciler_t* colyseus_reconciler_create(
    colyseus_schema_t* truth,
    const colyseus_schema_vtable_t* vtable,
    colyseus_input_handle_t* input,
    colyseus_room_clock_t* clock,          /* resolves reckon_time fallback; may be NULL */
    colyseus_reconciler_step_fn step,
    const colyseus_reconciler_options_t* options);

void colyseus_reconciler_free(colyseus_reconciler_t* r);

/* The TRUE predicted state (the schema-instance mirror) — read for game
 * logic, mutate for replay-reproducible side effects. */
colyseus_schema_t* colyseus_reconciler_state(colyseus_reconciler_t* r);

/*
 * Advance one render frame: follow the handle's epoch (self-reset), poll the
 * server ack (reconcile + replay), decay the correction offsets. Live inputs
 * are stepped eagerly as the handle sends — tick never steps them.
 */
void colyseus_reconciler_tick(colyseus_reconciler_t* r, double now);

/* Rendered value of a numeric field: predicted state interpolated between the
 * two latest steps plus the decaying correction offset. `field` must be one
 * of the reconciled fields (by name). */
double colyseus_reconciler_value(colyseus_reconciler_t* r, const char* field);

/* Re-seed from the authoritative instance; drops offsets, memos and the
 * in-flight window (prior-life sends won't replay). */
void colyseus_reconciler_reset(colyseus_reconciler_t* r);

/* Telemetry + bookkeeping. */
int colyseus_reconciler_pending_count(const colyseus_reconciler_t* r);
double colyseus_reconciler_step_ms(const colyseus_reconciler_t* r);
const colyseus_drift_t* colyseus_reconciler_drift(const colyseus_reconciler_t* r);
double colyseus_reconciler_last_correction_mag(const colyseus_reconciler_t* r);
double colyseus_reconciler_last_correction(const colyseus_reconciler_t* r, const char* field);
int colyseus_reconciler_reconcile_seq(const colyseus_reconciler_t* r);

/*
 * Manual pump — inverted control for hosts whose FFI cannot call back into
 * script (GameMaker's one-way extension ABI). Create with
 * `options.manual_step = true` (`step` may be NULL); the reconciler then
 * never invokes a step callback. Each frame, AFTER colyseus_reconciler_tick()
 * and after any colyseus_input_handle_send(), drain the due steps:
 *
 *   int n;
 *   while ((n = colyseus_reconciler_pump_begin(r)) > 0) {
 *       const colyseus_step_ctx_t* ctx;
 *       const colyseus_schema_t* cmd;
 *       while ((cmd = colyseus_reconciler_pump_next(r, &ctx)) != NULL) {
 *           // THE STEP: apply cmd to colyseus_reconciler_state(r) over ctx->dt
 *           colyseus_reconciler_pump_commit(r);
 *       }
 *       colyseus_reconciler_pump_end(r);
 *   }
 *
 * One begin() serves ONE phase — a pending reconcile's replay burst
 * (ctx->is_replay = true; only seqs that already ran live are replayed), or
 * the live catch-up for inputs sent since the last drain — so loop until
 * begin() returns 0 to drain both. A send that coincides with an ack is
 * served in the live phase, never mislabeled a replay. Error decay that
 * tick() deferred while a reconcile was pending is applied inside
 * pump_end(), preserving the auto path's rebase-then-decay ordering exactly.
 * Reads (value(), state()) between tick() and the drain see pre-reconcile
 * state; read after draining.
 *
 * Misuse: a phase left open (a missed pump_end) is auto-closed by the next
 * begin(); serving a step without pump_commit abandons that step at
 * pump_end. The live phase only advances through pump_next/pump_commit —
 * a host that begins but never drains will see begin() > 0 again.
 */
int colyseus_reconciler_pump_begin(colyseus_reconciler_t* r);
const colyseus_schema_t* colyseus_reconciler_pump_next(colyseus_reconciler_t* r,
                                                       const colyseus_step_ctx_t** out_ctx);
void colyseus_reconciler_pump_commit(colyseus_reconciler_t* r);
void colyseus_reconciler_pump_end(colyseus_reconciler_t* r);

/* @internal — set by colyseus_predict_reconciler() so free() can deregister. */
void colyseus_reconciler_set_driver_(colyseus_reconciler_t* r, struct colyseus_predict* driver);

/* One controller-owned (instance, field) and the pose key it reads back as.
 * Flattened to triples rather than the reference's per-instance registration
 * arrays: no nested ownership to hand across the module boundary. */
typedef struct {
    colyseus_schema_t* source;   /* the DECODED instance, never the mirror */
    const char* field;           /* borrowed — outlives the call, owned by `r` */
    const char* pose_key;        /* == field on the flat face */
} colyseus_bound_field_t;

/* @internal — enumerate what colyseus_predict_value() needs to reach this
 * controller's poses. Returns the total count; pass out=NULL (max ignored) to
 * size first. Writes at most `max`. */
int colyseus_reconciler_bound_fields_(const colyseus_reconciler_t* r,
                                      colyseus_bound_field_t* out, int max);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_PREDICT_RECONCILER_H */
