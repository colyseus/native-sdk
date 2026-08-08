#include "colyseus/predict/predict.h"
#include "colyseus/predict/sim_reconciler.h"
#include "colyseus/room.h"
#include "colyseus/schema.h"
#include "colyseus/schema/dynamic_schema.h"
#include "field_access.h"
#include "uthash.h"

#include <stdio.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Smoothing math tracks the JS reference bit-for-bit where exp() isn't
 * involved — keep clang ARM64 from fusing into FMA (see room_clock.c). */
#pragma STDC FP_CONTRACT OFF

#define RING_CAP 16
#define GAP_RESUME_MULT 3.0
#define GAP_RESUME_PATCH_MULT 1.5
#define GAP_RESUME_MAX_MS 250.0

/* ── slot: one tracked (instance, field) ─────────────────────────────── */

typedef struct predict_slot {
    char* field;                    /* owned */
    colyseus_schema_t* instance;
    predict_fref_t fref;            /* resolved storage (either model) */
    colyseus_field_type_t type;

    colyseus_predict_field_options_t opts;

    double v1;                      /* latest sample (raw mirror) */
    double aux_v;                   /* damped / extrapolate smoothing state */
    double aux_t;
    bool aux_seeded;

    /* snapshot ring: (t, v) pairs, overwrite-oldest */
    double ring_t[RING_CAP];
    double ring_v[RING_CAP];
    int ring_head;                  /* next write position */
    int ring_count;

    colyseus_callback_handle_t listen_handle;
    void* listen_ctx;               /* owned (the listener's userdata) */

    /* Controller-owned slot: non-NULL ctrl routes reads at this (instance,
     * field) to the reconciler's pose instead of a smoothing curve. `stash` is
     * the passive slot this displaced — restored when the controller goes. */
    colyseus_reconciler_t* ctrl;
    char* pose_key;                 /* owned */
    struct predict_slot* stash;

    struct predict_slot* next;      /* per-instance chain */
} predict_slot_t;

/* ── reckon sim: one dead-reckoned instance ──────────────────────────── */

typedef struct predict_sim {
    int ref_id;
    colyseus_schema_t* instance;
    const colyseus_schema_vtable_t* vtable;
    colyseus_schema_t* scratch;     /* owned; refilled per advance */
    colyseus_predict_step_fn step;
    void* userdata;
    double smoothing;
    double substep_ms;
    double snap;

    /* the reckoned field view (names borrowed from the vtable) */
    predict_fref_t* fields;
    int field_count;
    /* all scalar fields of the vtable (the scratch refill set) */
    predict_fref_t* copy_fields;
    int copy_count;

    double* smoothed;               /* displayed = out + offset */
    double* out;
    double* value_out;              /* value_at scratch */
    double* offset;
    double* out_prev;
    double* frame_vel;
    double last_base_t;             /* NAN until a clocked apply */
    double last_apply_time;         /* -INFINITY until first read */
    bool first_apply;
    /* Extra forward horizon on top of the snapshot age, in ms — the spawn
     * store's measured input lead. 0 for every other reckon. The other ports
     * pass a closure computing (age + lead); with no closures here the lead
     * is just added, which is the same number. */
    double lead_ms;

    struct predict_sim* next;
    UT_hash_handle hh;
} predict_sim_t;

/* refId → slot chain */
typedef struct {
    int ref_id;
    predict_slot_t* slots;
    UT_hash_handle hh;
} slot_bucket_t;

static void predict_bind_render_delay_fwd(colyseus_predict_t* p);

/* ── children driven by tick() (port of Predictor.driven) ────────────── */

typedef enum { DRIVEN_RECONCILER, DRIVEN_EVENTS, DRIVEN_SPAWNS } driven_kind_t;

typedef struct driven_child {
    driven_kind_t kind;
    void* ptr;
    struct driven_child* next;
} driven_child_t;

/* ── attach_all registrations (collection -> per-entry tracking) ─────── */

/* What the spawn-store collection callbacks need to reach: the store, and
 * (optionally) the reckon config to attach per confirmed entity. */
typedef struct spawns_bind_ctx {
    colyseus_predict_t* p;
    colyseus_spawns_t* spawns;
    bool reckon;
    const colyseus_schema_vtable_t* entry_vtable;
    char** fields;
    int field_count;
    colyseus_predict_step_fn step;
    double smoothing, substep_ms;
    void* userdata;
} spawns_bind_ctx_t;

typedef struct attach_all_ctx {
    colyseus_predict_t* p;
    char** fields;                  /* NULL = every numeric field */
    colyseus_predict_field_options_t* field_opts;  /* parallel to `fields` */
    int field_count;
    char* except_key;
    colyseus_predict_field_options_t opts;         /* the `fields == NULL` fallback */
    /* reckon variant */
    const colyseus_schema_vtable_t* entry_vtable;
    colyseus_predict_step_fn step;
    double smoothing, substep_ms, snap;
    void* userdata;
    /* The room owns the callbacks layer, so these MUST be removed when the
     * Predict dies or a later patch calls back into freed state. */
    colyseus_callback_handle_t on_add;
    colyseus_callback_handle_t on_remove;
    /* set only by bind_spawns; owned, freed with this attachment */
    struct spawns_bind_ctx* spawns_bind;
    struct attach_all_ctx* next;
} attach_all_ctx_t;

struct colyseus_predict {
    colyseus_callbacks_t* callbacks;   /* borrowed — the room owns it */
    colyseus_room_clock_t* clock;
    double render_time;
    slot_bucket_t* by_ref;
    predict_sim_t* sims;            /* uthash by ref_id */

    /* Room-wide fixed-step accumulator: elapsed render time -> whole input
     * steps due this frame. Separate from each controller's render clock. */
    double fixed_step_ms;           /* 0 = not adopted yet */
    double step_acc;
    double last_frame_now;
    bool has_last_frame;

    driven_child_t* driven;
    attach_all_ctx_t* attachments;

    /* Lag-comp binding: the delay remote entities are DRAWN at, pushed onto
     * the input handles of reconcilers this Predict spawned. */
    double lerp_delay;
    colyseus_input_handle_t* bound_input;
};

#define PREDICT_MAX_STEPS_PER_FRAME 5

/* Field access lives in field_access.h — one seam for both storage models. */

