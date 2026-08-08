#include "colyseus/predict/reconciler.h"
#include "colyseus/predict/sim_reconciler.h"
#include "colyseus/predict/predict.h"
#include "colyseus/schema/dynamic_schema.h"
#include "field_access.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Reconcile/decay math must be bit-identical to the JS reference (fixtures
 * compare float64 strictly where exp() isn't involved) — see quantize.c /
 * room_clock.c for the clang ARM64 FMA story.
 */
#pragma STDC FP_CONTRACT OFF

/* Forward decls for the composite face (definitions after the shared engine). */
typedef struct colyseus_reconciler colyseus_reconciler_impl_t;
static void sim_refresh_pose(colyseus_reconciler_impl_t* r);
static void sim_adopt_bound(colyseus_reconciler_impl_t* r);

/* ── memo store (numbers; NAN = none) ────────────────────────────────── */

#define MEMO_KEYS_PER_SEQ 8
#define MEMO_KEY_MAX 24

typedef struct {
    char key[MEMO_KEY_MAX];
    double value;                            /* scalar form: values[0] */
    double values[COLYSEUS_MEMO_VEC_MAX];
    int count;                               /* 0 = scalar entry */
} memo_entry_t;

typedef struct {
    double seq; /* -1 = empty */
    int count;
    memo_entry_t entries[MEMO_KEYS_PER_SEQ];
} memo_slot_t;

/* ── field view ──────────────────────────────────────────────────────── */

typedef struct {
    colyseus_field_type_t type;
    size_t offset;   /* static instances */
    int index;       /* dynamic instances */
    const char* name;
    bool numeric; /* number-family (booleans reconcile verbatim, not smoothed) */
} recon_field_t;

/* ── composite face (simReconciler.ts) ───────────────────────────────── */

#define SIM_NAME_MAX 24
#define SIM_POSE_KEY_MAX 48

typedef struct {
    char name[SIM_NAME_MAX];
    colyseus_schema_t* source;               /* NULL = opaque part */
    colyseus_schema_t* mirror;               /* bound only (owned) */
    void* opaque;
    const colyseus_schema_vtable_t* vtable;
    recon_field_t* fields;                   /* bound: numeric scalars */
    int field_count;
    int pose_base;                           /* index into the pose arrays */
} sim_part_t;

struct colyseus_sim_world {
    sim_part_t* parts;
    int part_count;
    colyseus_sim_step_fn step;
    void (*adopt)(colyseus_sim_world_t* world, void* userdata);
    void* userdata;
    double* cur_pose;                        /* [reconciler field_count] */
    char (*pose_keys)[SIM_POSE_KEY_MAX];
};

struct colyseus_reconciler {
    colyseus_schema_t* truth;
    const colyseus_schema_vtable_t* vtable;
    colyseus_input_handle_t* input;
    colyseus_room_clock_t* clock;
    colyseus_reconciler_step_fn step;
    void (*on_reconcile)(int acked, void* userdata);
    void* userdata;

    colyseus_schema_t* mirror; /* the predicted state (owned) */

    /* Non-NULL switches the state face from ONE mirrored instance to a world
     * of parts read back as a pose; the rollback loop below is unchanged. */
    colyseus_sim_world_t* sim;

    recon_field_t* fields;
    int field_count;

    double* error;             /* per field (meaningful for numeric) */
    double* prev;
    double* rendered_before;   /* reconcile scratch */
    double* last_correction;
    double last_correction_mag;
    int reconcile_seq;
    colyseus_drift_t drift;

    double smoothing;
    double snap_threshold;
    double step_ms;

    colyseus_step_ctx_t ctx;

    bool has_last_tick;
    double last_tick;
    int last_acked;
    int last_epoch;
    int replay_from;
    int predicted_seq;
    bool catching;
    double render_acc;
    int send_subscription;

    /* wire-precision history ring (every field numeric/bool ⇒ on) */
    int history_size;
    double* history;      /* [slot * field_count + i] */
    double* history_seq;  /* slot → seq (-1 = empty) */

    memo_slot_t* memos;   /* [history_size] */

    /* manual pump (hosts that can't receive C callbacks — see reconciler.h) */
    bool manual;
    int pump_phase;        /* 0 idle, 1 replay, 2 live catch-up */
    bool pump_step_open;   /* a served step awaits pump_commit() */
    int pump_seq;          /* seq being served */
    int pump_end_seq;
    int pump_acked;        /* ack awaiting a pumped reconcile; -1 = none */
    double pump_decay_dt;  /* decay deferred while a reconcile is pending */

    /* The Predict driving this controller, if it was born from one — free()
     * deregisters so a dropped reconciler can never be ticked again. */
    struct colyseus_predict* driver;
};

/* ── value access on schema instances (either storage model) ─────────── */

static double read_num(const colyseus_schema_t* instance, const recon_field_t* f) {
    return predict_scalar_read(instance, f->type, f->offset, f->index);
}

static void write_num(colyseus_schema_t* instance, const recon_field_t* f, double v) {
    predict_scalar_write(instance, f->type, f->offset, f->index, f->name, v);
}

/* Mirror of the codec's dynamic `number` wire rule (see schema.ts's
 * quantizeAutoNumber): what value would the wire deliver for this float64? */
