/*
 * Flutter FFI helpers that the generated core bindings can't express directly.
 *
 * Everything here is leaf-safe (never calls back into Dart) so the Dart side
 * can declare these with isLeaf: true and pay ~ns per call on the render path.
 *
 * Three jobs:
 *   1. Bridge the glue's 1-based room refs to the core `colyseus_room_t*` the
 *      0.18 headers take.
 *   2. Scalar field access by resolved index — one FFI call per read, no name
 *      marshalling, no union decoding in Dart.
 *   3. Collection snapshots — uthash-backed maps have no ordinal accessor, so
 *      iteration goes through foreach into a scratch buffer the Dart side then
 *      indexes.
 */

#include "colyseus/room.h"
#include "colyseus/schema.h"
#include "colyseus/schema/collections.h"
#include "colyseus/schema/dynamic_schema.h"
#include "colyseus/net_delay.h"
#include "colyseus/input_handle.h"
#include "colyseus/room_clock.h"
#include "colyseus/predict/predict.h"
#include "colyseus/predict/reconciler.h"
#include "colyseus/predict/events.h"
#include "colyseus/predict/spawns.h"

#include "../../../src/predict/field_access.h"
#include "flutter_colyseus.h"

#include <stdlib.h>
#include <string.h>

/* Provided by flutter_export.c — the glue owns the room-ref table. */
colyseus_room_t* flutter_room_from_ref(int ref);

/* =============================================================================
 * Link anchors
 * ========================================================================== */

/*
 * Dart resolves the core's symbols by name at runtime, so nothing in this
 * library references the predict layer at link time — and a linker drops
 * archive members that nothing references. Without these the predict, input
 * and clock objects never make it into the shared library and every
 * colyseus_predict_* lookup fails with "symbol not found".
 *
 * A reference to any symbol pulls in that symbol's whole object file, so one
 * entry per translation unit is enough.
 */
FLUTTER_EXPORT const void* const colyseus_flutter_link_anchors[] = {
    (const void*)&colyseus_predict_for_room,        /* src/predict/predict.c */
    (const void*)&colyseus_reconciler_create,       /* src/predict/reconciler.c */
    (const void*)&colyseus_event_channel_create,    /* src/predict/events.c */
    (const void*)&colyseus_spawns_create,           /* src/predict/spawns.c */
    (const void*)&colyseus_room_input,              /* src/input_handle.c */
    (const void*)&colyseus_room_clock_create,       /* src/room_clock.c */
    (const void*)&colyseus_netdelay_pump,           /* src/network/net_delay.c */
};

/* Count, so a caller can assert the table linked rather than being folded. */
FLUTTER_EXPORT int colyseus_flutter_link_anchor_count(void) {
    return (int)(sizeof(colyseus_flutter_link_anchors) /
                 sizeof(colyseus_flutter_link_anchors[0]));
}

/* =============================================================================
 * Room bridge
 * ========================================================================== */

/*
 * The core pointer behind a glue room ref, as an integer Dart can hold.
 * 0 when the ref is stale or the join hasn't resolved yet.
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_room_ptr(int room_handle) {
    return (intptr_t)flutter_room_from_ref(room_handle);
}

/* =============================================================================
 * Scalar field access
 * ========================================================================== */

/*
 * Resolve `name` against the instance's vtable so later reads/writes can skip
 * the lookup. Returns the field index (dynamic hash key or static table slot),
 * or -1 when the field is unknown.
 *
 * out_type receives the colyseus_field_type_t, out_offset the struct offset
 * (0 for dynamic instances). Dart caches the triple per (view, field).
 */
FLUTTER_EXPORT int colyseus_flutter_field_resolve(intptr_t instance, const char* name,
    int* out_type, int* out_offset)
{
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    if (!inst || !inst->__vtable || !name) return -1;

    predict_fref_t f;
    if (!predict_vt_find(inst->__vtable, name, &f)) return -1;

    if (out_type) *out_type = (int)f.type;
    if (out_offset) *out_offset = (int)f.offset;
    return f.index;
}

/*
 * The instance's vtable, which the reconciler and reckon APIs require to build
 * their mirrors. Reflection-derived schemas have no statically known vtable —
 * each instance carries its own — so it has to be read off the instance.
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_instance_vtable(intptr_t instance) {
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    return inst ? (intptr_t)inst->__vtable : 0;
}

/* Field count on the instance's vtable, either storage model. */
FLUTTER_EXPORT int colyseus_flutter_field_count(intptr_t instance) {
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    if (!inst || !inst->__vtable) return 0;
    return predict_vt_count(inst->__vtable);
}