/* ── sample listener ─────────────────────────────────────────────────── */

typedef struct {
    colyseus_predict_t* p;
    predict_slot_t* slot;
} listen_ctx_t;

static void on_sample(void* current_value, void* previous_value, void* userdata) {
    (void)previous_value;
    listen_ctx_t* lc = (listen_ctx_t*)userdata;
    predict_slot_t* slot = lc->slot;
    colyseus_predict_t* p = lc->p;
    if (!current_value) return;

    /* the callbacks layer hands the raw storage pointer for the field */
    double current;
    switch (slot->type) {
        case COLYSEUS_FIELD_BOOLEAN: current = *(bool*)current_value ? 1 : 0; break;
        case COLYSEUS_FIELD_FLOAT32: current = (double)*(float*)current_value; break;
        case COLYSEUS_FIELD_INT8:    current = (double)*(int8_t*)current_value; break;
        case COLYSEUS_FIELD_UINT8:   current = (double)*(uint8_t*)current_value; break;
        case COLYSEUS_FIELD_INT16:   current = (double)*(int16_t*)current_value; break;
        case COLYSEUS_FIELD_UINT16:  current = (double)*(uint16_t*)current_value; break;
        case COLYSEUS_FIELD_INT32:   current = (double)*(int32_t*)current_value; break;
        case COLYSEUS_FIELD_UINT32:  current = (double)*(uint32_t*)current_value; break;
        case COLYSEUS_FIELD_INT64:   current = (double)*(int64_t*)current_value; break;
        case COLYSEUS_FIELD_UINT64:  current = (double)*(uint64_t*)current_value; break;
        default:                     current = *(double*)current_value; break;
    }

    /* server-time axis when the clock is synced; local arrival otherwise */
    double now = (p->clock && colyseus_room_clock_last_server_time(p->clock) > 0)
        ? colyseus_room_clock_last_server_time(p->clock)
        : colyseus_room_clock_now(NULL);

    /* angle: fold onto the previous (continuous) value over the shortest arc */
    if (slot->opts.angle) {
        double prev = slot->v1;
        current = prev + atan2(sin(current - prev), cos(current - prev));
    }

    int head = slot->ring_head;
    int count = slot->ring_count;

    /* value-space teleport: empty the ring + snap the aux state */
    if (slot->opts.snap > 0 && count > 0 && fabs(current - slot->v1) > slot->opts.snap) {
        head = 0;
        count = 0;
        slot->aux_v = current;
    }

    double last_t1 = count == 0
        ? -INFINITY
        : slot->ring_t[head == 0 ? RING_CAP - 1 : head - 1];

    /* tick-snap arrival times onto a regular grid */
    double snap_t = now;
    double tick_interval = slot->opts.tick_interval;
    if (tick_interval > 0 && isfinite(last_t1)) {
        double elapsed = now - last_t1;
        double ticks = elapsed > 0 ? floor(elapsed / tick_interval + 0.5) : 1;
        if (ticks < 1) ticks = 1;
        snap_t = last_t1 + ticks * tick_interval;
        double cap = now + tick_interval;
        if (snap_t > cap) snap_t = cap;
    }

    slot->v1 = current;

    /* idle-resume gap collapse: inject a synthetic held sample so lerp
     * resumes over one normal interval instead of crawling across the gap */
    if (count >= 2 && isfinite(last_t1)) {
        int h1 = head == 0 ? RING_CAP - 1 : head - 1;
        int h2 = h1 == 0 ? RING_CAP - 1 : h1 - 1;
        double last_interval = last_t1 - slot->ring_t[h2];
        double patch_ms = p->clock ? colyseus_room_clock_patch_interval(p->clock) : 0;
        double span = patch_ms > 0 ? patch_ms : last_interval;
        double trigger = patch_ms > 0 ? GAP_RESUME_PATCH_MULT * patch_ms : GAP_RESUME_MULT * last_interval;
        if (span > 0 && (snap_t - last_t1) > trigger) {
            double resume_span = span < GAP_RESUME_MAX_MS ? span : GAP_RESUME_MAX_MS;
            slot->ring_t[head] = snap_t - resume_span;
            slot->ring_v[head] = slot->ring_v[h1]; /* previous (held) value */
            head = head + 1 >= RING_CAP ? 0 : head + 1;
            if (count < RING_CAP) count++;
        }
    }

    slot->ring_t[head] = snap_t;
    slot->ring_v[head] = current;
    slot->ring_head = head + 1 >= RING_CAP ? 0 : head + 1;
    slot->ring_count = count < RING_CAP ? count + 1 : count;
}

/* ── mode computers ──────────────────────────────────────────────────── */

static double compute_raw(const predict_slot_t* slot) {
    return slot->v1;
}

static double compute_damped(colyseus_predict_t* p, predict_slot_t* slot) {
    double now = p->render_time;
    double damping = slot->opts.damping;
    double dt_frame = now - slot->aux_t;
    slot->aux_t = now;
    if (dt_frame > 0) {
        double k = 1 - exp(-damping * dt_frame / 1000);
        slot->aux_v += (slot->v1 - slot->aux_v) * k;
    }
    return slot->aux_v;
}

static double compute_lerp(colyseus_predict_t* p, const predict_slot_t* slot) {
    int count = slot->ring_count;
    if (count == 0) return slot->v1;
    int head = slot->ring_head;
    int start = (head - count + RING_CAP) % RING_CAP;
    int newest = (start + count - 1) % RING_CAP;
    if (count == 1) return slot->ring_v[newest];

    /* render at the SAME instant the server's lag-comp rewinds to */
    double target = (p->clock && colyseus_room_clock_last_server_time(p->clock) > 0)
        ? colyseus_room_clock_server_now(p->clock) - slot->opts.delay - colyseus_room_clock_smoothed_rtt(p->clock) / 2
        : p->render_time - slot->opts.delay;

    if (target <= slot->ring_t[start]) return slot->ring_v[start];
    if (target >= slot->ring_t[newest]) return slot->ring_v[newest];

    int k = count - 2;
    int phys = (start + k) % RING_CAP;
    while (k > 0) {
        if (slot->ring_t[phys] <= target) break;
        k--;
        phys = phys == 0 ? RING_CAP - 1 : phys - 1;
    }
    int b = phys + 1 >= RING_CAP ? 0 : phys + 1;
    double t_a = slot->ring_t[phys], t_b = slot->ring_t[b];
    double span = t_b - t_a;
    if (span <= 0) return slot->ring_v[b];
    double u = (target - t_a) / span;
    return slot->ring_v[phys] + (slot->ring_v[b] - slot->ring_v[phys]) * u;
}

