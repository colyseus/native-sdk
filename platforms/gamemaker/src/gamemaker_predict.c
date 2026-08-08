// GameMaker bridge — prediction layer.
//
// Exposes the SDK's predict primitives (input handle, Predict controller,
// manual-pump reconciler, optimistic events, predicted spawns, netdelay
// injector, room clock) through GameMaker's doubles-and-strings FFI.
//
// GameMaker can never be called back from C, so:
//   - reconcilers are created in manual_step mode and GML drains their steps
//     through the pump exports (recon_pump_begin/next/commit/end);
//   - dead-reckon steps run C-side as built-in parametric steps (step_id);
//   - event-channel settlement and spawn rejections surface as polled queue
//     events (GM_EVENT_PREDICT_SETTLE / GM_EVENT_SPAWN_REJECT).
//
// Handles: predict/reconciler/channel/spawns are small-int registry ids
// (1-based). Inputs and clocks accept EITHER a room ref (1..16) OR a raw
// component pointer cast to double — the latter exists for the offline Zig
// bridge tests, which have no rooms.

#include "gamemaker_internal.h"

#include "../../../include/colyseus/room.h"
#include "../../../include/colyseus/room_clock.h"
#include "../../../include/colyseus/input_handle.h"
#include "../../../include/colyseus/net_delay.h"
#include "../../../include/colyseus/predict/predict.h"
#include "../../../include/colyseus/predict/reconciler.h"
#include "../../../include/colyseus/predict/sim_reconciler.h"
#include "../../../include/colyseus/predict/events.h"
#include "../../../include/colyseus/predict/spawns.h"
#include "../../../include/colyseus/predict/drift.h"
#include "../../../include/colyseus/schema/dynamic_schema.h"
#include "../../../src/predict/field_access.h"
#include "cJSON.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Bumped whenever the export surface changes; Colyseus.gml asserts it at
// init so a stale shim/bundle fails loudly instead of returning silent 0s.
#define GM_PREDICT_ABI_VERSION 1

// =============================================================================
// Registries
// =============================================================================

#define GM_MAX_PREDICTS 8
#define GM_MAX_RECONS 8
#define GM_MAX_CHANNELS 16
#define GM_MAX_SPAWN_STORES 8
#define GM_MAX_OWNED_PARAMS 16
#define GM_SPAWN_MAX_FIELDS 8
#define GM_NAME_MAX 32

typedef struct {
    int id;                       /* 1 = integrate */
    char fx[GM_NAME_MAX], fy[GM_NAME_MAX];
    char fvx[GM_NAME_MAX], fvy[GM_NAME_MAX];
    bool has_bounds;
    double bx0, by0, bx1, by1;
    int edge;                     /* 0 clamp, 1 bounce, 2 wrap */
    double friction;              /* 1/s, multiplicative velocity damping */
    double max_speed;             /* clamp |v| per axis; 0 = off */
} gm_step_params_t;

typedef struct {
    bool in_use;
    int room_ref;                  /* 0 = component-built (tests) */
    colyseus_predict_t* predict;
    gm_step_params_t* owned_params[GM_MAX_OWNED_PARAMS];
    int owned_param_count;
} gm_predict_entry_t;

typedef struct {
    bool in_use;
    int room_ref;
    int predict_id;
    colyseus_reconciler_t* recon;
} gm_recon_entry_t;

typedef struct {
    bool in_use;
    int room_ref;
    int predict_id;                /* set when driven */
    colyseus_event_channel_t* channel;
} gm_channel_entry_t;

typedef struct gm_spawns_entry {
    bool in_use;
    int room_ref;
    int predict_id;                /* set when bound */
    colyseus_spawns_t* spawns;
    char fields[GM_SPAWN_MAX_FIELDS][GM_NAME_MAX];
    const char* field_ptrs[GM_SPAWN_MAX_FIELDS];   /* stable view for reckon */
    int field_count;
    char owned_field[GM_NAME_MAX];
    char owned_value[64];
    char spawn_time_field[GM_NAME_MAX];
    gm_step_params_t step;         /* step.id 0 = no pending-local motion */
    double staging[GM_SPAWN_MAX_FIELDS];
    /* iteration cursor */
    const colyseus_spawn_entry_t* cur;
    bool iter_primed;
} gm_spawns_entry_t;

static gm_predict_entry_t g_predicts[GM_MAX_PREDICTS];
static gm_recon_entry_t g_recons[GM_MAX_RECONS];
static gm_channel_entry_t g_channels[GM_MAX_CHANNELS];
static gm_spawns_entry_t g_spawn_stores[GM_MAX_SPAWN_STORES];

/* spawn locals: a flat double record + a link to its store's field table */
typedef struct {
    gm_spawns_entry_t* owner;
    double v[GM_SPAWN_MAX_FIELDS];
} gm_spawn_local_t;

// =============================================================================
// Resolvers — room refs (1..16) vs raw component pointers
// =============================================================================

static bool gm_is_room_ref(double h) {
    return h >= 1 && h <= GM_MAX_ROOM_REFS && h == (double)(int)h;
}

static colyseus_input_handle_t* gm_input_resolve(double h) {
    if (h == 0) return NULL;
    if (gm_is_room_ref(h)) {
        colyseus_room_t* room = gm_room_ref_get((int)h);
        return room ? colyseus_room_input(room, NULL, NULL) : NULL;
    }
    return (colyseus_input_handle_t*)(uintptr_t)h;
}

static colyseus_room_clock_t* gm_clock_resolve(double h) {
    if (h == 0) return NULL;
    if (gm_is_room_ref(h)) {
        colyseus_room_t* room = gm_room_ref_get((int)h);
        return room ? colyseus_room_get_clock(room) : NULL;
    }
    return (colyseus_room_clock_t*)(uintptr_t)h;
}

static gm_predict_entry_t* gm_predict_entry(double id) {
    int i = (int)id;
    if (i < 1 || i > GM_MAX_PREDICTS || !g_predicts[i - 1].in_use) return NULL;
    return &g_predicts[i - 1];
}

static gm_recon_entry_t* gm_recon_entry(double id) {
    int i = (int)id;
    if (i < 1 || i > GM_MAX_RECONS || !g_recons[i - 1].in_use) return NULL;
    return &g_recons[i - 1];
}

static gm_channel_entry_t* gm_channel_entry(double id) {
    int i = (int)id;
    if (i < 1 || i > GM_MAX_CHANNELS || !g_channels[i - 1].in_use) return NULL;
    return &g_channels[i - 1];
}

static gm_spawns_entry_t* gm_spawns_entry(double id) {
    int i = (int)id;
    if (i < 1 || i > GM_MAX_SPAWN_STORES || !g_spawn_stores[i - 1].in_use) return NULL;
    return &g_spawn_stores[i - 1];
}

static colyseus_schema_t* gm_instance(double h) {
    return (colyseus_schema_t*)(uintptr_t)h;
}

static int gm_split_csv(const char* csv, char storage[][GM_NAME_MAX],
                        const char** out, int max);

/* Read/write a named scalar on either storage model. Returns NAN / false on
 * unknown fields — never a plausible 0. */
static double gm_field_read(const colyseus_schema_t* inst, const char* field) {
    if (!inst || !inst->__vtable || !field) return NAN;
    predict_fref_t f;
    if (!predict_vt_find(inst->__vtable, field, &f) || !predict_fref_scalar(&f)) return NAN;
    return predict_fread(inst, &f);
}

static bool gm_field_write(colyseus_schema_t* inst, const char* field, double v) {
    if (!inst || !inst->__vtable || !field) return false;
    predict_fref_t f;
    if (!predict_vt_find(inst->__vtable, field, &f) || !predict_fref_scalar(&f)) return false;
    predict_fwrite(inst, &f, v);
    return true;
}

// =============================================================================
// Built-in parametric steps (reckon + spawn locals run C-side: they execute
// synchronously inside reads/ticks and cannot be pumped out to GML)
// =============================================================================