static double quantize_auto_number(double v) {
    if (isnan(v)) return 0;
    if (isinf(v)) return v > 0 ? 9007199254740991.0 : -9007199254740991.0;
    bool is_int32 = v == floor(v) && v >= -2147483648.0 && v <= 2147483647.0;
    if (!is_int32) {
        if (fabs(v) <= 3.4028235e+38) {
            double f = (double)(float)v;
            if (fabs(fabs(f) - fabs(v)) < 1e-4) return f;
        }
    }
    return v;
}

static double wire_round(const recon_field_t* f, double v) {
    switch (f->type) {
        case COLYSEUS_FIELD_FLOAT32: return (double)(float)v;
        case COLYSEUS_FIELD_NUMBER:  return quantize_auto_number(v);
        default:                     return v; /* exact types + quantized: identity */
    }
}

/* Claim (or reclaim) this seq's memo slot on a LIVE step. */
static memo_slot_t* memo_slot_for(colyseus_reconciler_t* r, const colyseus_step_ctx_t* ctx) {
    memo_slot_t* slot = &r->memos[ctx->tick % r->history_size];
    if (slot->seq != (double)ctx->tick) {
        slot->seq = (double)ctx->tick;
        slot->count = 0;
    }
    return slot;
}

/* ── ctx.memo ────────────────────────────────────────────────────────── */

double colyseus_step_memo(const colyseus_step_ctx_t* ctx, const char* key,
    double (*compute)(void* userdata), void* userdata) {
    colyseus_reconciler_t* r = (colyseus_reconciler_t*)ctx->_memo_backing;
    if (!r || !key) return compute ? compute(userdata) : NAN;
    memo_slot_t* slot = &r->memos[ctx->tick % r->history_size];

    if (ctx->is_replay) {
        if (slot->seq != (double)ctx->tick) return NAN;
        for (int i = 0; i < slot->count; i++) {
            if (strncmp(slot->entries[i].key, key, MEMO_KEY_MAX) == 0) return slot->entries[i].value;
        }
        return NAN;
    }

    /* live: (re)claim the slot for this seq, run compute, store non-NAN */
    if (slot->seq != (double)ctx->tick) {
        slot->seq = (double)ctx->tick;
        slot->count = 0;
    }
    double v = compute(userdata);
    if (!isnan(v)) {
        for (int i = 0; i < slot->count; i++) {
            if (strncmp(slot->entries[i].key, key, MEMO_KEY_MAX) == 0) {
                slot->entries[i].value = v;
                return v;
            }
        }
        if (slot->count < MEMO_KEYS_PER_SEQ) {
            strncpy(slot->entries[slot->count].key, key, MEMO_KEY_MAX - 1);
            slot->entries[slot->count].key[MEMO_KEY_MAX - 1] = '\0';
            slot->entries[slot->count].value = v;
            slot->count++;
        }
    }
    return v;
}

static void memos_prune(colyseus_reconciler_t* r, int acked) {
    for (int i = 0; i < r->history_size; i++) {
        if (r->memos[i].seq >= 0 && r->memos[i].seq <= (double)acked) r->memos[i].seq = -1;
    }
}

static void memos_clear(colyseus_reconciler_t* r) {
    for (int i = 0; i < r->history_size; i++) r->memos[i].seq = -1;
}

/* ── engine ──────────────────────────────────────────────────────────── */

/* The current predicted value of field `i`: a mirror field, or a pose entry. */
static double cur_value(const colyseus_reconciler_t* r, int i) {
    return r->sim ? r->sim->cur_pose[i] : read_num(r->mirror, &r->fields[i]);
}

/* Pre-step: load this seq's context (shared by the auto path and the pump). */
static void step_ctx_load(colyseus_reconciler_t* r, int seq) {
    r->ctx.tick = seq;
    double raw = colyseus_input_handle_reckon_time_at(r->input, seq);
    r->ctx.lag_comp_active = raw > 0;
    r->ctx.reckon_time = raw > 0 ? raw
        : (r->clock ? colyseus_room_clock_server_now(r->clock) : 0);
}

/* Post-step: record this seq's predicted state (live and replay alike). */
static void step_record(colyseus_reconciler_t* r, int seq) {
    if (r->sim) {
        /* No wire-precision ring: a composite sim always adopts. */
        sim_refresh_pose(r);
        return;
    }
    int slot = seq % r->history_size;
    double* base = &r->history[(size_t)slot * r->field_count];
    for (int i = 0; i < r->field_count; i++) base[i] = read_num(r->mirror, &r->fields[i]);
    r->history_seq[slot] = (double)seq;
}

static void run_step(colyseus_reconciler_t* r, int seq, const colyseus_schema_t* command) {
    step_ctx_load(r, seq);
    if (r->sim) r->sim->step(&r->ctx, r->sim, command, r->userdata);
    else r->step(&r->ctx, r->mirror, command, r->userdata);
    step_record(r, seq);
}

static void snapshot_prev(colyseus_reconciler_t* r) {
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) r->prev[i] = cur_value(r, i) + r->error[i];
    }
}