static double compute_extrapolate(colyseus_predict_t* p, predict_slot_t* slot) {
    int count = slot->ring_count;
    if (count == 0) return slot->v1;
    int head = slot->ring_head;
    int start = (head - count + RING_CAP) % RING_CAP;
    int newest = (start + count - 1) % RING_CAP;
    double newest_t = slot->ring_t[newest];
    double newest_v = slot->ring_v[newest];
    double now = p->render_time;

    double raw;
    if (count == 1) {
        raw = newest_v;
    } else {
        int steps = count >= 3 ? 2 : 1;
        int lb = (start + count - 1 - steps + RING_CAP) % RING_CAP;
        double dt = newest_t - slot->ring_t[lb];
        if (dt <= 0) {
            raw = newest_v;
        } else {
            double slope = (newest_v - slot->ring_v[lb]) / dt;
            double ahead = now - newest_t;
            if (ahead < 0) ahead = 0;
            else if (ahead > slot->opts.max_extrapolate) ahead = slot->opts.max_extrapolate;
            raw = newest_v + slope * ahead;
        }
    }

    double last_t = slot->aux_t;
    slot->aux_t = now;
    double damping = slot->opts.damping;
    if (damping <= 0) {
        slot->aux_v = raw;
        return raw;
    }
    double dt_frame = now - last_t;
    if (dt_frame > 0) {
        double k = 1 - exp(-damping * dt_frame / 1000);
        slot->aux_v += (raw - slot->aux_v) * k;
    }
    return slot->aux_v;
}

/* ── reckon (offset-decay predict-then-smooth) ───────────────────────── */

static void sim_advance(predict_sim_t* sim, double forward_ms, double* out, double end_elapsed) {
    /* refill the scratch from the live instance (all scalar fields) */
    for (int i = 0; i < sim->copy_count; i++) {
        predict_fwrite(sim->scratch, &sim->copy_fields[i],
            predict_fread(sim->instance, &sim->copy_fields[i]));
    }
    double remaining = forward_ms;
    double elapsed = end_elapsed - forward_ms; /* last substep lands ON end_elapsed */
    while (remaining > 0) {
        double step_ms = remaining < sim->substep_ms ? remaining : sim->substep_ms;
        elapsed += step_ms;
        sim->step(sim->scratch, step_ms / 1000, elapsed, sim->userdata);
        remaining -= step_ms;
    }
    for (int k = 0; k < sim->field_count; k++) {
        out[k] = predict_fread(sim->scratch, &sim->fields[k]);
    }
}

static void sim_apply(colyseus_predict_t* p, predict_sim_t* sim) {
    double now = p->render_time;
    if (sim->last_apply_time == now) return; /* once per frame */

    int n = sim->field_count;
    double base_t = p->clock ? colyseus_room_clock_last_server_time(p->clock) : NAN;
    double present = p->clock ? colyseus_room_clock_server_now(p->clock) : 0;
    double forward = (!isnan(base_t) && base_t > 0) ? present - base_t : 0;
    if (forward < 0) forward = 0;
    forward += sim->lead_ms;
    sim_advance(sim, forward, sim->out, present);

    if (sim->first_apply || sim->smoothing <= 0) {
        for (int k = 0; k < n; k++) { sim->offset[k] = 0; sim->smoothed[k] = sim->out[k]; }
    } else if (!isnan(base_t)) {
        double dt_ms = now - sim->last_apply_time;
        if (dt_ms < 0) dt_ms = 0;
        if (dt_ms > 100) dt_ms = 100;
        if (base_t != sim->last_base_t && !isnan(sim->last_base_t)) {
            /* REBASE: subtract expected motion so only a genuine snapshot
             * correction lands in the offset; past `snap` it's a teleport */
            for (int k = 0; k < n; k++) {
                double d = sim->smoothed[k] + sim->frame_vel[k] * dt_ms - sim->out[k];
                sim->offset[k] = (sim->snap > 0 && fabs(d) > sim->snap) ? 0 : d;
            }
        } else if (dt_ms > 0) {
            for (int k = 0; k < n; k++) sim->frame_vel[k] = (sim->out[k] - sim->out_prev[k]) / dt_ms;
        }
        double decay = exp(-sim->smoothing * dt_ms / 1000);
        for (int k = 0; k < n; k++) { sim->offset[k] *= decay; sim->smoothed[k] = sim->out[k] + sim->offset[k]; }
    } else {
        /* no clock → no rebase signal: plain EMA chase */
        double dt_ms = now - sim->last_apply_time;
        if (dt_ms < 0) dt_ms = 0;
        if (dt_ms > 100) dt_ms = 100;
        double k2 = 1 - exp(-sim->smoothing * dt_ms / 1000);
        for (int k = 0; k < n; k++) sim->smoothed[k] += (sim->out[k] - sim->smoothed[k]) * k2;
    }
    for (int k = 0; k < n; k++) sim->out_prev[k] = sim->out[k];
    sim->last_base_t = base_t;
    sim->last_apply_time = now;
    sim->first_apply = false;
}

/* ── plumbing ────────────────────────────────────────────────────────── */

colyseus_predict_t* colyseus_predict_create(colyseus_callbacks_t* callbacks, colyseus_room_clock_t* clock) {
    colyseus_predict_t* p = calloc(1, sizeof(colyseus_predict_t));
    p->callbacks = callbacks;
    p->clock = clock;
    p->lerp_delay = 100;   /* the reference default for lerp-mode tracking */
    return p;
}

colyseus_predict_t* colyseus_predict_for_room(struct colyseus_room* room) {
    if (!room || !room->serializer) return NULL;
    /* Borrow the room's layer: several Predicts over one room share it, and
     * the room frees it. */
    colyseus_callbacks_t* callbacks = colyseus_room_callbacks(room);
    if (!callbacks) return NULL;
    colyseus_predict_t* p = colyseus_predict_create(callbacks, colyseus_room_get_clock(room));
    /* Pace from the server's advertised tick rate even before a reconciler
     * exists, so a prediction-free lab can still use tick() for send pacing. */
    if (room->input_tick_rate > 0) p->fixed_step_ms = 1000.0 / room->input_tick_rate;
    return p;
}

