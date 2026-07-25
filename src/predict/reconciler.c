#include "colyseus/predict/reconciler.h"
#include "colyseus/schema/dynamic_schema.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/*
 * Reconcile/decay math must be bit-identical to the JS reference (fixtures
 * compare float64 strictly where exp() isn't involved) — see quantize.c /
 * room_clock.c for the clang ARM64 FMA story.
 */
#pragma STDC FP_CONTRACT OFF

/* ── memo store (numbers; NAN = none) ────────────────────────────────── */

#define MEMO_KEYS_PER_SEQ 8
#define MEMO_KEY_MAX 24

typedef struct {
    char key[MEMO_KEY_MAX];
    double value;
} memo_entry_t;

typedef struct {
    double seq; /* -1 = empty */
    int count;
    memo_entry_t entries[MEMO_KEYS_PER_SEQ];
} memo_slot_t;

/* ── field view ──────────────────────────────────────────────────────── */

typedef struct {
    colyseus_field_type_t type;
    size_t offset;
    const char* name;
    bool numeric; /* number-family (booleans reconcile verbatim, not smoothed) */
} recon_field_t;

struct colyseus_reconciler {
    colyseus_schema_t* truth;
    const colyseus_schema_vtable_t* vtable;
    colyseus_input_handle_t* input;
    colyseus_room_clock_t* clock;
    colyseus_reconciler_step_fn step;
    void (*on_reconcile)(int acked, void* userdata);
    void* userdata;

    colyseus_schema_t* mirror; /* the predicted state (owned) */

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
};

/* ── value access on schema instances (static offsets) ───────────────── */

static double read_num(const colyseus_schema_t* instance, const recon_field_t* f) {
    const void* p = (const char*)instance + f->offset;
    switch (f->type) {
        case COLYSEUS_FIELD_BOOLEAN: return *(const bool*)p ? 1 : 0;
        case COLYSEUS_FIELD_FLOAT32: return (double)*(const float*)p;
        case COLYSEUS_FIELD_INT8:    return (double)*(const int8_t*)p;
        case COLYSEUS_FIELD_UINT8:   return (double)*(const uint8_t*)p;
        case COLYSEUS_FIELD_INT16:   return (double)*(const int16_t*)p;
        case COLYSEUS_FIELD_UINT16:  return (double)*(const uint16_t*)p;
        case COLYSEUS_FIELD_INT32:   return (double)*(const int32_t*)p;
        case COLYSEUS_FIELD_UINT32:  return (double)*(const uint32_t*)p;
        case COLYSEUS_FIELD_INT64:   return (double)*(const int64_t*)p;
        case COLYSEUS_FIELD_UINT64:  return (double)*(const uint64_t*)p;
        default:                     return *(const double*)p; /* NUMBER / FLOAT64 / QUANTIZED */
    }
}

static void write_num(colyseus_schema_t* instance, const recon_field_t* f, double v) {
    void* p = (char*)instance + f->offset;
    switch (f->type) {
        case COLYSEUS_FIELD_BOOLEAN: *(bool*)p = v != 0; break;
        case COLYSEUS_FIELD_FLOAT32: *(float*)p = (float)v; break;
        case COLYSEUS_FIELD_INT8:    *(int8_t*)p = (int8_t)v; break;
        case COLYSEUS_FIELD_UINT8:   *(uint8_t*)p = (uint8_t)v; break;
        case COLYSEUS_FIELD_INT16:   *(int16_t*)p = (int16_t)v; break;
        case COLYSEUS_FIELD_UINT16:  *(uint16_t*)p = (uint16_t)v; break;
        case COLYSEUS_FIELD_INT32:   *(int32_t*)p = (int32_t)v; break;
        case COLYSEUS_FIELD_UINT32:  *(uint32_t*)p = (uint32_t)v; break;
        case COLYSEUS_FIELD_INT64:   *(int64_t*)p = (int64_t)v; break;
        case COLYSEUS_FIELD_UINT64:  *(uint64_t*)p = (uint64_t)v; break;
        default:                     *(double*)p = v; break;
    }
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

static void run_step(colyseus_reconciler_t* r, int seq, const colyseus_schema_t* command) {
    r->ctx.tick = seq;
    double raw = colyseus_input_handle_reckon_time_at(r->input, seq);
    r->ctx.lag_comp_active = raw > 0;
    r->ctx.reckon_time = raw > 0 ? raw
        : (r->clock ? colyseus_room_clock_server_now(r->clock) : 0);
    r->step(&r->ctx, r->mirror, command, r->userdata);

    /* record this seq's predicted state (live and replay alike) */
    int slot = seq % r->history_size;
    double* base = &r->history[(size_t)slot * r->field_count];
    for (int i = 0; i < r->field_count; i++) base[i] = read_num(r->mirror, &r->fields[i]);
    r->history_seq[slot] = (double)seq;
}

static void snapshot_prev(colyseus_reconciler_t* r) {
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) r->prev[i] = read_num(r->mirror, &r->fields[i]) + r->error[i];
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
            /* consume one step of the render clock, resyncing into [0, stepMs) */
            r->render_acc -= r->step_ms;
            if (r->render_acc < 0) r->render_acc = 0;
            else if (r->render_acc >= r->step_ms) r->render_acc = fmod(r->render_acc, r->step_ms);
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
    for (int i = 0; i < r->field_count; i++) {
        write_num(r->mirror, &r->fields[i], read_num(r->truth, &r->fields[i]));
    }
}

/* Wire-precision compare of the ring prediction at `acked` vs decoded truth. */
static bool truth_matches_at(colyseus_reconciler_t* r, int acked) {
    int slot = acked % r->history_size;
    if (r->history_seq[slot] != (double)acked) return false;
    const double* base = &r->history[(size_t)slot * r->field_count];
    for (int i = 0; i < r->field_count; i++) {
        if (wire_round(&r->fields[i], base[i]) != read_num(r->truth, &r->fields[i])) return false;
    }
    return true;
}

static void reconcile(colyseus_reconciler_t* r, int acked) {
    if (truth_matches_at(r, acked)) {
        for (int i = 0; i < r->field_count; i++) r->last_correction[i] = 0;
        r->last_correction_mag = 0;
        colyseus_drift_update(&r->drift, 0);
        r->reconcile_seq++;
        memos_prune(r, acked);
        if (r->on_reconcile) r->on_reconcile(acked, r->userdata);
        return;
    }

    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) {
            r->rendered_before[i] = read_num(r->mirror, &r->fields[i]) + r->error[i];
        }
    }

    adopt_truth(r);

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

    /* re-base the error so the rendered pose is unchanged at this instant */
    bool hard = r->smoothing <= 0;
    double mag = 0;
    for (int i = 0; i < r->field_count; i++) {
        if (!r->fields[i].numeric) { r->last_correction[i] = 0; continue; }
        double correction = r->rendered_before[i] - read_num(r->mirror, &r->fields[i]);
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
            r->prev[i] = read_num(r->mirror, &r->fields[i]);
        }
    }
    r->reconcile_seq++;
    r->last_correction_mag = mag;
    if (!popped) colyseus_drift_update(&r->drift, mag);

    memos_prune(r, acked);
    if (r->on_reconcile) r->on_reconcile(acked, r->userdata);
}