/* Consume one step of the render clock, resyncing into [0, stepMs). */
static void consume_render_step(colyseus_reconciler_t* r) {
    r->render_acc -= r->step_ms;
    if (r->render_acc < 0) r->render_acc = 0;
    else if (r->render_acc >= r->step_ms) r->render_acc = fmod(r->render_acc, r->step_ms);
}

static void decay_error(colyseus_reconciler_t* r, double dt) {
    double k = r->smoothing <= 0 ? 1 : 1 - exp(-r->smoothing * dt / 1000);
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) r->error[i] -= r->error[i] * k;
    }
}

static void catch_up(colyseus_reconciler_t* r) {
    int sent = colyseus_input_handle_sent_count(r->input);
    if (r->predicted_seq >= sent || r->catching) return;
    r->catching = true;
    r->ctx.is_replay = false;
    for (int seq = r->predicted_seq + 1; seq <= sent; seq++) {
        colyseus_schema_t* inp = colyseus_input_handle_at(r->input, seq);
        if (inp != NULL) {
            snapshot_prev(r);
            run_step(r, seq, inp);
            consume_render_step(r);
        }
        r->predicted_seq = seq;
    }
    r->catching = false;
}

static void on_send_hook(int seq, void* userdata) {
    (void)seq;
    catch_up((colyseus_reconciler_t*)userdata);
}

static double render_alpha(const colyseus_reconciler_t* r) {
    if (r->step_ms <= 0) return 1;
    double a = r->render_acc / r->step_ms;
    return a < 0 ? 0 : a > 1 ? 1 : a;
}

static void adopt_truth(colyseus_reconciler_t* r) {
    if (r->sim) {
        /* Bound mirrors pull FIRST and unconditionally, then the app restores
         * whatever opaque parts it owns. */
        sim_adopt_bound(r);
        if (r->sim->adopt) r->sim->adopt(r->sim, r->userdata);
        return;
    }
    for (int i = 0; i < r->field_count; i++) {
        write_num(r->mirror, &r->fields[i], read_num(r->truth, &r->fields[i]));
    }
}

/* Wire-precision compare of the ring prediction at `acked` vs decoded truth. */
static bool truth_matches_at(colyseus_reconciler_t* r, int acked) {
    if (r->sim) return false;   /* composite face: always adopt */
    int slot = acked % r->history_size;
    if (r->history_seq[slot] != (double)acked) return false;
    const double* base = &r->history[(size_t)slot * r->field_count];
    for (int i = 0; i < r->field_count; i++) {
        if (wire_round(&r->fields[i], base[i]) != read_num(r->truth, &r->fields[i])) return false;
    }
    return true;
}

/* Wire-precision short-circuit: prediction at `acked` matched — no adopt, no
 * replay. Returns false when a full reconcile is needed. */
static bool reconcile_short_circuit(colyseus_reconciler_t* r, int acked) {
    if (!truth_matches_at(r, acked)) return false;
    for (int i = 0; i < r->field_count; i++) r->last_correction[i] = 0;
    r->last_correction_mag = 0;
    colyseus_drift_update(&r->drift, 0);
    r->reconcile_seq++;
    memos_prune(r, acked);
    if (r->on_reconcile) r->on_reconcile(acked, r->userdata);
    return true;
}

/* Pre-replay half of a full reconcile: snapshot the rendered pose, adopt
 * authority. The replay loop runs between this and reconcile_settle(). */
static void reconcile_adopt(colyseus_reconciler_t* r) {
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) r->rendered_before[i] = cur_value(r, i) + r->error[i];
    }
    adopt_truth(r);
    /* refreshRender: with nothing to replay the pose would still hold the
     * pre-adopt values, and the correction below would read them. */
    if (r->sim) sim_refresh_pose(r);
}

/* Post-replay half: re-base the error so the rendered pose is unchanged at
 * this instant, then snap/drift/memo bookkeeping. */
static void reconcile_settle(colyseus_reconciler_t* r, int acked) {
    bool hard = r->smoothing <= 0;
    double mag = 0;
    for (int i = 0; i < r->field_count; i++) {
        if (!r->fields[i].numeric) { r->last_correction[i] = 0; continue; }
        double correction = r->rendered_before[i] - cur_value(r, i);
        r->error[i] = hard ? 0 : correction;
        double a = correction < 0 ? -correction : correction;
        if (a > mag) mag = a;
        r->last_correction[i] = correction;
    }

    bool popped = r->snap_threshold > 0 && mag > r->snap_threshold;
    if (popped) {
        for (int i = 0; i < r->field_count; i++) {
            if (!r->fields[i].numeric) continue;
            r->error[i] = 0;
            r->prev[i] = cur_value(r, i);
        }
    }
    r->reconcile_seq++;
    r->last_correction_mag = mag;
    if (!popped) colyseus_drift_update(&r->drift, mag);

    memos_prune(r, acked);
    if (r->on_reconcile) r->on_reconcile(acked, r->userdata);
}

static void reconcile(colyseus_reconciler_t* r, int acked) {
    if (reconcile_short_circuit(r, acked)) return;
    reconcile_adopt(r);

    /* replay still-unacked inputs from the handle's buffer */
    int from = acked > r->replay_from ? acked : r->replay_from;
    int sent = colyseus_input_handle_sent_count(r->input);
    r->ctx.is_replay = true;
    r->catching = true;
    for (int seq = from + 1; seq <= sent; seq++) {
        colyseus_schema_t* inp = colyseus_input_handle_at(r->input, seq);
        if (inp != NULL) run_step(r, seq, inp);
    }
    r->catching = false;
    r->predicted_seq = sent;

    reconcile_settle(r, acked);
}