static void gm_step_params_defaults(gm_step_params_t* sp) {
    memset(sp, 0, sizeof(*sp));
    snprintf(sp->fx, GM_NAME_MAX, "x");
    snprintf(sp->fy, GM_NAME_MAX, "y");
    snprintf(sp->fvx, GM_NAME_MAX, "vx");
    snprintf(sp->fvy, GM_NAME_MAX, "vy");
}

static void gm_step_params_parse(gm_step_params_t* sp, int step_id, const char* json) {
    gm_step_params_defaults(sp);
    sp->id = step_id;
    if (!json || !json[0]) return;
    cJSON* root = cJSON_Parse(json);
    if (!root) return;
    const cJSON* fields = cJSON_GetObjectItem(root, "fields");
    if (cJSON_IsArray(fields)) {
        const char* dst[4] = { sp->fx, sp->fy, sp->fvx, sp->fvy };
        for (int i = 0; i < 4 && i < cJSON_GetArraySize(fields); i++) {
            const cJSON* it = cJSON_GetArrayItem(fields, i);
            if (cJSON_IsString(it)) snprintf((char*)dst[i], GM_NAME_MAX, "%s", it->valuestring);
        }
    }
    const cJSON* bounds = cJSON_GetObjectItem(root, "bounds");
    if (cJSON_IsArray(bounds) && cJSON_GetArraySize(bounds) == 4) {
        sp->has_bounds = true;
        sp->bx0 = cJSON_GetArrayItem(bounds, 0)->valuedouble;
        sp->by0 = cJSON_GetArrayItem(bounds, 1)->valuedouble;
        sp->bx1 = cJSON_GetArrayItem(bounds, 2)->valuedouble;
        sp->by1 = cJSON_GetArrayItem(bounds, 3)->valuedouble;
    }
    const cJSON* edge = cJSON_GetObjectItem(root, "edge");
    if (cJSON_IsString(edge)) {
        if (strcmp(edge->valuestring, "bounce") == 0) sp->edge = 1;
        else if (strcmp(edge->valuestring, "wrap") == 0) sp->edge = 2;
    }
    const cJSON* friction = cJSON_GetObjectItem(root, "friction");
    if (cJSON_IsNumber(friction)) sp->friction = friction->valuedouble;
    const cJSON* max_speed = cJSON_GetObjectItem(root, "maxSpeed");
    if (cJSON_IsNumber(max_speed)) sp->max_speed = max_speed->valuedouble;
    cJSON_Delete(root);
}

/* One integrate step over an axis pair pulled through get/set thunks. */
typedef struct {
    double (*get)(void* obj, const char* field, void* env);
    void (*set)(void* obj, const char* field, double v, void* env);
    void* env;
} gm_axes_access_t;

static void gm_integrate(const gm_step_params_t* sp, void* obj,
                         const gm_axes_access_t* ax, double dt) {
    double vx = sp->fvx[0] ? ax->get(obj, sp->fvx, ax->env) : 0;
    double vy = sp->fvy[0] ? ax->get(obj, sp->fvy, ax->env) : 0;
    if (sp->friction > 0) {
        double k = 1 - sp->friction * dt;
        if (k < 0) k = 0;
        vx *= k;
        vy *= k;
    }
    if (sp->max_speed > 0) {
        if (vx > sp->max_speed) vx = sp->max_speed;
        if (vx < -sp->max_speed) vx = -sp->max_speed;
        if (vy > sp->max_speed) vy = sp->max_speed;
        if (vy < -sp->max_speed) vy = -sp->max_speed;
    }
    double x = sp->fx[0] ? ax->get(obj, sp->fx, ax->env) : 0;
    double y = sp->fy[0] ? ax->get(obj, sp->fy, ax->env) : 0;
    if (!isnan(x)) x += vx * dt;
    if (!isnan(y)) y += vy * dt;
    if (sp->has_bounds) {
        double* pos[2] = { &x, &y };
        double* vel[2] = { &vx, &vy };
        double lo[2] = { sp->bx0, sp->by0 };
        double hi[2] = { sp->bx1, sp->by1 };
        for (int a = 0; a < 2; a++) {
            if (isnan(*pos[a])) continue;
            if (sp->edge == 2) { /* wrap */
                double span = hi[a] - lo[a];
                if (span > 0 && isfinite(*pos[a])) {
                    /* fmod, not a subtract loop: an inf/huge divergent pose
                     * would spin the frame forever */
                    double off = fmod(*pos[a] - lo[a], span);
                    if (off < 0) off += span;
                    *pos[a] = lo[a] + off;
                }
            } else if (*pos[a] < lo[a]) {
                *pos[a] = lo[a];
                if (sp->edge == 1) *vel[a] = -*vel[a];
            } else if (*pos[a] > hi[a]) {
                *pos[a] = hi[a];
                if (sp->edge == 1) *vel[a] = -*vel[a];
            }
        }
    }
    if (sp->fx[0] && !isnan(x)) ax->set(obj, sp->fx, x, ax->env);
    if (sp->fy[0] && !isnan(y)) ax->set(obj, sp->fy, y, ax->env);
    if (sp->fvx[0]) ax->set(obj, sp->fvx, vx, ax->env);
    if (sp->fvy[0]) ax->set(obj, sp->fvy, vy, ax->env);
}

/* -- schema-instance flavor (reckon scratches) -- */
static double axes_schema_get(void* obj, const char* field, void* env) {
    (void)env;
    return gm_field_read((colyseus_schema_t*)obj, field);
}
static void axes_schema_set(void* obj, const char* field, double v, void* env) {
    (void)env;
    gm_field_write((colyseus_schema_t*)obj, field, v);
}

static void gm_builtin_reckon_step(colyseus_schema_t* state, double dt,
                                   double elapsed_ms, void* userdata) {
    (void)elapsed_ms;
    const gm_step_params_t* sp = (const gm_step_params_t*)userdata;
    if (!sp || sp->id == 0) return;
    gm_axes_access_t ax = { axes_schema_get, axes_schema_set, NULL };
    gm_integrate(sp, state, &ax, dt);
}

/* -- spawn-local flavor (double records) -- */
static int gm_spawn_field_index(const gm_spawns_entry_t* e, const char* field) {
    for (int i = 0; i < e->field_count; i++) {
        if (strcmp(e->fields[i], field) == 0) return i;
    }
    return -1;
}

static double axes_local_get(void* obj, const char* field, void* env) {
    gm_spawn_local_t* local = (gm_spawn_local_t*)obj;
    (void)env;
    int idx = gm_spawn_field_index(local->owner, field);
    return idx >= 0 ? local->v[idx] : NAN;
}
static void axes_local_set(void* obj, const char* field, double v, void* env) {
    gm_spawn_local_t* local = (gm_spawn_local_t*)obj;
    (void)env;
    int idx = gm_spawn_field_index(local->owner, field);
    if (idx >= 0) local->v[idx] = v;
}

// =============================================================================
// Misc / clock
// =============================================================================

GM_EXPORT double colyseus_gm_predict_abi_version(void) {
    return GM_PREDICT_ABI_VERSION;
}

GM_EXPORT double colyseus_gm_now(void) {
    return colyseus_room_clock_now(NULL);
}

GM_EXPORT double colyseus_gm_clock_stat(double clock_h, double which) {
    colyseus_room_clock_t* clock = gm_clock_resolve(clock_h);
    if (!clock) return 0;
    switch ((int)which) {
        case 0: return colyseus_room_clock_server_now(clock);
        case 1: return colyseus_room_clock_render_now(clock);
        case 2: return colyseus_room_clock_rtt(clock);
        case 3: return colyseus_room_clock_smoothed_rtt(clock);
        case 4: return colyseus_room_clock_jitter(clock);
        case 5: return colyseus_room_clock_last_server_time(clock);
        case 6: return colyseus_room_clock_patch_interval(clock);
        default: return 0;
    }
}

GM_EXPORT void colyseus_gm_reconnect_poll(void) {
    colyseus_reconnect_poll();
}