/* ── public API ──────────────────────────────────────────────────────── */

colyseus_reconciler_t* colyseus_reconciler_create(
    colyseus_schema_t* truth,
    const colyseus_schema_vtable_t* vtable,
    colyseus_input_handle_t* input,
    colyseus_room_clock_t* clock,
    colyseus_reconciler_step_fn step,
    const colyseus_reconciler_options_t* options) {
    if (!truth || !vtable || !input || !step) return NULL;
    /* v1: static vtables only (a predicted state is a codegen'd struct) */
    if (colyseus_vtable_is_dynamic(vtable)) return NULL;

    colyseus_reconciler_t* r = calloc(1, sizeof(colyseus_reconciler_t));
    r->truth = truth;
    r->vtable = vtable;
    r->input = input;
    r->clock = clock;
    r->step = step;
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
    r->fields = calloc(vtable->field_count, sizeof(recon_field_t));
    for (int i = 0; i < vtable->field_count; i++) {
        const colyseus_field_t* field = &vtable->fields[i];
        bool scalar = field->type != COLYSEUS_FIELD_REF && field->type != COLYSEUS_FIELD_ARRAY
            && field->type != COLYSEUS_FIELD_MAP && field->type != COLYSEUS_FIELD_STRING;
        if (names != NULL) {
            bool listed = false;
            for (int k = 0; k < name_count; k++) {
                if (strcmp(names[k], field->name) == 0) { listed = true; break; }
            }
            if (!listed) continue;
            if (!scalar) { free(r->fields); free(r); return NULL; } /* unsupported field */
        } else if (!scalar) {
            continue;
        }
        recon_field_t* rf = &r->fields[r->field_count++];
        rf->type = field->type;
        rf->offset = field->offset;
        rf->name = field->name;
        rf->numeric = field->type != COLYSEUS_FIELD_BOOLEAN;
    }
    if (r->field_count == 0) { free(r->fields); free(r); return NULL; }

    r->error = calloc(r->field_count, sizeof(double));
    r->prev = calloc(r->field_count, sizeof(double));
    r->rendered_before = calloc(r->field_count, sizeof(double));
    r->last_correction = calloc(r->field_count, sizeof(double));

    /* the predicted mirror: a fresh instance seeded from truth */
    r->mirror = vtable->create();
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
    r->send_subscription = colyseus_input_handle_on_send(input, on_send_hook, r);
    return r;
}

void colyseus_reconciler_free(colyseus_reconciler_t* r) {
    if (!r) return;
    colyseus_input_handle_off_send(r->input, r->send_subscription);
    if (r->mirror) r->vtable->destroy(r->mirror);
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
        reconcile(r, acked);
    }

    if (dt <= 0) return;
    double k = r->smoothing <= 0 ? 1 : 1 - exp(-r->smoothing * dt / 1000);
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) r->error[i] -= r->error[i] * k;
    }
}

double colyseus_reconciler_value(colyseus_reconciler_t* r, const char* field) {
    for (int i = 0; i < r->field_count; i++) {
        if (strcmp(r->fields[i].name, field) != 0) continue;
        double current = read_num(r->mirror, &r->fields[i]);
        if (!r->fields[i].numeric) return current;
        double smoothed = current + r->error[i];
        double p = r->prev[i];
        return p + (smoothed - p) * render_alpha(r);
    }
    return 0;
}

void colyseus_reconciler_reset(colyseus_reconciler_t* r) {
    adopt_truth(r);
    for (int i = 0; i < r->field_count; i++) {
        if (r->fields[i].numeric) {
            r->prev[i] = read_num(r->mirror, &r->fields[i]);
            r->error[i] = 0;
        }
    }
    for (int i = 0; i < r->history_size; i++) r->history_seq[i] = -1;
    colyseus_drift_reset(&r->drift);
    r->replay_from = colyseus_input_handle_sent_count(r->input);
    r->predicted_seq = r->replay_from;
    r->last_acked = colyseus_input_handle_last_processed(r->input);
    r->render_acc = 0;
    memos_clear(r);
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