/* ── public API ──────────────────────────────────────────────────────── */

colyseus_reconciler_t* colyseus_reconciler_create(
    colyseus_schema_t* truth,
    const colyseus_schema_vtable_t* vtable,
    colyseus_input_handle_t* input,
    colyseus_room_clock_t* clock,
    colyseus_reconciler_step_fn step,
    const colyseus_reconciler_options_t* options) {
    bool manual = options && options->manual_step;
    if (!truth || !vtable || !input || (!step && !manual)) return NULL;

    colyseus_reconciler_t* r = calloc(1, sizeof(colyseus_reconciler_t));
    r->truth = truth;
    r->vtable = vtable;
    r->input = input;
    r->clock = clock;
    r->step = step;
    r->manual = manual;
    r->pump_acked = -1;
    if (options) {
        r->on_reconcile = options->on_reconcile;
        r->userdata = options->userdata;
    }

    /* fixed step: explicit > handle-advertised > stepSeconds; fail otherwise */
    double step_ms = options && options->step_ms > 0 ? options->step_ms : 0;
    if (step_ms <= 0) {
        int tick_rate = colyseus_input_handle_tick_rate(input);
        if (tick_rate > 0) step_ms = 1000.0 / tick_rate;
    }
    if (step_ms <= 0 && options && options->step_seconds > 0) step_ms = options->step_seconds * 1000;
    if (step_ms <= 0) { free(r); return NULL; } /* a wrong dt silently diverges */
    r->step_ms = step_ms;

    double dt = options && options->step_seconds > 0 ? options->step_seconds : 0;
    if (dt <= 0) {
        int tick_rate = colyseus_input_handle_tick_rate(input);
        dt = tick_rate > 0 ? 1.0 / tick_rate : step_ms / 1000;
    }
    int sub_steps = options && options->sub_steps > 1 ? options->sub_steps : colyseus_input_handle_sub_steps(input);
    if (sub_steps < 1) sub_steps = 1;

    /* smoothing default: the server's correction cadence, else 20 */
    if (options && options->smoothing >= 0) {
        r->smoothing = options->smoothing;
    } else {
        int patch_rate = colyseus_input_handle_patch_rate(input);
        r->smoothing = patch_rate > 0 ? 1000.0 / patch_rate : 20;
    }
    r->snap_threshold = options && options->snap > 0 ? options->snap : 0;

    /* resolve the field view: explicit names, or every numeric/boolean field */
    const char* const* names = options ? options->fields : NULL;
    int name_count = options ? options->field_count : 0;
    int declared = predict_vt_count(vtable);
    r->fields = calloc((size_t)(declared > 0 ? declared : 1), sizeof(recon_field_t));
    for (int i = 0; i < declared; i++) {
        predict_fref_t field;
        if (!predict_vt_at(vtable, i, &field)) continue;
        bool scalar = predict_fref_scalar(&field);
        if (names != NULL) {
            bool listed = false;
            for (int k = 0; k < name_count; k++) {
                if (strcmp(names[k], field.name) == 0) { listed = true; break; }
            }
            if (!listed) continue;
            if (!scalar) { free(r->fields); free(r); return NULL; } /* unsupported field */
        } else if (!scalar) {
            continue;
        }
        recon_field_t* rf = &r->fields[r->field_count++];
        rf->type = field.type;
        rf->offset = field.offset;
        rf->index = field.index;
        rf->name = field.name;
        rf->numeric = field.type != COLYSEUS_FIELD_BOOLEAN;
    }
    if (r->field_count == 0) { free(r->fields); free(r); return NULL; }

    r->error = calloc(r->field_count, sizeof(double));
    r->prev = calloc(r->field_count, sizeof(double));
    r->rendered_before = calloc(r->field_count, sizeof(double));
    r->last_correction = calloc(r->field_count, sizeof(double));

    /* the predicted mirror: a fresh instance seeded from truth */
    r->mirror = predict_instance_create(vtable);
    if (!r->mirror) {
        free(r->error); free(r->prev); free(r->rendered_before);
        free(r->last_correction); free(r->fields); free(r);
        return NULL;
    }
    r->mirror->__vtable = vtable;
    adopt_truth(r);
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) r->prev[i] = read_num(r->mirror, &r->fields[i]);
    }

    r->history_size = colyseus_input_handle_replay_buffer_size(input);
    if (r->history_size <= 0) r->history_size = 64;
    r->history = calloc((size_t)r->history_size * r->field_count, sizeof(double));
    r->history_seq = malloc((size_t)r->history_size * sizeof(double));
    for (int i = 0; i < r->history_size; i++) r->history_seq[i] = -1;
    r->memos = calloc(r->history_size, sizeof(memo_slot_t));
    memos_clear(r);

    r->ctx.dt = dt;
    r->ctx.dt_ms = step_ms;
    r->ctx.sub_steps = sub_steps;
    r->ctx.sub_dt = dt / sub_steps;
    r->ctx.sub_dt_ms = step_ms / sub_steps;
    r->ctx._memo_backing = r;

    r->last_acked = colyseus_input_handle_last_processed(input);
    r->last_epoch = colyseus_input_handle_epoch(input);
    r->predicted_seq = colyseus_input_handle_sent_count(input);
    /* manual mode pumps live steps itself — no eager step at send() */
    r->send_subscription = r->manual ? -1
        : colyseus_input_handle_on_send(input, on_send_hook, r);
    return r;
}