// =============================================================================
// Input handle — addressed by room ref (per-room singleton) or raw pointer
// =============================================================================

GM_EXPORT double colyseus_gm_input_init(double room_ref, double unreliable,
                                        double history_size, double render_delay) {
    colyseus_room_t* room = gm_room_ref_get((int)room_ref);
    if (!room) return 0;
    colyseus_input_options_t opts = {0};
    opts.unreliable = unreliable != 0;
    opts.history_size = (int)history_size;
    opts.render_delay = render_delay;
    colyseus_input_handle_t* h = colyseus_room_input(room, NULL, &opts);
    if (!h) return 0;
    /* serialize inbound decode onto the GML thread — see net_delay.h */
    colyseus_netdelay_wrap(room, true);
    return 1;
}

GM_EXPORT double colyseus_gm_input_set(double input_h, const char* field, double value) {
    colyseus_input_handle_t* h = gm_input_resolve(input_h);
    if (!h) return 0;
    return gm_field_write(colyseus_input_handle_data(h), field, value) ? 1 : 0;
}

GM_EXPORT double colyseus_gm_input_get(double input_h, const char* field) {
    colyseus_input_handle_t* h = gm_input_resolve(input_h);
    if (!h) return NAN;
    return gm_field_read(colyseus_input_handle_data(h), field);
}

GM_EXPORT double colyseus_gm_input_send(double input_h) {
    colyseus_input_handle_t* h = gm_input_resolve(input_h);
    return h ? (double)colyseus_input_handle_send(h) : 0;
}

GM_EXPORT double colyseus_gm_input_stat(double input_h, double which) {
    colyseus_input_handle_t* h = gm_input_resolve(input_h);
    if (!h) return 0;
    switch ((int)which) {
        case 0: return (double)colyseus_input_handle_sent_count(h);
        case 1: return (double)colyseus_input_handle_last_processed(h);
        case 2: return (double)colyseus_input_handle_pending_count(h);
        case 3: return (double)colyseus_input_handle_epoch(h);
        case 4: return (double)colyseus_input_handle_tick_rate(h);
        case 5: return (double)colyseus_input_handle_patch_rate(h);
        case 6: return (double)colyseus_input_handle_sub_steps(h);
        case 7: return colyseus_input_handle_render_delay(h);
        case 8: return (double)colyseus_input_handle_replay_buffer_size(h);
        default: return 0;
    }
}

GM_EXPORT void colyseus_gm_input_set_render_delay(double input_h, double ms) {
    colyseus_input_handle_t* h = gm_input_resolve(input_h);
    if (h) colyseus_input_handle_set_render_delay(h, ms);
}

GM_EXPORT void colyseus_gm_input_reset(double input_h) {
    colyseus_input_handle_t* h = gm_input_resolve(input_h);
    if (h) colyseus_input_handle_reset(h);
}

/* allow_rewind without a callback into GML: gate on a flag FIELD of the input
 * data — GML sets the field before send, the C predicate reads it. */
typedef struct {
    colyseus_input_handle_t* handle;
    char field[GM_NAME_MAX];
} gm_rewind_slot_t;
static gm_rewind_slot_t g_rewind_slots[GM_MAX_ROOM_REFS];

static bool gm_rewind_pred(void* data, void* userdata) {
    gm_rewind_slot_t* slot = (gm_rewind_slot_t*)userdata;
    double v = gm_field_read((colyseus_schema_t*)data, slot->field);
    return !isnan(v) && v != 0;
}

GM_EXPORT double colyseus_gm_input_set_rewind_field(double input_h, const char* field) {
    colyseus_input_handle_t* h = gm_input_resolve(input_h);
    if (!h) return 0;
    gm_rewind_slot_t* slot = NULL;
    for (int i = 0; i < GM_MAX_ROOM_REFS; i++) {
        if (g_rewind_slots[i].handle == h) { slot = &g_rewind_slots[i]; break; }
    }
    if (!field || !field[0]) {
        if (slot) slot->handle = NULL;
        colyseus_input_handle_set_allow_rewind(h, NULL, NULL);
        return 1;
    }
    if (!slot) {
        for (int i = 0; i < GM_MAX_ROOM_REFS; i++) {
            if (!g_rewind_slots[i].handle) { slot = &g_rewind_slots[i]; break; }
        }
    }
    if (!slot) return 0;
    slot->handle = h;
    snprintf(slot->field, GM_NAME_MAX, "%s", field);
    colyseus_input_handle_set_allow_rewind(h, gm_rewind_pred, slot);
    return 1;
}

// =============================================================================
// Predict controller
// =============================================================================

static double gm_predict_register(colyseus_predict_t* p, int room_ref) {
    if (!p) return 0;
    for (int i = 0; i < GM_MAX_PREDICTS; i++) {
        if (!g_predicts[i].in_use) {
            memset(&g_predicts[i], 0, sizeof(g_predicts[i]));
            g_predicts[i].in_use = true;
            g_predicts[i].room_ref = room_ref;
            g_predicts[i].predict = p;
            return (double)(i + 1);
        }
    }
    colyseus_predict_free(p);
    return 0;
}

GM_EXPORT double colyseus_gm_predict_create(double room_ref) {
    colyseus_room_t* room = gm_room_ref_get((int)room_ref);
    if (!room) return 0;
    return gm_predict_register(colyseus_predict_for_room(room), (int)room_ref);
}

/* component-built variant for offline tests (no room needed) */
GM_EXPORT double colyseus_gm_predict_create_with(double callbacks_ptr, double clock_ptr) {
    colyseus_predict_t* p = colyseus_predict_create(
        (colyseus_callbacks_t*)(uintptr_t)callbacks_ptr,
        gm_clock_resolve(clock_ptr));
    return gm_predict_register(p, 0);
}

/* The params blob a reckon attach hands to the C step — owned by the predict.
 * step_id 0 yields a no-op step (pure projection). */
static void gm_spec_step_params(const cJSON* root, gm_step_params_t* sp);
static gm_step_params_t* gm_predict_own_params_spec(gm_predict_entry_t* e,
                                                    const cJSON* root) {
    if (e->owned_param_count >= GM_MAX_OWNED_PARAMS) return NULL;
    gm_step_params_t* sp = malloc(sizeof(gm_step_params_t));
    if (!sp) return NULL;
    gm_spec_step_params(root, sp);
    e->owned_params[e->owned_param_count++] = sp;
    return sp;
}

static void gm_predict_entry_free(gm_predict_entry_t* e) {
    if (!e->in_use) return;
    colyseus_predict_free(e->predict);
    for (int i = 0; i < e->owned_param_count; i++) free(e->owned_params[i]);
    memset(e, 0, sizeof(*e));
}

GM_EXPORT void colyseus_gm_predict_free(double predict_id) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    if (!e) return;
    int id = (int)predict_id;
    /* children first — they undrive/deregister themselves */
    for (int i = 0; i < GM_MAX_RECONS; i++) {
        if (g_recons[i].in_use && g_recons[i].predict_id == id) {
            colyseus_reconciler_free(g_recons[i].recon);
            memset(&g_recons[i], 0, sizeof(g_recons[i]));
        }
    }
    for (int i = 0; i < GM_MAX_SPAWN_STORES; i++) {
        if (g_spawn_stores[i].in_use && g_spawn_stores[i].predict_id == id) {
            colyseus_spawns_free(g_spawn_stores[i].spawns);
            memset(&g_spawn_stores[i], 0, sizeof(g_spawn_stores[i]));
        }
    }
    for (int i = 0; i < GM_MAX_CHANNELS; i++) {
        if (g_channels[i].in_use && g_channels[i].predict_id == id) {
            colyseus_event_channel_free(g_channels[i].channel);
            memset(&g_channels[i], 0, sizeof(g_channels[i]));
        }
    }
    gm_predict_entry_free(e);
}

GM_EXPORT double colyseus_gm_predict_tick(double predict_id, double now) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    return e ? (double)colyseus_predict_tick(e->predict, now) : 0;
}