/* ── attach_all ──────────────────────────────────────────────────────── */

static void attach_all_on_add(void* value, void* key, void* userdata) {
    attach_all_ctx_t* a = (attach_all_ctx_t*)userdata;
    const char* k = (const char*)key;
    if (a->except_key && k && strcmp(k, a->except_key) == 0) return;

    colyseus_schema_t* instance = (colyseus_schema_t*)value;
    if (a->step) {
        /* NULL entry_vtable: resolve from the entry itself — dynamic vtables
         * (reflection / GDScript) have no name to pass up front. */
        colyseus_predict_attach_reckon(a->p, instance,
            a->entry_vtable ? a->entry_vtable : instance->__vtable,
            (const char* const*)a->fields, a->field_count, a->step,
            a->smoothing, a->substep_ms, a->snap, a->userdata);
        return;
    }
    if (a->fields) {
        for (int i = 0; i < a->field_count; i++) {
            colyseus_predict_track(a->p, instance, a->fields[i], &a->field_opts[i]);
        }
        return;
    }
    /* No explicit list: every numeric field of the entry. */
    const colyseus_schema_vtable_t* vt = instance->__vtable;
    if (!vt) return;
    for (int i = 0; i < predict_vt_count(vt); i++) {
        predict_fref_t f;
        if (!predict_vt_at(vt, i, &f)) continue;
        if (!predict_fref_scalar(&f) || f.type == COLYSEUS_FIELD_BOOLEAN) continue;
        colyseus_predict_track(a->p, instance, f.name, &a->opts);
    }
}

static void attach_all_on_remove(void* value, void* key, void* userdata) {
    (void)key;
    attach_all_ctx_t* a = (attach_all_ctx_t*)userdata;
    colyseus_predict_detach(a->p, (colyseus_schema_t*)value);
}

int colyseus_predict_attach(
    colyseus_predict_t* p,
    colyseus_schema_t* instance,
    const colyseus_attach_field_t* config, int count) {
    if (!p || !instance || !config || count <= 0) return -1;
    for (int i = 0; i < count; i++) {
        if (!config[i].field) continue;
        /* Drop what this type doesn't declare: one config, many entry types. */
        predict_fref_t f;
        if (instance->__vtable && !predict_vt_find(instance->__vtable, config[i].field, &f)) {
            continue;
        }
        colyseus_predict_track(p, instance, config[i].field, config[i].opts);
    }
    return 0;
}

int colyseus_predict_attach_all(
    colyseus_predict_t* p,
    colyseus_schema_t* state,
    const char* collection,
    const colyseus_attach_field_t* config, int count,
    const char* except_key,
    const colyseus_predict_field_options_t* fallback) {
    if (!p || !state || !collection) return -1;

    attach_all_ctx_t* a = calloc(1, sizeof(attach_all_ctx_t));
    a->p = p;
    if (fallback) a->opts = *fallback;
    if (config && count > 0) {
        a->field_count = count;
        a->fields = calloc((size_t)count, sizeof(char*));
        a->field_opts = calloc((size_t)count, sizeof(colyseus_predict_field_options_t));
        for (int i = 0; i < count; i++) {
            a->fields[i] = strdup(config[i].field);
            /* Snapshot per-field options: the caller's structs are typically
               stack locals that die at the end of mount(). */
            if (config[i].opts) { a->field_opts[i] = *config[i].opts; }
            else if (fallback) { a->field_opts[i] = *fallback; }
        }
    }
    if (except_key) a->except_key = strdup(except_key);

    /* `immediate` replays the entries already decoded — the initial full sync
     * usually lands before an app gets here. */
    a->on_add = colyseus_callbacks_on_add(p->callbacks, state, collection,
        attach_all_on_add, a, true);
    a->on_remove = colyseus_callbacks_on_remove(p->callbacks, state, collection,
        attach_all_on_remove, a);
    a->next = p->attachments;
    p->attachments = a;
    return 0;
}

int colyseus_predict_attach_all_reckon(
    colyseus_predict_t* p,
    colyseus_schema_t* state,
    const char* collection,
    const colyseus_schema_vtable_t* entry_vtable,
    const char* const* fields, int field_count,
    colyseus_predict_step_fn step,
    double smoothing, double substep_ms, double snap,
    void* userdata) {
    /* entry_vtable may be NULL — resolved per entry at on_add (dynamic vtables). */
    if (!p || !state || !collection || !step || field_count <= 0) return -1;

    attach_all_ctx_t* a = calloc(1, sizeof(attach_all_ctx_t));
    a->p = p;
    a->entry_vtable = entry_vtable;
    a->step = step;
    a->smoothing = smoothing;
    a->substep_ms = substep_ms;
    a->snap = snap;
    a->userdata = userdata;
    a->field_count = field_count;
    a->fields = calloc((size_t)field_count, sizeof(char*));
    for (int i = 0; i < field_count; i++) a->fields[i] = strdup(fields[i]);

    a->on_add = colyseus_callbacks_on_add(p->callbacks, state, collection,
        attach_all_on_add, a, true);
    a->on_remove = colyseus_callbacks_on_remove(p->callbacks, state, collection,
        attach_all_on_remove, a);
    a->next = p->attachments;
    p->attachments = a;
    return 0;
}

static void free_slot(colyseus_predict_t* p, predict_slot_t* slot) {
    if (slot->listen_handle >= 0) colyseus_callbacks_remove(p->callbacks, slot->listen_handle);
    free(slot->listen_ctx);
    free(slot->field);
    free(slot->pose_key);
    if (slot->stash) free_slot(p, slot->stash);
    free(slot);
}

static void free_sim(predict_sim_t* sim) {
    if (sim->scratch && sim->vtable->destroy) sim->vtable->destroy(sim->scratch);
    /* field names are borrowed from the vtable — nothing per-field to free */
    free(sim->fields);
    free(sim->copy_fields);
    free(sim->smoothed);
    free(sim->out);
    free(sim->value_out);
    free(sim->offset);
    free(sim->out_prev);
    free(sim->frame_vel);
    free(sim);
}