void colyseus_reconciler_free(colyseus_reconciler_t* r) {
    if (!r) return;
    if (r->driver) colyseus_predict_undrive(r->driver, r);
    if (r->send_subscription >= 0) colyseus_input_handle_off_send(r->input, r->send_subscription);
    if (r->mirror) r->vtable->destroy(r->mirror);
    if (r->sim) {
        for (int i = 0; i < r->sim->part_count; i++) {
            sim_part_t* part = &r->sim->parts[i];
            if (part->mirror) part->vtable->destroy(part->mirror);
            free(part->fields);
        }
        free(r->sim->pose_keys);
        free(r->sim->cur_pose);
        free(r->sim->parts);
        free(r->sim);
    }
    free(r->memos);
    free(r->history_seq);
    free(r->history);
    free(r->last_correction);
    free(r->rendered_before);
    free(r->prev);
    free(r->error);
    free(r->fields);
    free(r);
}

colyseus_schema_t* colyseus_reconciler_state(colyseus_reconciler_t* r) {
    return r->mirror;
}

void colyseus_reconciler_tick(colyseus_reconciler_t* r, double now) {
    double dt = r->has_last_tick ? now - r->last_tick : 0;
    r->has_last_tick = true;
    r->last_tick = now;
    if (dt > 0 && r->step_ms > 0) r->render_acc += dt;

    /* follow the handle's reset (reconnect) BEFORE the ack poll */
    int epoch = colyseus_input_handle_epoch(r->input);
    if (epoch != r->last_epoch) {
        r->last_epoch = epoch;
        colyseus_reconciler_reset(r);
    }

    int acked = colyseus_input_handle_last_processed(r->input);
    if (acked > r->last_acked) {
        r->last_acked = acked;
        if (r->manual) r->pump_acked = acked;   /* reconcile runs at the pump */
        else reconcile(r, acked);
    }

    if (dt <= 0) return;
    if (r->manual && r->pump_acked >= 0) {
        /* preserve the auto path's rebase-then-decay order: defer to pump_end */
        r->pump_decay_dt += dt;
        return;
    }
    decay_error(r, dt);
}

double colyseus_reconciler_value(colyseus_reconciler_t* r, const char* field) {
    for (int i = 0; i < r->field_count; i++) {
        if (strcmp(r->fields[i].name, field) != 0) continue;
        double current = cur_value(r, i);
        if (!r->fields[i].numeric) return current;
        double smoothed = current + r->error[i];
        double p = r->prev[i];
        return p + (smoothed - p) * render_alpha(r);
    }
    /* Not a reconciled field: NAN, never a plausible-looking 0. */
    return NAN;
}

void colyseus_reconciler_reset(colyseus_reconciler_t* r) {
    adopt_truth(r);
    if (r->sim) sim_refresh_pose(r);
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) {
            r->prev[i] = cur_value(r, i);
            r->error[i] = 0;
        }
    }
    for (int i = 0; i < r->history_size; i++) r->history_seq[i] = -1;
    colyseus_drift_reset(&r->drift);
    r->replay_from = colyseus_input_handle_sent_count(r->input);
    r->predicted_seq = r->replay_from;
    r->last_acked = colyseus_input_handle_last_processed(r->input);
    r->render_acc = 0;
    r->pump_acked = -1;
    r->pump_decay_dt = 0;
    r->pump_phase = 0;
    r->pump_step_open = false;
    memos_clear(r);
}

/* ── manual pump (see reconciler.h) ──────────────────────────────────── */

static void pump_apply_deferred_decay(colyseus_reconciler_t* r) {
    if (r->pump_decay_dt <= 0) return;
    decay_error(r, r->pump_decay_dt);
    r->pump_decay_dt = 0;
}

int colyseus_reconciler_pump_begin(colyseus_reconciler_t* r) {
    if (!r || !r->manual) return 0;
    /* a phase the host abandoned (missed pump_end) self-heals instead of
     * freezing every future drain */
    if (r->pump_phase != 0) colyseus_reconciler_pump_end(r);

    if (r->pump_acked >= 0) {
        int acked = r->pump_acked;
        if (reconcile_short_circuit(r, acked)) {
            r->pump_acked = -1;
            pump_apply_deferred_decay(r);
            /* matched — nothing replays; fall through to live catch-up */
        } else {
            int from = acked > r->replay_from ? acked : r->replay_from;
            /* replay ONLY seqs that ran live (auto keeps predicted_seq==sent
             * via the send hook; the pump must not label a never-stepped
             * input a replay — its memo would never compute and settle would
             * rebase against a step auto ran after settling) */
            int end = r->predicted_seq > from ? r->predicted_seq : from;
            reconcile_adopt(r);
            if (from >= end) {
                /* nothing predicted past the ack: settle now; inputs sent but
                 * never stepped stay for the live phase */
                if (from > r->predicted_seq) r->predicted_seq = from;
                reconcile_settle(r, acked);
                r->pump_acked = -1;
                pump_apply_deferred_decay(r);
            } else {
                r->pump_seq = from + 1;
                r->pump_end_seq = end;
                r->ctx.is_replay = true;
                r->catching = true;
                r->pump_phase = 1;
                return end - from;
            }
        }
    }

    int sent = colyseus_input_handle_sent_count(r->input);
    if (r->predicted_seq < sent) {
        r->pump_seq = r->predicted_seq + 1;
        r->pump_end_seq = sent;
        r->ctx.is_replay = false;
        r->catching = true;
        r->pump_phase = 2;
        return sent - r->predicted_seq;
    }
    return 0;
}