/* One field-options blob: a bare mode number or {"mode":2,"delay":100,...} —
 * mode ints follow colyseus_predict_mode_t (0 lerp, 1 extrapolate, 2 damped,
 * 3 reckon, 4 raw). */
static void gm_parse_field_options(const cJSON* it, colyseus_predict_field_options_t* o) {
    memset(o, 0, sizeof(*o));
    if (cJSON_IsNumber(it)) {
        o->mode = (colyseus_predict_mode_t)it->valueint;
        return;
    }
    if (!cJSON_IsObject(it)) return;
    const cJSON* v;
    if ((v = cJSON_GetObjectItem(it, "mode")) && cJSON_IsNumber(v)) o->mode = (colyseus_predict_mode_t)v->valueint;
    if ((v = cJSON_GetObjectItem(it, "delay")) && cJSON_IsNumber(v)) o->delay = v->valuedouble;
    if ((v = cJSON_GetObjectItem(it, "damping")) && cJSON_IsNumber(v)) o->damping = v->valuedouble;
    if ((v = cJSON_GetObjectItem(it, "max_extrapolate")) && cJSON_IsNumber(v)) o->max_extrapolate = v->valuedouble;
    if ((v = cJSON_GetObjectItem(it, "tick_interval")) && cJSON_IsNumber(v)) o->tick_interval = v->valuedouble;
    if ((v = cJSON_GetObjectItem(it, "snap")) && cJSON_IsNumber(v)) o->snap = v->valuedouble;
    if ((v = cJSON_GetObjectItem(it, "angle")) && cJSON_IsBool(v)) o->angle = cJSON_IsTrue(v);
}

/* GameMaker refuses extension functions with >4 args of mixed types, so
 * every long signature folds its tail into ONE json spec string. */

/* {"x":0,"y":{"mode":2,"delay":100}} → per-field attach config */
static int gm_parse_attach_config(const cJSON* root,
    colyseus_attach_field_t* out_fields, colyseus_predict_field_options_t* out_opts,
    char names[][GM_NAME_MAX], int max) {
    if (!root || !cJSON_IsObject(root)) return 0;
    int n = 0;
    for (const cJSON* it = root->child; it && n < max; it = it->next) {
        if (!it->string) continue;
        if (!cJSON_IsNumber(it) && !cJSON_IsObject(it)) continue;
        snprintf(names[n], GM_NAME_MAX, "%s", it->string);
        gm_parse_field_options(it, &out_opts[n]);
        out_fields[n].field = names[n];
        out_fields[n].opts = &out_opts[n];
        n++;
    }
    return n;
}

/* spec helpers: "fields" accepts ["x","y"] or "x,y"; "step_params" accepts a
 * nested object (serialized through for the params parser) */
static void gm_spec_fields_csv(const cJSON* v, char* out, size_t out_size) {
    out[0] = '\0';
    if (cJSON_IsString(v)) {
        snprintf(out, out_size, "%s", v->valuestring);
        return;
    }
    if (!cJSON_IsArray(v)) return;
    size_t used = 0;
    for (const cJSON* it = v->child; it; it = it->next) {
        if (!cJSON_IsString(it)) continue;
        int wrote = snprintf(out + used, out_size - used, "%s%s",
                             used > 0 ? "," : "", it->valuestring);
        if (wrote < 0 || (size_t)wrote >= out_size - used) break;
        used += (size_t)wrote;
    }
}

static double gm_spec_num(const cJSON* root, const char* key, double def) {
    const cJSON* v = cJSON_GetObjectItem(root, key);
    return cJSON_IsNumber(v) ? v->valuedouble : def;
}

static void gm_spec_str(const cJSON* root, const char* key, char* out, size_t out_size) {
    const cJSON* v = cJSON_GetObjectItem(root, key);
    out[0] = '\0';
    if (cJSON_IsString(v)) snprintf(out, out_size, "%s", v->valuestring);
}

/* step params from a spec: {"step_id":1,"step_params":{...}} (the params may
 * also arrive as an already-encoded JSON string) */
static void gm_spec_step_params(const cJSON* root, gm_step_params_t* sp) {
    int step_id = (int)gm_spec_num(root, "step_id", 0);
    const cJSON* params = cJSON_GetObjectItem(root, "step_params");
    if (cJSON_IsString(params)) {
        gm_step_params_parse(sp, step_id, params->valuestring);
        return;
    }
    char* params_json = params ? cJSON_PrintUnformatted(params) : NULL;
    gm_step_params_parse(sp, step_id, params_json);
    free(params_json);
}

#define GM_ATTACH_MAX_FIELDS 16

GM_EXPORT double colyseus_gm_predict_attach(double predict_id, double instance,
                                            const char* config_json) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    colyseus_schema_t* inst = gm_instance(instance);
    if (!e || !inst) return -1;
    colyseus_attach_field_t fields[GM_ATTACH_MAX_FIELDS];
    colyseus_predict_field_options_t opts[GM_ATTACH_MAX_FIELDS];
    char names[GM_ATTACH_MAX_FIELDS][GM_NAME_MAX];
    cJSON* root = cJSON_Parse(config_json ? config_json : "");
    int n = gm_parse_attach_config(root, fields, opts, names, GM_ATTACH_MAX_FIELDS);
    cJSON_Delete(root);
    if (n <= 0) return -1;
    return (double)colyseus_predict_attach(e->predict, inst, fields, n);
}

/* the predict's state fallback: explicit instance, else the room's root */
static colyseus_schema_t* gm_predict_state(gm_predict_entry_t* e, double state_instance) {
    colyseus_schema_t* state = gm_instance(state_instance);
    if (!state && e->room_ref) {
        colyseus_room_t* room = gm_room_ref_get(e->room_ref);
        if (room) state = (colyseus_schema_t*)colyseus_room_get_state(room);
    }
    return state;
}

/* spec: {"collection":"players","config":{...}|null,"except":"<key>"} */
GM_EXPORT double colyseus_gm_predict_attach_all(double predict_id, double state_instance,
                                                const char* spec_json) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    if (!e) return -1;
    colyseus_schema_t* state = gm_predict_state(e, state_instance);
    cJSON* root = cJSON_Parse(spec_json ? spec_json : "");
    if (!state || !root) { cJSON_Delete(root); return -1; }
    char collection[GM_NAME_MAX], except_key[64];
    gm_spec_str(root, "collection", collection, sizeof(collection));
    gm_spec_str(root, "except", except_key, sizeof(except_key));
    colyseus_attach_field_t fields[GM_ATTACH_MAX_FIELDS];
    colyseus_predict_field_options_t opts[GM_ATTACH_MAX_FIELDS];
    char names[GM_ATTACH_MAX_FIELDS][GM_NAME_MAX];
    int n = gm_parse_attach_config(cJSON_GetObjectItem(root, "config"),
                                   fields, opts, names, GM_ATTACH_MAX_FIELDS);
    int rc = collection[0]
        ? colyseus_predict_attach_all(e->predict, state, collection,
              n > 0 ? fields : NULL, n, except_key[0] ? except_key : NULL, NULL)
        : -1;
    cJSON_Delete(root);
    return (double)rc;
}

/* spec: {"fields":["x","y"],"step_id":1,"step_params":{...},
 *        "smoothing":n,"substep_ms":n,"snap":n} */