/* Unregister an attachment's collection callbacks and free it. For a spawns
 * bind this also resets the store's confirmed-value reader — the store is
 * app-owned and may outlive this Predict. */
static void free_attachment(colyseus_predict_t* p, attach_all_ctx_t* a) {
    colyseus_callbacks_remove(p->callbacks, a->on_add);
    colyseus_callbacks_remove(p->callbacks, a->on_remove);
    for (int i = 0; i < a->field_count; i++) free(a->fields[i]);
    free(a->fields);
    free(a->field_opts);
    free(a->except_key);
    if (a->spawns_bind) {
        spawns_bind_ctx_t* b = a->spawns_bind;
        if (b->reckon) colyseus_spawns_bind_reader(b->spawns, NULL, NULL);
        for (int i = 0; i < b->field_count; i++) free(b->fields[i]);
        free(b->fields);
        free(b);
    }
    free(a);
}

void colyseus_predict_free(colyseus_predict_t* p) {
    if (!p) return;
    while (p->driven) { driven_child_t* d = p->driven; p->driven = d->next; free(d); }
    while (p->attachments) {
        attach_all_ctx_t* a = p->attachments;
        p->attachments = a->next;
        free_attachment(p, a);
    }
    slot_bucket_t *bucket, *tmp;
    HASH_ITER(hh, p->by_ref, bucket, tmp) {
        predict_slot_t* slot = bucket->slots;
        while (slot) {
            predict_slot_t* next = slot->next;
            free_slot(p, slot);
            slot = next;
        }
        HASH_DEL(p->by_ref, bucket);
        free(bucket);
    }
    predict_sim_t *sim, *stmp;
    HASH_ITER(hh, p->sims, sim, stmp) {
        HASH_DEL(p->sims, sim);
        free_sim(sim);
    }
    free(p);
}

int colyseus_predict_track(
    colyseus_predict_t* p,
    colyseus_schema_t* instance,
    const char* field,
    const colyseus_predict_field_options_t* options) {
    if (!p || !instance || !field || !instance->__vtable) return -1;
    predict_fref_t meta;
    if (!predict_vt_find(instance->__vtable, field, &meta)) return -1;

    predict_slot_t* slot = calloc(1, sizeof(predict_slot_t));
    slot->field = strdup(field);
    slot->instance = instance;
    slot->fref = meta;
    slot->type = meta.type;
    slot->opts.mode = options ? options->mode : COLYSEUS_PREDICT_LERP;
    slot->opts.delay = options && options->delay > 0 ? options->delay : 100;
    if (slot->opts.mode == COLYSEUS_PREDICT_LERP) {
        /* Lag comp must rewind to the instant we DRAW; keep the binding live. */
        p->lerp_delay = slot->opts.delay;
        predict_bind_render_delay_fwd(p);
    }
    slot->opts.damping = options
        ? (options->damping < 0 ? 0 : (options->damping > 0 ? options->damping : 15))
        : 15;
    slot->opts.max_extrapolate = options && options->max_extrapolate > 0 ? options->max_extrapolate : 200;
    slot->opts.tick_interval = options && options->tick_interval > 0 ? options->tick_interval : 0;
    slot->opts.snap = options && options->snap > 0 ? options->snap : 0;
    slot->opts.angle = options ? options->angle : false;

    double initial = predict_fread(instance, &slot->fref);
    slot->v1 = initial;
    slot->aux_v = initial;
    slot->aux_t = colyseus_room_clock_now(NULL);

    int ref_id = instance->__refId;
    slot_bucket_t* bucket = NULL;
    HASH_FIND_INT(p->by_ref, &ref_id, bucket);
    if (!bucket) {
        bucket = calloc(1, sizeof(slot_bucket_t));
        bucket->ref_id = ref_id;
        HASH_ADD_INT(p->by_ref, ref_id, bucket);
    } else {
        /* idempotent per field: replace an existing slot for this field */
        predict_slot_t** cursor = &bucket->slots;
        while (*cursor) {
            if (strcmp((*cursor)->field, field) == 0) {
                predict_slot_t* old = *cursor;
                *cursor = old->next;
                free_slot(p, old);
                break;
            }
            cursor = &(*cursor)->next;
        }
    }
    slot->next = bucket->slots;
    bucket->slots = slot;

    listen_ctx_t* lc = malloc(sizeof(listen_ctx_t));
    lc->p = p;
    lc->slot = slot;
    slot->listen_ctx = lc;
    slot->listen_handle = colyseus_callbacks_listen(
        p->callbacks, instance, field, on_sample, lc, true);
    return 0;
}

int colyseus_predict_attach_reckon(
    colyseus_predict_t* p,
    colyseus_schema_t* instance,
    const colyseus_schema_vtable_t* vtable,
    const char* const* fields, int field_count,
    colyseus_predict_step_fn step,
    double smoothing, double substep_ms, double snap,
    void* userdata) {
    if (!p || !instance || !vtable || !fields || field_count <= 0 || !step) return -1;

    predict_sim_t* sim = calloc(1, sizeof(predict_sim_t));
    sim->ref_id = instance->__refId;
    sim->instance = instance;
    sim->vtable = vtable;
    sim->step = step;
    sim->userdata = userdata;
    sim->smoothing = smoothing > 0 ? smoothing : 0;
    sim->substep_ms = substep_ms > 0 ? substep_ms : 16;
    sim->snap = snap > 0 ? snap : 0;
    sim->last_base_t = NAN;
    sim->last_apply_time = -INFINITY;
    sim->first_apply = true;

    sim->fields = calloc(field_count, sizeof(*sim->fields));
    sim->field_count = field_count;
    for (int k = 0; k < field_count; k++) {
        if (!predict_vt_find(vtable, fields[k], &sim->fields[k])) { free_sim(sim); return -1; }
    }

    /* scratch refill set: every scalar field of the vtable */
    int declared = predict_vt_count(vtable);
    sim->copy_fields = calloc((size_t)(declared > 0 ? declared : 1), sizeof(*sim->copy_fields));
    for (int i = 0; i < declared; i++) {
        predict_fref_t meta;
        if (!predict_vt_at(vtable, i, &meta) || !predict_fref_scalar(&meta)) continue;
        sim->copy_fields[sim->copy_count++] = meta;
    }

    sim->scratch = predict_instance_create(vtable);
    if (!sim->scratch) { free_sim(sim); return -1; }
    sim->scratch->__vtable = vtable;

    sim->smoothed = calloc(field_count, sizeof(double));
    sim->out = calloc(field_count, sizeof(double));
    sim->value_out = calloc(field_count, sizeof(double));
    sim->offset = calloc(field_count, sizeof(double));
    sim->out_prev = calloc(field_count, sizeof(double));
    sim->frame_vel = calloc(field_count, sizeof(double));
    for (int k = 0; k < field_count; k++) {
        sim->smoothed[k] = predict_fread(instance, &sim->fields[k]);
    }

    predict_sim_t* existing = NULL;
    HASH_FIND_INT(p->sims, &sim->ref_id, existing);
    if (existing) { HASH_DEL(p->sims, existing); free_sim(existing); }
    HASH_ADD_INT(p->sims, ref_id, sim);

    /* one-call API: each reckoned field also gets a RECKON slot (sample
     * mirror + raw fallback), like the JS reckon attach */
    colyseus_predict_field_options_t slot_opts = {0};
    slot_opts.mode = COLYSEUS_PREDICT_RECKON;
    for (int k = 0; k < field_count; k++) {
        colyseus_predict_track(p, instance, fields[k], &slot_opts);
    }
    return 0;
}