const colyseus_schema_t* colyseus_reconciler_pump_next(colyseus_reconciler_t* r,
                                                       const colyseus_step_ctx_t** out_ctx) {
    if (!r || r->pump_phase == 0 || r->pump_step_open) return NULL;
    while (r->pump_seq <= r->pump_end_seq) {
        colyseus_schema_t* inp = colyseus_input_handle_at(r->input, r->pump_seq);
        if (inp == NULL) {
            /* aged out of the ring — live catch-up still consumes the seq */
            if (r->pump_phase == 2) r->predicted_seq = r->pump_seq;
            r->pump_seq++;
            continue;
        }
        if (r->pump_phase == 2) snapshot_prev(r);
        step_ctx_load(r, r->pump_seq);
        r->pump_step_open = true;
        if (out_ctx) *out_ctx = &r->ctx;
        return inp;
    }
    return NULL;
}

void colyseus_reconciler_pump_commit(colyseus_reconciler_t* r) {
    if (!r || !r->pump_step_open) return;
    step_record(r, r->pump_seq);
    if (r->pump_phase == 2) {
        consume_render_step(r);
        r->predicted_seq = r->pump_seq;
    }
    r->pump_step_open = false;
    r->pump_seq++;
}

void colyseus_reconciler_pump_end(colyseus_reconciler_t* r) {
    if (!r || r->pump_phase == 0) return;
    r->pump_step_open = false;   /* an uncommitted served step is abandoned */
    r->catching = false;
    if (r->pump_phase == 1) {
        r->predicted_seq = r->pump_end_seq;
        reconcile_settle(r, r->pump_acked);
        r->pump_acked = -1;
        pump_apply_deferred_decay(r);
    }
    r->pump_phase = 0;
}

int colyseus_reconciler_pending_count(const colyseus_reconciler_t* r) {
    return colyseus_input_handle_pending_count(r->input);
}

double colyseus_reconciler_step_ms(const colyseus_reconciler_t* r) { return r->step_ms; }
const colyseus_drift_t* colyseus_reconciler_drift(const colyseus_reconciler_t* r) { return &r->drift; }
double colyseus_reconciler_last_correction_mag(const colyseus_reconciler_t* r) { return r->last_correction_mag; }
int colyseus_reconciler_reconcile_seq(const colyseus_reconciler_t* r) { return r->reconcile_seq; }

double colyseus_reconciler_last_correction(const colyseus_reconciler_t* r, const char* field) {
    for (int i = 0; i < r->field_count; i++) {
        if (strcmp(r->fields[i].name, field) == 0) return r->last_correction[i];
    }
    return 0;
}

void colyseus_reconciler_set_driver_(colyseus_reconciler_t* r, struct colyseus_predict* driver) {
    if (r) r->driver = driver;
}

int colyseus_reconciler_bound_fields_(const colyseus_reconciler_t* r,
                                      colyseus_bound_field_t* out, int max) {
    if (!r) return 0;
    int n = 0;
    if (!r->sim) {
        /* Flat face: one mirrored instance, and the pose key IS the field name. */
        if (!r->truth) return 0;
        for (int i = 0; i < r->field_count; i++) {
            if (!r->fields[i].numeric) continue;   /* booleans copy, never smooth */
            if (out && n < max) {
                out[n].source = r->truth;
                out[n].field = r->fields[i].name;
                out[n].pose_key = r->fields[i].name;
            }
            n++;
        }
        return n;
    }
    /* Composite face: the SOURCE per part, not the mirror that replaced it —
     * that is the instance the app still holds and reads through. */
    for (int i = 0; i < r->sim->part_count; i++) {
        const sim_part_t* part = &r->sim->parts[i];
        if (!part->source) continue;              /* opaque part — nothing to key on */
        for (int k = 0; k < part->field_count; k++) {
            if (!part->fields[k].numeric) continue;
            if (out && n < max) {
                out[n].source = part->source;
                out[n].field = part->fields[k].name;
                out[n].pose_key = r->sim->pose_keys[part->pose_base + k];
            }
            n++;
        }
    }
    return n;
}