GM_EXPORT double colyseus_gm_predict_attach_reckon(double predict_id, double instance,
                                                   const char* spec_json) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    colyseus_schema_t* inst = gm_instance(instance);
    cJSON* root = cJSON_Parse(spec_json ? spec_json : "");
    if (!e || !inst || !inst->__vtable || !root) { cJSON_Delete(root); return -1; }
    char csv[256];
    gm_spec_fields_csv(cJSON_GetObjectItem(root, "fields"), csv, sizeof(csv));
    char storage[GM_ATTACH_MAX_FIELDS][GM_NAME_MAX];
    const char* fields[GM_ATTACH_MAX_FIELDS];
    int n = gm_split_csv(csv, storage, fields, GM_ATTACH_MAX_FIELDS);
    int rc = -1;
    if (n > 0) {
        /* own params LAST: a failed attach must not burn an owned slot */
        gm_step_params_t* sp = gm_predict_own_params_spec(e, root);
        if (sp) rc = colyseus_predict_attach_reckon(e->predict, inst, inst->__vtable,
            fields, n, gm_builtin_reckon_step,
            gm_spec_num(root, "smoothing", 0),
            gm_spec_num(root, "substep_ms", 0),
            gm_spec_num(root, "snap", 0), sp);
    }
    cJSON_Delete(root);
    return (double)rc;
}

/* spec: attach_reckon's + {"collection":"bots"} */
GM_EXPORT double colyseus_gm_predict_attach_all_reckon(double predict_id,
    double state_instance, const char* spec_json) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    if (!e) return -1;
    colyseus_schema_t* state = gm_predict_state(e, state_instance);
    cJSON* root = cJSON_Parse(spec_json ? spec_json : "");
    if (!state || !root) { cJSON_Delete(root); return -1; }
    char collection[GM_NAME_MAX], csv[256];
    gm_spec_str(root, "collection", collection, sizeof(collection));
    gm_spec_fields_csv(cJSON_GetObjectItem(root, "fields"), csv, sizeof(csv));
    char storage[GM_ATTACH_MAX_FIELDS][GM_NAME_MAX];
    const char* fields[GM_ATTACH_MAX_FIELDS];
    int n = gm_split_csv(csv, storage, fields, GM_ATTACH_MAX_FIELDS);
    int rc = -1;
    if (n > 0 && collection[0]) {
        /* own params LAST: a failed attach must not burn an owned slot.
         * entry_vtable NULL: each entry reckons with its own vtable (the only
         * option for reflection-decoded schemas — GM's normal case) */
        gm_step_params_t* sp = gm_predict_own_params_spec(e, root);
        if (sp) rc = colyseus_predict_attach_all_reckon(e->predict, state, collection,
            NULL, fields, n, gm_builtin_reckon_step,
            gm_spec_num(root, "smoothing", 0),
            gm_spec_num(root, "substep_ms", 0),
            gm_spec_num(root, "snap", 0), sp);
    }
    cJSON_Delete(root);
    return (double)rc;
}

GM_EXPORT void colyseus_gm_predict_detach(double predict_id, double instance) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    colyseus_schema_t* inst = gm_instance(instance);
    if (e && inst) colyseus_predict_detach(e->predict, inst);
}

GM_EXPORT double colyseus_gm_predict_value(double predict_id, double instance, const char* field) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    colyseus_schema_t* inst = gm_instance(instance);
    if (!e || !inst) return NAN;
    return colyseus_predict_value(e->predict, inst, field);
}

GM_EXPORT double colyseus_gm_predict_value_at(double predict_id, double instance,
                                              const char* field, double time) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    colyseus_schema_t* inst = gm_instance(instance);
    if (!e || !inst) return NAN;
    return colyseus_predict_value_at(e->predict, inst, field, time);
}

// =============================================================================
// Reconciler + manual pump
// =============================================================================

static double gm_recon_register(colyseus_reconciler_t* r, gm_predict_entry_t* pe,
                                double predict_id) {
    if (!r) return 0;
    for (int i = 0; i < GM_MAX_RECONS; i++) {
        if (!g_recons[i].in_use) {
            g_recons[i].in_use = true;
            g_recons[i].room_ref = pe->room_ref;
            g_recons[i].predict_id = (int)predict_id;
            g_recons[i].recon = r;
            return (double)(i + 1);
        }
    }
    colyseus_reconciler_free(r);
    return 0;
}

static int gm_split_csv(const char* csv, char storage[][GM_NAME_MAX],
                        const char** out, int max) {
    int n = 0;
    if (!csv || !csv[0]) return 0;
    const char* p = csv;
    while (n < max && *p) {
        const char* comma = strchr(p, ',');
        size_t len = comma ? (size_t)(comma - p) : strlen(p);
        if (len >= GM_NAME_MAX) len = GM_NAME_MAX - 1;
        memcpy(storage[n], p, len);
        storage[n][len] = '\0';
        out[n] = storage[n];
        n++;
        p = comma ? comma + 1 : p + strlen(p);
    }
    return n;
}

#define GM_RECON_MAX_FIELDS 32

/* spec: {"fields":["x","y"]|"" (all numeric), "smoothing":n (-1 = default),
 *        "snap":n, "step_ms":n, "sub_steps":n} */
GM_EXPORT double colyseus_gm_predict_reconciler(double predict_id, double truth_instance,
    double input_h, const char* spec_json) {
    gm_predict_entry_t* e = gm_predict_entry(predict_id);
    colyseus_schema_t* truth = gm_instance(truth_instance);
    colyseus_input_handle_t* input =
        gm_input_resolve(input_h != 0 ? input_h : (double)(e ? e->room_ref : 0));
    if (!e || !truth || !truth->__vtable || !input) return 0;
    cJSON* root = cJSON_Parse(spec_json && spec_json[0] ? spec_json : "{}");
    if (!root) return 0;

    char csv[256];
    gm_spec_fields_csv(cJSON_GetObjectItem(root, "fields"), csv, sizeof(csv));
    char storage[GM_RECON_MAX_FIELDS][GM_NAME_MAX];
    const char* fields[GM_RECON_MAX_FIELDS];
    int n = gm_split_csv(csv, storage, fields, GM_RECON_MAX_FIELDS);

    colyseus_reconciler_options_t opts = {0};
    opts.smoothing = gm_spec_num(root, "smoothing", -1);
    opts.snap = gm_spec_num(root, "snap", 0);
    opts.step_ms = gm_spec_num(root, "step_ms", 0);
    opts.sub_steps = (int)gm_spec_num(root, "sub_steps", 0);
    opts.fields = n > 0 ? fields : NULL;
    opts.field_count = n;
    opts.manual_step = true;
    cJSON_Delete(root);
    colyseus_reconciler_t* r = colyseus_predict_reconciler(
        e->predict, truth, truth->__vtable, input, NULL, &opts);
    return gm_recon_register(r, e, predict_id);
}

/* sim composite: staged builder (no pointer arrays through the FFI) */
static struct {
    int predict_id;
    int part_count;
    colyseus_sim_part_t parts[8];
    char names[8][GM_NAME_MAX];
} g_sim_stage;

GM_EXPORT double colyseus_gm_sim_begin(double predict_id) {
    if (!gm_predict_entry(predict_id)) return 0;
    memset(&g_sim_stage, 0, sizeof(g_sim_stage));
    g_sim_stage.predict_id = (int)predict_id;
    return 1;
}

GM_EXPORT double colyseus_gm_sim_part(const char* name, double instance) {
    colyseus_schema_t* inst = gm_instance(instance);
    if (!g_sim_stage.predict_id || !name || !inst || !inst->__vtable) return 0;
    if (g_sim_stage.part_count >= 8) return 0;
    int i = g_sim_stage.part_count++;
    snprintf(g_sim_stage.names[i], GM_NAME_MAX, "%s", name);
    g_sim_stage.parts[i].name = g_sim_stage.names[i];
    g_sim_stage.parts[i].source = inst;
    g_sim_stage.parts[i].vtable = inst->__vtable;
    g_sim_stage.parts[i].opaque = NULL;
    return (double)g_sim_stage.part_count;
}