void colyseus_predict_detach(colyseus_predict_t* p, colyseus_schema_t* instance) {
    if (!p || !instance) return;
    int ref_id = instance->__refId;
    slot_bucket_t* bucket = NULL;
    HASH_FIND_INT(p->by_ref, &ref_id, bucket);
    if (bucket) {
        predict_slot_t* slot = bucket->slots;
        while (slot) {
            predict_slot_t* next = slot->next;
            free_slot(p, slot);
            slot = next;
        }
        HASH_DEL(p->by_ref, bucket);
        free(bucket);
    }
    predict_sim_t* sim = NULL;
    HASH_FIND_INT(p->sims, &ref_id, sim);
    if (sim) { HASH_DEL(p->sims, sim); free_sim(sim); }
}

int colyseus_predict_tick(colyseus_predict_t* p, double now) {
    if (!p) return 0;
    p->render_time = now;

    /* Room-wide fixed-step accumulator -> whole input steps due this frame. */
    int steps = 0;
    if (p->fixed_step_ms > 0) {
        double dt = p->has_last_frame ? now - p->last_frame_now : 0;
        p->step_acc += dt;
        steps = (int)floor(p->step_acc / p->fixed_step_ms);
        if (steps > PREDICT_MAX_STEPS_PER_FRAME) {
            p->step_acc = 0;                    /* hitch: drop the backlog */
            steps = PREDICT_MAX_STEPS_PER_FRAME;
        } else {
            p->step_acc -= steps * p->fixed_step_ms;
        }
    }
    p->has_last_frame = true;
    p->last_frame_now = now;

    /* Drive the children: one tick advances the whole prediction stack. */
    for (driven_child_t* d = p->driven; d; d = d->next) {
        switch (d->kind) {
            case DRIVEN_RECONCILER:
                colyseus_reconciler_tick((colyseus_reconciler_t*)d->ptr, now);
                break;
            case DRIVEN_EVENTS:
                colyseus_event_channel_prune((colyseus_event_channel_t*)d->ptr);
                break;
            case DRIVEN_SPAWNS:
                colyseus_spawns_tick((colyseus_spawns_t*)d->ptr, now);
                colyseus_spawns_prune((colyseus_spawns_t*)d->ptr);
                break;
        }
    }
    return steps;
}

/* ── children ────────────────────────────────────────────────────────── */

static void predict_drive(colyseus_predict_t* p, driven_kind_t kind, void* ptr) {
    if (!p || !ptr) return;
    for (driven_child_t* d = p->driven; d; d = d->next) {
        if (d->ptr == ptr) return;
    }
    driven_child_t* d = calloc(1, sizeof(driven_child_t));
    d->kind = kind;
    d->ptr = ptr;
    d->next = p->driven;
    p->driven = d;
}

/* Put back every passive slot a controller's overlay displaced, and drop the
 * bound slots themselves. Called as the controller goes away, so reads fall
 * back to smoothing (or to the raw decoded field) instead of a dangling ctrl. */
static void predict_remove_bound_overlay(colyseus_predict_t* p, colyseus_reconciler_t* r) {
    slot_bucket_t *bucket, *tmp;
    HASH_ITER(hh, p->by_ref, bucket, tmp) {
        predict_slot_t** link = &bucket->slots;
        while (*link) {
            predict_slot_t* slot = *link;
            if (slot->ctrl != r) { link = &slot->next; continue; }
            predict_slot_t* stash = slot->stash;
            slot->stash = NULL;                 /* adopted below, not freed */
            *link = stash ? stash : slot->next;
            if (stash) stash->next = slot->next;
            free_slot(p, slot);
            link = stash ? &stash->next : link;
        }
    }
}

void colyseus_predict_undrive(colyseus_predict_t* p, void* child) {
    if (!p) return;
    predict_remove_bound_overlay(p, (colyseus_reconciler_t*)child);
    /* a spawns child came with an attachment (collection callbacks + reader);
     * unwind it too, so the store can be freed before the Predict */
    attach_all_ctx_t** alink = &p->attachments;
    while (*alink) {
        attach_all_ctx_t* a = *alink;
        if (a->spawns_bind && a->spawns_bind->spawns == child) {
            *alink = a->next;
            free_attachment(p, a);
        } else {
            alink = &a->next;
        }
    }
    driven_child_t** link = &p->driven;
    while (*link) {
        if ((*link)->ptr == child) {
            driven_child_t* dead = *link;
            *link = dead->next;
            free(dead);
            return;
        }
        link = &(*link)->next;
    }
}

colyseus_callbacks_t* colyseus_predict_callbacks(colyseus_predict_t* p) {
    return p ? p->callbacks : NULL;
}

/* The confirmed side of colyseus_spawns_value(): the reckon slot, not the raw
 * decoded field. */