int colyseus_step_memo_vec(const colyseus_step_ctx_t* ctx, const char* key,
    int (*compute)(double* out, void* userdata), void* userdata, double* out) {
    colyseus_reconciler_t* r = (colyseus_reconciler_t*)ctx->_memo_backing;
    if (!r || !key || !out) { return compute ? compute(out, userdata) : 0; }
    memo_slot_t* slot = &r->memos[ctx->tick % r->history_size];

    if (ctx->is_replay) {
        if (slot->seq != (double)ctx->tick) return 0;
        for (int i = 0; i < slot->count; i++) {
            if (strncmp(slot->entries[i].key, key, MEMO_KEY_MAX) != 0) continue;
            int n = slot->entries[i].count;
            for (int k = 0; k < n; k++) out[k] = slot->entries[i].values[k];
            return n;
        }
        return 0;
    }

    int n = compute(out, userdata);
    if (n > COLYSEUS_MEMO_VEC_MAX) n = COLYSEUS_MEMO_VEC_MAX;
    if (n <= 0) return 0;
    slot = memo_slot_for(r, ctx);
    for (int i = 0; i < slot->count; i++) {
        if (strncmp(slot->entries[i].key, key, MEMO_KEY_MAX) != 0) continue;
        slot->entries[i].count = n;
        for (int k = 0; k < n; k++) slot->entries[i].values[k] = out[k];
        return n;
    }
    if (slot->count < MEMO_KEYS_PER_SEQ) {
        memo_entry_t* e = &slot->entries[slot->count++];
        snprintf(e->key, MEMO_KEY_MAX, "%s", key);
        e->count = n;
        for (int k = 0; k < n; k++) e->values[k] = out[k];
    }
    return n;
}

/* @internal — events.c reaches the emitting handle through the step ctx. */
colyseus_input_handle_t* colyseus_reconciler_input_(const void* reconciler) {
    return ((const colyseus_reconciler_t*)reconciler)->input;
}

/* ════════════════════════════════════════════════════════════════════════
 * SimReconciler — the composite face over the SAME rollback engine.
 *
 * The only differences from the flat face live in the hooks above:
 * adopt_truth() pulls every bound mirror from its source, run_step() drives the
 * world step and refreshes the pose, truth_matches_at() is always false (a
 * composite sim has no wire-precision short-circuit), and cur_value() reads the
 * pose instead of a mirror field. Everything else — catchUp, reconcile, error
 * decay, snap, drift, memos — is shared verbatim.
 * ════════════════════════════════════════════════════════════════════════ */

static void sim_refresh_pose(colyseus_reconciler_t* r) {
    colyseus_sim_world_t* w = r->sim;
    for (int p = 0; p < w->part_count; p++) {
        sim_part_t* part = &w->parts[p];
        if (!part->mirror) continue;
        for (int f = 0; f < part->field_count; f++) {
            w->cur_pose[part->pose_base + f] = read_num(part->mirror, &part->fields[f]);
        }
    }
}

static void sim_adopt_bound(colyseus_reconciler_t* r) {
    colyseus_sim_world_t* w = r->sim;
    for (int p = 0; p < w->part_count; p++) {
        sim_part_t* part = &w->parts[p];
        if (!part->mirror) continue;
        for (int f = 0; f < part->field_count; f++) {
            write_num(part->mirror, &part->fields[f], read_num(part->source, &part->fields[f]));
        }
    }
}

void* colyseus_sim_world_part(colyseus_sim_world_t* world, const char* name) {
    if (!world || !name) return NULL;
    for (int i = 0; i < world->part_count; i++) {
        if (strcmp(world->parts[i].name, name) != 0) continue;
        return world->parts[i].mirror ? (void*)world->parts[i].mirror : world->parts[i].opaque;
    }
    return NULL;
}

colyseus_sim_world_t* colyseus_sim_reconciler_world(colyseus_reconciler_t* r) {
    return r ? r->sim : NULL;
}