GM_EXPORT double colyseus_gm_sim_create(double input_h, double smoothing, double snap,
                                        double step_ms, double sub_steps) {
    gm_predict_entry_t* e = gm_predict_entry((double)g_sim_stage.predict_id);
    if (!e || g_sim_stage.part_count == 0) return 0;
    colyseus_input_handle_t* input =
        gm_input_resolve(input_h != 0 ? input_h : (double)e->room_ref);
    if (!input) return 0;
    colyseus_sim_reconciler_options_t opts = {0};
    opts.parts = g_sim_stage.parts;
    opts.part_count = g_sim_stage.part_count;
    opts.smoothing = smoothing;
    opts.snap = snap;
    opts.step_ms = step_ms;
    opts.sub_steps = (int)sub_steps;
    opts.manual_step = true;
    colyseus_reconciler_t* r = colyseus_predict_sim_reconciler(
        e->predict, input, NULL, &opts);
    double id = gm_recon_register(r, e, (double)g_sim_stage.predict_id);
    memset(&g_sim_stage, 0, sizeof(g_sim_stage));
    return id;
}

GM_EXPORT double colyseus_gm_sim_part_mirror(double recon_id, const char* name) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (!e) return 0;
    colyseus_sim_world_t* world = colyseus_sim_reconciler_world(e->recon);
    if (!world) return 0;
    void* part = colyseus_sim_world_part(world, name);
    return part ? (double)(uintptr_t)part : 0;
}

GM_EXPORT void colyseus_gm_recon_free(double recon_id) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (!e) return;
    colyseus_reconciler_free(e->recon);
    memset(e, 0, sizeof(*e));
}

/* the step being served between pump_next and pump_commit */
static struct {
    const colyseus_step_ctx_t* ctx;
    const colyseus_schema_t* cmd;
} g_cur_step;

GM_EXPORT double colyseus_gm_recon_pump_begin(double recon_id) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    return e ? (double)colyseus_reconciler_pump_begin(e->recon) : 0;
}

GM_EXPORT double colyseus_gm_recon_pump_next(double recon_id) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (!e) return 0;
    const colyseus_step_ctx_t* ctx = NULL;
    const colyseus_schema_t* cmd = colyseus_reconciler_pump_next(e->recon, &ctx);
    if (!cmd) return 0;
    g_cur_step.ctx = ctx;
    g_cur_step.cmd = cmd;
    return 1;
}

GM_EXPORT void colyseus_gm_recon_pump_commit(double recon_id) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (e) colyseus_reconciler_pump_commit(e->recon);
}

GM_EXPORT void colyseus_gm_recon_pump_end(double recon_id) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (e) colyseus_reconciler_pump_end(e->recon);
    g_cur_step.ctx = NULL;
    g_cur_step.cmd = NULL;
}

GM_EXPORT double colyseus_gm_step_ctx(double which) {
    const colyseus_step_ctx_t* ctx = g_cur_step.ctx;
    if (!ctx) return 0;
    switch ((int)which) {
        case 0: return ctx->dt;
        case 1: return ctx->dt_ms;
        case 2: return (double)ctx->tick;
        case 3: return (double)ctx->sub_steps;
        case 4: return ctx->sub_dt;
        case 5: return ctx->sub_dt_ms;
        case 6: return ctx->is_replay ? 1 : 0;
        case 7: return ctx->reckon_time;
        case 8: return ctx->lag_comp_active ? 1 : 0;
        default: return 0;
    }
}

GM_EXPORT double colyseus_gm_step_cmd(const char* field) {
    if (!g_cur_step.cmd) return NAN;
    return gm_field_read(g_cur_step.cmd, field);
}

GM_EXPORT double colyseus_gm_recon_value(double recon_id, const char* field_or_posekey) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    return e ? colyseus_reconciler_value(e->recon, field_or_posekey) : NAN;
}

GM_EXPORT double colyseus_gm_recon_state(double recon_id) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (!e) return 0;
    colyseus_schema_t* mirror = colyseus_reconciler_state(e->recon);
    return mirror ? (double)(uintptr_t)mirror : 0;
}

GM_EXPORT double colyseus_gm_recon_stat(double recon_id, double which) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (!e) return 0;
    switch ((int)which) {
        case 0: return (double)colyseus_reconciler_pending_count(e->recon);
        case 1: return colyseus_reconciler_step_ms(e->recon);
        case 2: return colyseus_reconciler_last_correction_mag(e->recon);
        case 3: return (double)colyseus_reconciler_reconcile_seq(e->recon);
        case 4: return colyseus_reconciler_drift(e->recon)->ema;
        case 5: return colyseus_reconciler_drift(e->recon)->peak;
        case 6: return (double)colyseus_drift_classify(colyseus_reconciler_drift(e->recon), 0.25);
        default: return 0;
    }
}

GM_EXPORT double colyseus_gm_recon_last_correction(double recon_id, const char* field) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    return e ? colyseus_reconciler_last_correction(e->recon, field) : 0;
}

GM_EXPORT void colyseus_gm_recon_reset(double recon_id) {
    gm_recon_entry_t* e = gm_recon_entry(recon_id);
    if (e) colyseus_reconciler_reset(e->recon);
}

GM_EXPORT double colyseus_gm_mirror_set(double instance, const char* field, double value) {
    return gm_field_write(gm_instance(instance), field, value) ? 1 : 0;
}

GM_EXPORT double colyseus_gm_mirror_get(double instance, const char* field) {
    return gm_field_read(gm_instance(instance), field);
}

// =============================================================================
// Step memo — peek/store split so GML computes only on live steps
// =============================================================================

static double gm_memo_nan_compute(void* userdata) {
    (void)userdata;
    return NAN;
}
static double gm_memo_value_compute(void* userdata) {
    return *(double*)userdata;
}

GM_EXPORT double colyseus_gm_step_memo_peek(const char* key) {
    if (!g_cur_step.ctx) return NAN;
    return colyseus_step_memo(g_cur_step.ctx, key, gm_memo_nan_compute, NULL);
}

GM_EXPORT double colyseus_gm_step_memo_store(const char* key, double value) {
    if (!g_cur_step.ctx) return NAN;
    double candidate = value;
    return colyseus_step_memo(g_cur_step.ctx, key, gm_memo_value_compute, &candidate);
}

// =============================================================================
// Optimistic events — settlement surfaces as polled queue events
// =============================================================================

static void gm_channel_push_settle(gm_channel_entry_t* e, int kind, const char* key) {
    gm_event_t event = {0};
    event.type = GM_EVENT_PREDICT_SETTLE;
    event.room_handle = (double)e->room_ref;
    event.callback_handle = (double)((e - g_channels) + 1);
    event.code = kind;
    strncpy(event.message, key ? key : "", sizeof(event.message) - 1);
    gm_event_queue_push(&event);
}

static void gm_ch_on_predict(void* payload, void* userdata) {
    gm_channel_push_settle((gm_channel_entry_t*)userdata, 0, (const char*)payload);
}
static void gm_ch_on_confirm(void* payload, void* userdata) {
    gm_channel_push_settle((gm_channel_entry_t*)userdata, 1, (const char*)payload);
}
static void gm_ch_on_reject(void* payload, void* userdata) {
    gm_channel_push_settle((gm_channel_entry_t*)userdata, 2, (const char*)payload);
}
static void gm_ch_on_unpredicted(const char* key, void* userdata) {
    gm_channel_push_settle((gm_channel_entry_t*)userdata, 3, key);
}

GM_EXPORT double colyseus_gm_events_create(double clock_h, double grace_ticks,
                                           double ttl_ms, double cooldown_ms) {
    gm_channel_entry_t* e = NULL;
    for (int i = 0; i < GM_MAX_CHANNELS; i++) {
        if (!g_channels[i].in_use) { e = &g_channels[i]; break; }
    }
    if (!e) return 0;
    memset(e, 0, sizeof(*e));
    colyseus_event_channel_options_t opts = {0};
    opts.on_predict = gm_ch_on_predict;
    opts.on_confirm = gm_ch_on_confirm;
    opts.on_reject = gm_ch_on_reject;
    opts.on_unpredicted = gm_ch_on_unpredicted;
    opts.payload_free = free;
    opts.grace_ticks = (int)grace_ticks;
    opts.ttl_ms = ttl_ms;
    opts.cooldown_ms = cooldown_ms;
    opts.userdata = e;
    colyseus_event_channel_t* ch =
        colyseus_event_channel_create(&opts, gm_clock_resolve(clock_h));
    if (!ch) return 0;
    e->in_use = true;
    e->room_ref = gm_is_room_ref(clock_h) ? (int)clock_h : 0;
    e->channel = ch;
    return (double)((e - g_channels) + 1);
}