static double predict_spawns_read(colyseus_schema_t* server, const char* field, void* userdata) {
    return colyseus_predict_value((colyseus_predict_t*)userdata, server, field);
}

/* Per-instance forward-horizon bump (the spawn store's measured input lead). */
static void predict_sim_set_lead(colyseus_predict_t* p, colyseus_schema_t* instance, double lead_ms) {
    predict_sim_t* sim = NULL;
    int ref_id = instance->__refId;
    HASH_FIND_INT(p->sims, &ref_id, sim);
    if (sim) sim->lead_ms = lead_ms;
}

static void predict_spawns_on_add(void* value, void* key, void* userdata) {
    (void)key;
    spawns_bind_ctx_t* b = (spawns_bind_ctx_t*)userdata;
    colyseus_schema_t* server = (colyseus_schema_t*)value;
    colyseus_spawns_handle_add(b->spawns, server);
    if (!b->reckon) return;

    /* AFTER handle_add: the lead is only measured once the entry collapses onto
     * its prediction. Reading it before would silently see 0 — which looks
     * exactly like not applying the lead at all. */
    const colyseus_spawn_entry_t* entry = colyseus_spawns_entry_for(b->spawns, server);
    double lead = entry ? entry->lead_ms : 0;
    if (lead < 0) lead = 0;

    if (colyseus_predict_attach_reckon(b->p, server,
            b->entry_vtable ? b->entry_vtable : server->__vtable,
            (const char* const*)b->fields, b->field_count, b->step,
            b->smoothing, b->substep_ms, 0, b->userdata) != 0) return;
    predict_sim_set_lead(b->p, server, lead);
}

static void predict_spawns_on_remove(void* value, void* key, void* userdata) {
    (void)key;
    spawns_bind_ctx_t* b = (spawns_bind_ctx_t*)userdata;
    colyseus_schema_t* server = (colyseus_schema_t*)value;
    if (b->reckon) colyseus_predict_detach(b->p, server);
    colyseus_spawns_handle_remove(b->spawns, server);
}

void colyseus_predict_bind_spawns(colyseus_predict_t* p, colyseus_spawns_t* spawns,
    colyseus_schema_t* state, const char* collection,
    const colyseus_spawns_reckon_t* reckon) {
    if (!p || !spawns || !state || !collection) return;

    spawns_bind_ctx_t* b = calloc(1, sizeof(spawns_bind_ctx_t));
    b->p = p;
    b->spawns = spawns;
    /* entry_vtable may be NULL — resolved per entry at on_add (dynamic
     * vtables have no name to pass up front, same rule as attach_all_reckon). */
    if (reckon && reckon->fields && reckon->field_count > 0 && reckon->step) {
        b->reckon = true;
        b->entry_vtable = reckon->entry_vtable;
        b->step = reckon->step;
        b->smoothing = reckon->smoothing;
        b->substep_ms = reckon->substep_ms;
        b->userdata = reckon->userdata;
        b->field_count = reckon->field_count;
        b->fields = calloc((size_t)reckon->field_count, sizeof(char*));
        for (int i = 0; i < reckon->field_count; i++) b->fields[i] = strdup(reckon->fields[i]);
        /* route store value() confirmed reads through the reckon slots */
        colyseus_spawns_bind_reader(spawns, predict_spawns_read, p);
    }

    /* Recorded as an attachment so predict_free() unregisters it: the room owns
     * the callbacks layer, and a patch decoded after the store is freed would
     * otherwise call into it. */
    attach_all_ctx_t* a = calloc(1, sizeof(attach_all_ctx_t));
    a->p = p;
    a->spawns_bind = b;
    a->on_add = colyseus_callbacks_on_add(p->callbacks, state, collection,
        predict_spawns_on_add, b, true);
    a->on_remove = colyseus_callbacks_on_remove(p->callbacks, state, collection,
        predict_spawns_on_remove, b);
    a->next = p->attachments;
    p->attachments = a;
    predict_drive(p, DRIVEN_SPAWNS, spawns);
}

void colyseus_predict_drive_events(colyseus_predict_t* p, colyseus_event_channel_t* channel) {
    predict_drive(p, DRIVEN_EVENTS, channel);
}

void colyseus_predict_drive_spawns(colyseus_predict_t* p, colyseus_spawns_t* spawns) {
    predict_drive(p, DRIVEN_SPAWNS, spawns);
}

/*
 * Adopt a spawned reconciler's fixed step as this Predict's room-wide pacing
 * rate (first one wins — the server has a single tick rate), and reset the
 * accumulator so the first tick after the spawn doesn't emit a burst for all
 * the time that elapsed before there was anything to predict.
 */
static void predict_adopt_fixed_step(colyseus_predict_t* p, double step_ms) {
    if (step_ms <= 0) return;
    if (p->fixed_step_ms <= 0) {
        p->fixed_step_ms = step_ms;
        p->step_acc = 0;
        p->has_last_frame = false;
        return;
    }
    if (fabs(p->fixed_step_ms - step_ms) > 1e-6) {
        fprintf(stderr, "colyseus predict: a reconciler's fixed step (%.3fms) differs from this "
            "Predict's (%.3fms); tick() paces one rate for the whole room\n",
            step_ms, p->fixed_step_ms);
    }
}

/* The lag-comp stamp must name the instant this client DISPLAYED, which is
 * the lerp delay behind serverNow — see input_handle's render_delay note. */
static void predict_bind_render_delay(colyseus_predict_t* p) {
    if (p->bound_input) colyseus_input_handle_set_render_delay(p->bound_input, p->lerp_delay);
}

static void predict_bind_render_delay_fwd(colyseus_predict_t* p) { predict_bind_render_delay(p); }

/* Route colyseus_predict_value() at every field a controller predicts, so ONE
 * read idiom covers the whole render layer: passively-smoothed remotes and
 * controller-owned entities alike, with the caller never naming a pose key.
 *
 * A passive slot already on that field is STASHED, not dropped — its listener
 * keeps sampling, and undrive() puts it back. */