/* The i-th declared field's name (borrowed from the vtable), or "" for a hole. */
FLUTTER_EXPORT const char* colyseus_flutter_field_name_at(intptr_t instance, int i) {
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    if (!inst || !inst->__vtable) return "";

    predict_fref_t f;
    if (!predict_vt_at(inst->__vtable, i, &f)) return "";
    return f.name ? f.name : "";
}

FLUTTER_EXPORT double colyseus_flutter_field_get_number(intptr_t instance,
    int type, int offset, int index)
{
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    if (!inst) return 0.0;
    return predict_scalar_read(inst, (colyseus_field_type_t)type, (size_t)offset, index);
}

FLUTTER_EXPORT void colyseus_flutter_field_set_number(intptr_t instance,
    int type, int offset, int index, double value)
{
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    if (!inst) return;
    predict_scalar_write(inst, (colyseus_field_type_t)type, (size_t)offset, index, NULL, value);
}

/*
 * String read by resolved field. Returns "" rather than NULL so Dart can
 * convert unconditionally; the pointer is borrowed and only valid until the
 * next decode touches this instance.
 */
FLUTTER_EXPORT const char* colyseus_flutter_field_get_string(intptr_t instance,
    int offset, int index)
{
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    if (!inst || !inst->__vtable) return "";

    if (colyseus_vtable_is_dynamic(inst->__vtable)) {
        colyseus_dynamic_value_t* v =
            colyseus_dynamic_schema_get((colyseus_dynamic_schema_t*)inst, index);
        return (v && v->type == COLYSEUS_FIELD_STRING && v->data.str) ? v->data.str : "";
    }

    const char* str = *(const char**)((const char*)inst + (size_t)offset);
    return str ? str : "";
}

/* Ref/array/map child pointer by resolved field, as an integer handle. */
FLUTTER_EXPORT intptr_t colyseus_flutter_field_get_ref(intptr_t instance,
    int offset, int index)
{
    colyseus_schema_t* inst = (colyseus_schema_t*)instance;
    if (!inst || !inst->__vtable) return 0;

    if (colyseus_vtable_is_dynamic(inst->__vtable)) {
        colyseus_dynamic_value_t* v =
            colyseus_dynamic_schema_get((colyseus_dynamic_schema_t*)inst, index);
        return v ? (intptr_t)v->data.ptr : 0;
    }

    return (intptr_t)*(void**)((const char*)inst + (size_t)offset);
}

/* =============================================================================
 * Collection snapshots
 * ========================================================================== */

/*
 * Maps store items in a uthash table with no ordinal accessor, so iteration
 * has to go through foreach. One snapshot buffer serves the whole binding:
 * Dart calls snapshot() then reads entries by ordinal, all within one frame
 * on the isolate thread. Entries borrow the collection's own key/value
 * pointers — they go stale as soon as the next decode runs.
 */
typedef struct {
    const char* key;    /* borrowed; NULL for arrays */
    int index;          /* array ordinal, or the map item's decode index */
    void* value;        /* borrowed */
} flutter_coll_entry_t;

static flutter_coll_entry_t* g_coll_entries = NULL;
static int g_coll_count = 0;
static int g_coll_capacity = 0;
/* colyseus_field_type_t of the snapshot's children; -1 when schema-typed. */
static int g_coll_primitive = -1;
static bool g_coll_has_schema_child = false;

static void coll_reset(int hint) {
    g_coll_count = 0;
    if (hint > g_coll_capacity) {
        int cap = g_coll_capacity ? g_coll_capacity : 16;
        while (cap < hint) cap *= 2;
        flutter_coll_entry_t* grown =
            (flutter_coll_entry_t*)realloc(g_coll_entries, (size_t)cap * sizeof(*grown));
        if (!grown) return;
        g_coll_entries = grown;
        g_coll_capacity = cap;
    }
}

static void coll_push(const char* key, int index, void* value) {
    if (g_coll_count >= g_coll_capacity) return;
    g_coll_entries[g_coll_count].key = key;
    g_coll_entries[g_coll_count].index = index;
    g_coll_entries[g_coll_count].value = value;
    g_coll_count++;
}

static void coll_map_visit(const char* key, void* value, void* userdata) {
    (void)userdata;
    coll_push(key, g_coll_count, value);
}

static void coll_array_visit(int index, void* value, void* userdata) {
    (void)userdata;
    coll_push(NULL, index, value);
}

/*
 * Snapshot a map or array into the scratch buffer. `is_map` selects the
 * accessor. Returns the entry count.
 */