GM_EXPORT void colyseus_gm_events_free(double channel_id) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    if (!e) return;
    /* undrive first: the predict's tick would otherwise walk freed memory */
    gm_predict_entry_t* pe = gm_predict_entry(e->predict_id);
    if (pe) colyseus_predict_undrive(pe->predict, e->channel);
    colyseus_event_channel_free(e->channel);
    memset(e, 0, sizeof(*e));
}

GM_EXPORT void colyseus_gm_predict_drive_events(double predict_id, double channel_id) {
    gm_predict_entry_t* pe = gm_predict_entry(predict_id);
    gm_channel_entry_t* ce = gm_channel_entry(channel_id);
    if (!pe || !ce) return;
    ce->predict_id = (int)predict_id;
    colyseus_predict_drive_events(pe->predict, ce->channel);
}

GM_EXPORT double colyseus_gm_events_predict(double channel_id, const char* key) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    if (!e || !key) return 0;
    char* payload = strdup(key);
    if (!colyseus_event_channel_predict(e->channel, key, payload)) {
        free(payload);
        return 0;
    }
    return 1;
}

GM_EXPORT void colyseus_gm_step_predict(double channel_id, const char* key) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    if (!e || !key || !g_cur_step.ctx) return;
    colyseus_step_predict(g_cur_step.ctx, e->channel, key, strdup(key));
}

GM_EXPORT double colyseus_gm_events_confirm(double channel_id, const char* key) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    if (!e) return 0;
    return (double)colyseus_event_channel_confirm(e->channel,
        (key && key[0]) ? key : NULL);
}

GM_EXPORT double colyseus_gm_events_reject(double channel_id, const char* key) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    if (!e) return 0;
    return (double)colyseus_event_channel_reject(e->channel,
        (key && key[0]) ? key : NULL);
}

GM_EXPORT double colyseus_gm_events_has(double channel_id, const char* key) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    if (!e) return 0;
    return colyseus_event_channel_has(e->channel, (key && key[0]) ? key : NULL) ? 1 : 0;
}

GM_EXPORT double colyseus_gm_events_pending(double channel_id) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    return e ? (double)colyseus_event_channel_pending_count(e->channel) : 0;
}

GM_EXPORT void colyseus_gm_events_clear(double channel_id) {
    gm_channel_entry_t* e = gm_channel_entry(channel_id);
    if (e) colyseus_event_channel_clear(e->channel);
}

// =============================================================================
// Predicted spawns
// =============================================================================

static bool gm_spawns_owned(colyseus_schema_t* server, void* userdata) {
    gm_spawns_entry_t* e = (gm_spawns_entry_t*)userdata;
    if (!e->owned_field[0]) return true;   /* everything correlatable */
    if (!server || !server->__vtable) return false;
    predict_fref_t f;
    if (!predict_vt_find(server->__vtable, e->owned_field, &f)) return false;
    if (f.type == COLYSEUS_FIELD_STRING) {
        /* string compare via the dynamic/static string read */
        if (colyseus_vtable_is_dynamic(server->__vtable)) {
            colyseus_dynamic_value_t* val = colyseus_dynamic_schema_get_by_name(
                (colyseus_dynamic_schema_t*)server, e->owned_field);
            return val && val->data.str && strcmp(val->data.str, e->owned_value) == 0;
        }
        const char* str = *(const char**)((const char*)server + f.offset);
        return str && strcmp(str, e->owned_value) == 0;
    }
    if (!predict_fref_scalar(&f)) return false;
    return predict_fread(server, &f) == atof(e->owned_value);
}

static double gm_spawns_spawn_time(colyseus_schema_t* server, void* userdata) {
    gm_spawns_entry_t* e = (gm_spawns_entry_t*)userdata;
    return gm_field_read(server, e->spawn_time_field);
}

static void gm_spawns_local_step(void* local, double dt, void* userdata) {
    gm_spawns_entry_t* e = (gm_spawns_entry_t*)userdata;
    if (e->step.id == 0) return;
    gm_axes_access_t ax = { axes_local_get, axes_local_set, NULL };
    gm_integrate(&e->step, local, &ax, dt);
}

static double gm_spawns_local_read(void* local, const char* field, void* userdata) {
    (void)userdata;
    return axes_local_get(local, field, NULL);
}

static void gm_spawns_on_reject(void* local, int id, void* userdata) {
    gm_spawns_entry_t* e = (gm_spawns_entry_t*)userdata;
    (void)local;
    gm_event_t event = {0};
    event.type = GM_EVENT_SPAWN_REJECT;
    event.room_handle = (double)e->room_ref;
    event.callback_handle = (double)((e - g_spawn_stores) + 1);
    event.code = id;
    gm_event_queue_push(&event);
}

/* spec: {"ttl_ms":n,"fields":["x","vx"],"owned_field":"owner",
 *        "owned_value":"<sid>","spawn_time_field":"bornMs",
 *        "step_id":1,"step_params":{...}} */
GM_EXPORT double colyseus_gm_spawns_create(double clock_h, const char* spec_json) {
    gm_spawns_entry_t* e = NULL;
    for (int i = 0; i < GM_MAX_SPAWN_STORES; i++) {
        if (!g_spawn_stores[i].in_use) { e = &g_spawn_stores[i]; break; }
    }
    if (!e) return 0;
    memset(e, 0, sizeof(*e));
    cJSON* root = cJSON_Parse(spec_json && spec_json[0] ? spec_json : "{}");
    if (!root) return 0;

    char csv[256];
    gm_spec_fields_csv(cJSON_GetObjectItem(root, "fields"), csv, sizeof(csv));
    char storage[GM_SPAWN_MAX_FIELDS][GM_NAME_MAX];
    const char* fields[GM_SPAWN_MAX_FIELDS];
    e->field_count = gm_split_csv(csv, storage, fields, GM_SPAWN_MAX_FIELDS);
    if (e->field_count == 0) { cJSON_Delete(root); return 0; }
    for (int i = 0; i < e->field_count; i++) {
        snprintf(e->fields[i], GM_NAME_MAX, "%s", storage[i]);
    }
    gm_spec_str(root, "owned_field", e->owned_field, GM_NAME_MAX);
    gm_spec_str(root, "owned_value", e->owned_value, sizeof(e->owned_value));
    gm_spec_str(root, "spawn_time_field", e->spawn_time_field, GM_NAME_MAX);
    gm_spec_step_params(root, &e->step);
    double ttl_ms = gm_spec_num(root, "ttl_ms", 0);
    cJSON_Delete(root);

    colyseus_spawns_options_t opts = {0};
    opts.owned = gm_spawns_owned;
    opts.spawn_time = e->spawn_time_field[0] ? gm_spawns_spawn_time : NULL;
    opts.has_spawn_time = e->spawn_time_field[0] != '\0';
    opts.step = gm_spawns_local_step;
    opts.local_read = gm_spawns_local_read;
    opts.ttl_ms = ttl_ms;
    opts.on_reject = gm_spawns_on_reject;
    opts.local_free = free;
    opts.userdata = e;
    colyseus_spawns_t* s = colyseus_spawns_create(&opts, gm_clock_resolve(clock_h));
    if (!s) return 0;
    e->in_use = true;
    e->room_ref = gm_is_room_ref(clock_h) ? (int)clock_h : 0;
    e->spawns = s;
    return (double)((e - g_spawn_stores) + 1);
}