static void predict_install_bound_overlay(colyseus_predict_t* p, colyseus_reconciler_t* r) {
    int n = colyseus_reconciler_bound_fields_(r, NULL, 0);
    if (n <= 0) return;
    colyseus_bound_field_t* regs = calloc((size_t)n, sizeof(*regs));
    if (!regs) return;
    colyseus_reconciler_bound_fields_(r, regs, n);

    for (int i = 0; i < n; i++) {
        if (!regs[i].source) continue;
        int ref_id = regs[i].source->__refId;
        slot_bucket_t* bucket = NULL;
        HASH_FIND_INT(p->by_ref, &ref_id, bucket);
        if (!bucket) {
            bucket = calloc(1, sizeof(slot_bucket_t));
            if (!bucket) continue;
            bucket->ref_id = ref_id;
            HASH_ADD_INT(p->by_ref, ref_id, bucket);
        }

        predict_slot_t* stash = NULL;
        predict_slot_t** cursor = &bucket->slots;
        while (*cursor) {
            if (strcmp((*cursor)->field, regs[i].field) == 0) {
                stash = *cursor;
                *cursor = stash->next;
                if (stash->ctrl) {
                    /* Same (instance, field) claimed twice: newer wins, and it
                     * inherits the ORIGINAL passive slot rather than nesting. */
                    predict_slot_t* prior = stash;
                    stash = prior->stash;
                    prior->stash = NULL;
                    free_slot(p, prior);
                }
                break;
            }
            cursor = &(*cursor)->next;
        }

        predict_slot_t* slot = calloc(1, sizeof(predict_slot_t));
        if (!slot) { continue; }
        slot->field = strdup(regs[i].field);
        slot->pose_key = strdup(regs[i].pose_key);
        slot->instance = regs[i].source;
        slot->ctrl = r;
        slot->stash = stash;
        slot->listen_handle = -1;
        slot->next = bucket->slots;
        bucket->slots = slot;
    }
    free(regs);
}

colyseus_reconciler_t* colyseus_predict_reconciler(
    colyseus_predict_t* p,
    colyseus_schema_t* truth,
    const colyseus_schema_vtable_t* vtable,
    colyseus_input_handle_t* input,
    colyseus_reconciler_step_fn step,
    const colyseus_reconciler_options_t* options) {
    if (!p) return NULL;
    colyseus_reconciler_t* r =
        colyseus_reconciler_create(truth, vtable, input, p->clock, step, options);
    if (!r) return NULL;
    predict_adopt_fixed_step(p, colyseus_reconciler_step_ms(r));
    predict_drive(p, DRIVEN_RECONCILER, r);
    colyseus_reconciler_set_driver_(r, p);
    predict_install_bound_overlay(p, r);
    p->bound_input = input;
    predict_bind_render_delay(p);
    return r;
}

colyseus_reconciler_t* colyseus_predict_sim_reconciler(
    colyseus_predict_t* p,
    colyseus_input_handle_t* input,
    colyseus_sim_step_fn step,
    const colyseus_sim_reconciler_options_t* options) {
    if (!p) return NULL;
    colyseus_reconciler_t* r = colyseus_sim_reconciler_create(input, p->clock, step, options);
    if (!r) return NULL;
    predict_adopt_fixed_step(p, colyseus_reconciler_step_ms(r));
    predict_drive(p, DRIVEN_RECONCILER, r);
    colyseus_reconciler_set_driver_(r, p);
    predict_install_bound_overlay(p, r);
    p->bound_input = input;
    predict_bind_render_delay(p);
    return r;
}

static predict_slot_t* find_slot(colyseus_predict_t* p, colyseus_schema_t* instance, const char* field) {
    int ref_id = instance->__refId;
    slot_bucket_t* bucket = NULL;
    HASH_FIND_INT(p->by_ref, &ref_id, bucket);
    if (!bucket) return NULL;
    for (predict_slot_t* slot = bucket->slots; slot; slot = slot->next) {
        if (strcmp(slot->field, field) == 0) return slot;
    }
    return NULL;
}

double colyseus_predict_value(colyseus_predict_t* p, colyseus_schema_t* instance, const char* field) {
    predict_slot_t* slot = find_slot(p, instance, field);
    if (!slot) {
        /* Untracked is FINE — read the decoded field verbatim. A field that
         * doesn't exist is not: NAN, so a typo can't render as a plausible 0. */
        if (instance->__vtable) {
            predict_fref_t meta;
            if (predict_vt_find(instance->__vtable, field, &meta) && predict_fref_scalar(&meta))
                return predict_fread(instance, &meta);
        }
        return NAN;
    }
    /* Controller-owned: the pose comes from its rollback, not the server stream. */
    if (slot->ctrl) return colyseus_reconciler_value(slot->ctrl, slot->pose_key);
    switch (slot->opts.mode) {
        case COLYSEUS_PREDICT_LERP:        return compute_lerp(p, slot);
        case COLYSEUS_PREDICT_DAMPED:      return compute_damped(p, slot);
        case COLYSEUS_PREDICT_EXTRAPOLATE: return compute_extrapolate(p, slot);
        case COLYSEUS_PREDICT_RECKON: {
            predict_sim_t* sim = NULL;
            int ref_id = instance->__refId;
            HASH_FIND_INT(p->sims, &ref_id, sim);
            if (sim) {
                for (int k = 0; k < sim->field_count; k++) {
                    if (strcmp(sim->fields[k].name, field) == 0) {
                        sim_apply(p, sim);
                        return sim->smoothed[k];
                    }
                }
            }
            return slot->v1;
        }
        default: return compute_raw(slot);
    }
}

double colyseus_predict_value_at(colyseus_predict_t* p, colyseus_schema_t* instance, const char* field, double time) {
    predict_slot_t* slot = find_slot(p, instance, field);
    if (slot == NULL || slot->opts.mode != COLYSEUS_PREDICT_RECKON) {
        return colyseus_predict_value(p, instance, field);
    }
    predict_sim_t* sim = NULL;
    int ref_id = instance->__refId;
    HASH_FIND_INT(p->sims, &ref_id, sim);
    if (sim) {
        for (int k = 0; k < sim->field_count; k++) {
            if (strcmp(sim->fields[k].name, field) != 0) continue;
            double base = p->clock ? colyseus_room_clock_last_server_time(p->clock) : NAN;
            double forward = isnan(base) ? 0 : time - base;
            if (forward < 0) forward = 0;
            sim_advance(sim, forward, sim->value_out, time);
            return sim->value_out[k];
        }
    }
    return slot->v1;
}