colyseus_reconciler_t* colyseus_sim_reconciler_create(
    colyseus_input_handle_t* input,
    colyseus_room_clock_t* clock,
    colyseus_sim_step_fn step,
    const colyseus_sim_reconciler_options_t* options) {
    if (!input || !options || options->part_count <= 0) return NULL;
    if (!step && !options->manual_step) return NULL;

    colyseus_reconciler_t* r = calloc(1, sizeof(colyseus_reconciler_t));
    r->send_subscription = -1;   /* the early-error paths run through free() */
    r->input = input;
    r->clock = clock;
    r->manual = options->manual_step;
    r->pump_acked = -1;
    r->on_reconcile = options->on_reconcile;
    r->userdata = options->userdata;

    /* fixed step: explicit > handle-advertised > stepSeconds; fail otherwise */
    double step_ms = options->step_ms > 0 ? options->step_ms : 0;
    if (step_ms <= 0) {
        int tick_rate = colyseus_input_handle_tick_rate(input);
        if (tick_rate > 0) step_ms = 1000.0 / tick_rate;
    }
    if (step_ms <= 0 && options->step_seconds > 0) step_ms = options->step_seconds * 1000;
    if (step_ms <= 0) { free(r); return NULL; }
    r->step_ms = step_ms;

    double dt = options->step_seconds > 0 ? options->step_seconds : 0;
    if (dt <= 0) {
        int tick_rate = colyseus_input_handle_tick_rate(input);
        dt = tick_rate > 0 ? 1.0 / tick_rate : step_ms / 1000;
    }
    int sub_steps = options->sub_steps > 1 ? options->sub_steps : colyseus_input_handle_sub_steps(input);
    if (sub_steps < 1) sub_steps = 1;

    if (options->smoothing >= 0) {
        r->smoothing = options->smoothing;
    } else {
        int patch_rate = colyseus_input_handle_patch_rate(input);
        r->smoothing = patch_rate > 0 ? 1000.0 / patch_rate : 20;
    }
    r->snap_threshold = options->snap > 0 ? options->snap : 0;

    colyseus_sim_world_t* w = calloc(1, sizeof(colyseus_sim_world_t));
    w->step = step;
    w->adopt = options->adopt;
    w->userdata = options->userdata;
    w->part_count = options->part_count;
    w->parts = calloc((size_t)w->part_count, sizeof(sim_part_t));
    r->sim = w;

    /* Auto-binding: a part with a `source` gets a MIRROR of the same vtable and
     * contributes "<part>.<field>" pose keys; a part without one is opaque and
     * is only ever restored by the app's adopt(). */
    int pose_count = 0, bound = 0;
    for (int i = 0; i < w->part_count; i++) {
        const colyseus_sim_part_t* spec = &options->parts[i];
        sim_part_t* part = &w->parts[i];
        if (!spec->name) { colyseus_reconciler_free(r); return NULL; }
        snprintf(part->name, SIM_NAME_MAX, "%s", spec->name);
        part->opaque = spec->opaque;
        part->pose_base = pose_count;
        if (!spec->source) continue;
        if (!spec->vtable) {
            colyseus_reconciler_free(r); return NULL;
        }
        part->source = spec->source;
        part->vtable = spec->vtable;
        int part_declared = predict_vt_count(spec->vtable);
        part->fields = calloc((size_t)(part_declared > 0 ? part_declared : 1), sizeof(recon_field_t));
        for (int f = 0; f < part_declared; f++) {
            predict_fref_t field;
            if (!predict_vt_at(spec->vtable, f, &field)) continue;
            if (!predict_fref_scalar(&field) || field.type == COLYSEUS_FIELD_BOOLEAN) continue;
            recon_field_t* rf = &part->fields[part->field_count++];
            rf->type = field.type;
            rf->offset = field.offset;
            rf->index = field.index;
            rf->name = field.name;
            rf->numeric = true;
        }
        /* A bound entry with no scalar fields has nothing to predict. */
        if (part->field_count == 0) { colyseus_reconciler_free(r); return NULL; }
        part->mirror = predict_instance_create(spec->vtable);
        if (!part->mirror) { colyseus_reconciler_free(r); return NULL; }
        part->mirror->__vtable = spec->vtable;
        pose_count += part->field_count;
        bound++;
    }
    /* Nothing bound and no adopt() = no restore point for the replay. */
    if (pose_count == 0 || (bound == 0 && !options->adopt)) {
        colyseus_reconciler_free(r); return NULL;
    }

    /* The pose IS the reconciled field view: one entry per bound numeric field. */
    r->field_count = pose_count;
    r->fields = calloc((size_t)pose_count, sizeof(recon_field_t));
    w->pose_keys = calloc((size_t)pose_count, SIM_POSE_KEY_MAX);
    w->cur_pose = calloc((size_t)pose_count, sizeof(double));
    for (int i = 0; i < w->part_count; i++) {
        sim_part_t* part = &w->parts[i];
        for (int f = 0; f < part->field_count; f++) {
            int k = part->pose_base + f;
            snprintf(w->pose_keys[k], SIM_POSE_KEY_MAX, "%s.%s", part->name, part->fields[f].name);
            r->fields[k].name = w->pose_keys[k];
            r->fields[k].numeric = true;
        }
    }

    r->error = calloc((size_t)pose_count, sizeof(double));
    r->prev = calloc((size_t)pose_count, sizeof(double));
    r->rendered_before = calloc((size_t)pose_count, sizeof(double));
    r->last_correction = calloc((size_t)pose_count, sizeof(double));

    adopt_truth(r);
    sim_refresh_pose(r);
    for (int i = 0; i < pose_count; i++) r->prev[i] = w->cur_pose[i];

    /* No wire-precision ring here, but the memo store is still keyed by seq. */
    r->history_size = colyseus_input_handle_replay_buffer_size(input);
    if (r->history_size <= 0) r->history_size = 64;
    r->history_seq = malloc((size_t)r->history_size * sizeof(double));
    for (int i = 0; i < r->history_size; i++) r->history_seq[i] = -1;
    r->memos = calloc((size_t)r->history_size, sizeof(memo_slot_t));
    memos_clear(r);

    r->ctx.dt = dt;
    r->ctx.dt_ms = step_ms;
    r->ctx.sub_steps = sub_steps;
    r->ctx.sub_dt = dt / sub_steps;
    r->ctx.sub_dt_ms = step_ms / sub_steps;
    r->ctx._memo_backing = r;

    r->last_acked = colyseus_input_handle_last_processed(input);
    r->last_epoch = colyseus_input_handle_epoch(input);
    r->predicted_seq = colyseus_input_handle_sent_count(input);
    r->send_subscription = r->manual ? -1
        : colyseus_input_handle_on_send(input, on_send_hook, r);
    return r;
}