FLUTTER_EXPORT int colyseus_flutter_collection_snapshot(intptr_t collection, int is_map) {
    if (!collection) {
        g_coll_count = 0;
        return 0;
    }

    if (is_map) {
        colyseus_map_schema_t* map = (colyseus_map_schema_t*)collection;
        coll_reset(map->count);
        g_coll_has_schema_child = map->has_schema_child;
        g_coll_primitive = map->child_primitive_type
            ? (int)colyseus_field_type_from_string(map->child_primitive_type)
            : -1;
        colyseus_map_schema_foreach(map, coll_map_visit, NULL);
    } else {
        colyseus_array_schema_t* arr = (colyseus_array_schema_t*)collection;
        coll_reset(arr->count);
        g_coll_has_schema_child = arr->has_schema_child;
        g_coll_primitive = arr->child_primitive_type
            ? (int)colyseus_field_type_from_string(arr->child_primitive_type)
            : -1;
        colyseus_array_schema_foreach(arr, coll_array_visit, NULL);
    }

    return g_coll_count;
}

/*
 * Child kind of the last snapshot: 1 = schema instances (read via
 * entry_ref), 0 = primitives (read via entry_number / entry_string).
 */
FLUTTER_EXPORT int colyseus_flutter_collection_has_schema_child(void) {
    return g_coll_has_schema_child ? 1 : 0;
}

/* colyseus_field_type_t of the last snapshot's primitive children (-1 if none). */
FLUTTER_EXPORT int colyseus_flutter_collection_primitive_type(void) {
    return g_coll_primitive;
}

FLUTTER_EXPORT const char* colyseus_flutter_collection_entry_key(int ordinal) {
    if (ordinal < 0 || ordinal >= g_coll_count) return "";
    const char* key = g_coll_entries[ordinal].key;
    return key ? key : "";
}

FLUTTER_EXPORT int colyseus_flutter_collection_entry_index(int ordinal) {
    if (ordinal < 0 || ordinal >= g_coll_count) return -1;
    return g_coll_entries[ordinal].index;
}

FLUTTER_EXPORT intptr_t colyseus_flutter_collection_entry_ref(int ordinal) {
    if (ordinal < 0 || ordinal >= g_coll_count) return 0;
    return (intptr_t)g_coll_entries[ordinal].value;
}

/* Unbox a primitive value cell against a colyseus_field_type_t. */
static double primitive_as_number(void* value, int type) {
    if (!value) return 0.0;
    switch ((colyseus_field_type_t)type) {
        case COLYSEUS_FIELD_BOOLEAN: return *(bool*)value ? 1.0 : 0.0;
        case COLYSEUS_FIELD_FLOAT32: return (double)*(float*)value;
        case COLYSEUS_FIELD_INT8:    return (double)*(int8_t*)value;
        case COLYSEUS_FIELD_UINT8:   return (double)*(uint8_t*)value;
        case COLYSEUS_FIELD_INT16:   return (double)*(int16_t*)value;
        case COLYSEUS_FIELD_UINT16:  return (double)*(uint16_t*)value;
        case COLYSEUS_FIELD_INT32:   return (double)*(int32_t*)value;
        case COLYSEUS_FIELD_UINT32:  return (double)*(uint32_t*)value;
        case COLYSEUS_FIELD_INT64:   return (double)*(int64_t*)value;
        case COLYSEUS_FIELD_UINT64:  return (double)*(uint64_t*)value;
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT64: return *(double*)value;
        default:                     return 0.0;
    }
}

FLUTTER_EXPORT double colyseus_flutter_collection_entry_number(int ordinal) {
    if (ordinal < 0 || ordinal >= g_coll_count) return 0.0;
    return primitive_as_number(g_coll_entries[ordinal].value, g_coll_primitive);
}

FLUTTER_EXPORT const char* colyseus_flutter_collection_entry_string(int ordinal) {
    if (ordinal < 0 || ordinal >= g_coll_count) return "";
    if (g_coll_primitive != COLYSEUS_FIELD_STRING) return "";
    const char* str = (const char*)g_coll_entries[ordinal].value;
    return str ? str : "";
}

/*
 * Direct key lookup — cheaper than a snapshot when the caller wants one item.
 * Schema children only; primitives need the snapshot path for their type tag.
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_collection_get(intptr_t collection, int is_map,
    const char* key, int index)
{
    if (!collection) return 0;
    if (is_map) {
        if (!key) return 0;
        return (intptr_t)colyseus_map_schema_get((colyseus_map_schema_t*)collection, key);
    }
    return (intptr_t)colyseus_array_schema_get((colyseus_array_schema_t*)collection, index);
}

FLUTTER_EXPORT int colyseus_flutter_collection_count(intptr_t collection, int is_map) {
    if (!collection) return 0;
    return is_map ? ((colyseus_map_schema_t*)collection)->count
                  : ((colyseus_array_schema_t*)collection)->count;
}

FLUTTER_EXPORT int colyseus_flutter_collection_contains(intptr_t collection, const char* key) {
    if (!collection || !key) return 0;
    return colyseus_map_schema_contains((colyseus_map_schema_t*)collection, key) ? 1 : 0;
}