GM_EXPORT void colyseus_gm_spawns_free(double spawns_id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e) return;
    /* undrive first: unhooks the predict's tick AND the collection
     * callbacks/reader a bind installed — a patch decoded after this free
     * must not reach the dead store */
    gm_predict_entry_t* pe = gm_predict_entry(e->predict_id);
    if (pe) colyseus_predict_undrive(pe->predict, e->spawns);
    colyseus_spawns_free(e->spawns);
    memset(e, 0, sizeof(*e));
}

GM_EXPORT void colyseus_gm_predict_bind_spawns(double predict_id, double spawns_id,
    double state_instance, const char* collection) {
    gm_predict_entry_t* pe = gm_predict_entry(predict_id);
    gm_spawns_entry_t* se = gm_spawns_entry(spawns_id);
    if (!pe || !se) return;
    colyseus_schema_t* state = gm_instance(state_instance);
    if (!state && pe->room_ref) {
        colyseus_room_t* room = gm_room_ref_get(pe->room_ref);
        if (room) state = (colyseus_schema_t*)colyseus_room_get_state(room);
    }
    if (!state) return;
    se->predict_id = (int)predict_id;
    if (se->step.id > 0 && se->field_count > 0) {
        /* the store's step also RECKONS confirmed entities: forward by
         * snapshot age + the entry's measured lead, so an owned projectile
         * keeps the shooter's timeline through the handoff instead of
         * snapping back to the (older) authoritative snapshot */
        for (int i = 0; i < se->field_count; i++) se->field_ptrs[i] = se->fields[i];
        colyseus_spawns_reckon_t reckon = {0};
        reckon.entry_vtable = NULL;        /* per-entry — reflection-decoded */
        reckon.fields = se->field_ptrs;
        reckon.field_count = se->field_count;
        reckon.step = gm_builtin_reckon_step;
        reckon.smoothing = 0;              /* raw projection: exact for constant-step motion */
        reckon.substep_ms = 0;             /* -> 16 */
        reckon.userdata = &se->step;
        colyseus_predict_bind_spawns(pe->predict, se->spawns, state, collection, &reckon);
        return;
    }
    colyseus_predict_bind_spawns(pe->predict, se->spawns, state, collection, NULL);
}

GM_EXPORT double colyseus_gm_spawns_spawn_set(double spawns_id, const char* field, double value) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e) return 0;
    int idx = gm_spawn_field_index(e, field);
    if (idx < 0) return 0;
    e->staging[idx] = value;
    return 1;
}

GM_EXPORT double colyseus_gm_spawns_spawn(double spawns_id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e) return 0;
    gm_spawn_local_t* local = malloc(sizeof(gm_spawn_local_t));
    if (!local) return 0;
    local->owner = e;
    memcpy(local->v, e->staging, sizeof(e->staging));
    memset(e->staging, 0, sizeof(e->staging));
    int id = colyseus_spawns_spawn(e->spawns, local);
    if (id <= 0) { free(local); return 0; }
    return (double)id;
}

GM_EXPORT void colyseus_gm_spawns_cancel(double spawns_id, double id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (e) colyseus_spawns_cancel(e->spawns, (int)id);
}

GM_EXPORT void colyseus_gm_spawns_accept(double spawns_id, double id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (e) colyseus_spawns_accept(e->spawns, (int)id);
}

GM_EXPORT double colyseus_gm_spawns_size(double spawns_id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    return e ? (double)colyseus_spawns_size(e->spawns) : 0;
}

GM_EXPORT double colyseus_gm_spawns_alive(double spawns_id, double id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    return (e && colyseus_spawns_alive(e->spawns, (int)id)) ? 1 : 0;
}

/* test-facing seams (production adds/removes flow through bind_spawns) */
GM_EXPORT void colyseus_gm_spawns_handle_add(double spawns_id, double server_instance) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (e) colyseus_spawns_handle_add(e->spawns, gm_instance(server_instance));
}

GM_EXPORT void colyseus_gm_spawns_handle_remove(double spawns_id, double server_instance) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (e) colyseus_spawns_handle_remove(e->spawns, gm_instance(server_instance));
}

GM_EXPORT void colyseus_gm_spawns_tick(double spawns_id, double now) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (e) {
        colyseus_spawns_tick(e->spawns, now);
        colyseus_spawns_prune(e->spawns);
    }
}

/* iteration: begin/next cursor + accessors on the current entry */
GM_EXPORT double colyseus_gm_spawns_iter_begin(double spawns_id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e) return 0;
    e->cur = colyseus_spawns_first(e->spawns);
    e->iter_primed = true;
    return e->cur ? 1 : 0;
}

GM_EXPORT double colyseus_gm_spawns_iter_next(double spawns_id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e || !e->cur) return 0;
    e->cur = colyseus_spawns_next(e->spawns, e->cur);
    return e->cur ? 1 : 0;
}

GM_EXPORT double colyseus_gm_spawns_entry_stat(double spawns_id, double which) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e || !e->cur) return 0;
    switch ((int)which) {
        case 0: return (double)e->cur->id;
        case 1: return e->cur->confirmed ? 1 : 0;
        case 2: return e->cur->lead_ms;
        case 3: return e->cur->server ? (double)(uintptr_t)e->cur->server : 0;
        case 4: return e->cur->local ? 1 : 0;
        default: return 0;
    }
}

GM_EXPORT double colyseus_gm_spawns_entry_value(double spawns_id, const char* field) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e || !e->cur) return NAN;
    return colyseus_spawns_value(e->spawns, e->cur, field);
}

/* random access by id (post-iteration reads without re-walking) */
GM_EXPORT double colyseus_gm_spawns_seek(double spawns_id, double id) {
    gm_spawns_entry_t* e = gm_spawns_entry(spawns_id);
    if (!e) return 0;
    for (const colyseus_spawn_entry_t* it = colyseus_spawns_first(e->spawns);
         it; it = colyseus_spawns_next(e->spawns, it)) {
        if (it->id == (int)id) { e->cur = it; return 1; }
    }
    return 0;
}

// =============================================================================
// Netdelay injector
// =============================================================================

GM_EXPORT void colyseus_gm_netdelay_set(double room_ref, double delay_ms, double jitter_ms) {
    colyseus_room_t* room = gm_room_ref_get((int)room_ref);
    if (room) colyseus_netdelay_set(room, delay_ms, jitter_ms);
}

GM_EXPORT void colyseus_gm_netdelay_pump(void) {
    colyseus_netdelay_pump();
}

GM_EXPORT double colyseus_gm_netdelay_in_flight(void) {
    return (double)colyseus_netdelay_in_flight();
}

GM_EXPORT void colyseus_gm_netdelay_drop(double room_ref) {
    colyseus_room_t* room = gm_room_ref_get((int)room_ref);
    if (room) colyseus_netdelay_drop(room);
}

// =============================================================================
// Room-release sweep (called by gamemaker_export.c)
// =============================================================================

void gm_predict_room_released(int room_ref) {
    if (room_ref < 1) return;
    for (int i = 0; i < GM_MAX_RECONS; i++) {
        if (g_recons[i].in_use && g_recons[i].room_ref == room_ref) {
            colyseus_reconciler_free(g_recons[i].recon);
            memset(&g_recons[i], 0, sizeof(g_recons[i]));
        }
    }
    for (int i = 0; i < GM_MAX_SPAWN_STORES; i++) {
        if (g_spawn_stores[i].in_use && g_spawn_stores[i].room_ref == room_ref) {
            colyseus_spawns_free(g_spawn_stores[i].spawns);
            memset(&g_spawn_stores[i], 0, sizeof(g_spawn_stores[i]));
        }
    }
    for (int i = 0; i < GM_MAX_CHANNELS; i++) {
        if (g_channels[i].in_use && g_channels[i].room_ref == room_ref) {
            colyseus_event_channel_free(g_channels[i].channel);
            memset(&g_channels[i], 0, sizeof(g_channels[i]));
        }
    }
    for (int i = 0; i < GM_MAX_PREDICTS; i++) {
        if (g_predicts[i].in_use && g_predicts[i].room_ref == room_ref) {
            gm_predict_entry_free(&g_predicts[i]);
        }
    }
}
