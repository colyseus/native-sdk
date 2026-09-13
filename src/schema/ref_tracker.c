#include "colyseus/schema/ref_tracker.h"
#include "colyseus/schema/collections.h"
#include "colyseus/schema/dynamic_schema.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Forward declaration for recursive removal */
static void schedule_children_for_removal(colyseus_ref_tracker_t* tracker, colyseus_ref_entry_t* entry);

/* Address of a pointer-typed field (string, ref, array or map) in an instance. */
static void** schema_field_slot(void* instance, const colyseus_field_t* field) {
    return (void**)((char*)instance + field->offset);
}

void colyseus_schema_free_string_fields(colyseus_schema_t* instance) {
    const colyseus_schema_vtable_t* vt = instance ? instance->__vtable : NULL;
    if (!vt || colyseus_vtable_is_dynamic(vt)) return;
    for (int i = 0; i < vt->field_count; i++) {
        const colyseus_field_t* f = &vt->fields[i];
        if (f->type != COLYSEUS_FIELD_STRING) continue;
        char** slot = (char**)schema_field_slot(instance, f);
        free(*slot);
        *slot = NULL;
    }
}

/* Drop the tracker's handle on a ref we just destroyed, so nothing frees it twice. */
static void ref_tracker_forget(colyseus_ref_tracker_t* tracker, int ref_id) {
    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);
    if (entry) entry->ref = NULL;
}

/* One instance can sit at two indices of an array, or in two collections — the
 * wire references it by refId. Destroying per slot would free it twice, and the
 * alias pass below needs these pointers after the fact. */
typedef struct destroyed_ref {
    void* ptr;
    UT_hash_handle hh;
} destroyed_ref_t;

static bool ref_seen(destroyed_ref_t* set, void* ptr) {
    destroyed_ref_t* found = NULL;
    HASH_FIND_PTR(set, &ptr, found);
    return found != NULL;
}

/* The vtable of a live codegen-backed schema entry; NULL for anything the
 * static teardown must leave alone — already freed, a collection, or dynamic. */
static const colyseus_schema_vtable_t* static_schema_vtable(const colyseus_ref_entry_t* entry) {
    if (!entry->ref || entry->ref_type != COLYSEUS_REF_TYPE_SCHEMA) return NULL;
    if (!entry->vtable || colyseus_vtable_is_dynamic(entry->vtable)) return NULL;
    return entry->vtable;
}

typedef struct {
    colyseus_ref_tracker_t* tracker;
    const colyseus_schema_vtable_t* child_vtable;
    destroyed_ref_t* destroyed;
} destroy_children_ctx_t;

static void destroy_collection_child(colyseus_schema_t* instance, destroy_children_ctx_t* ctx) {
    if (!instance) return;
    /* must precede every read of *instance: on a repeat it is already freed */
    if (ref_seen(ctx->destroyed, instance)) return;
    const colyseus_schema_vtable_t* vt = instance->__vtable ? instance->__vtable : ctx->child_vtable;
    if (!vt || colyseus_vtable_is_dynamic(vt) || !vt->destroy) return;
    destroyed_ref_t* mark = malloc(sizeof(destroyed_ref_t));
    if (!mark) return;   /* without the marker a repeat would double-free; leak instead */
    mark->ptr = instance;
    HASH_ADD_PTR(ctx->destroyed, ptr, mark);
    int ref_id = instance->__refId;
    colyseus_schema_free_string_fields(instance);
    vt->destroy(instance);
    ref_tracker_forget(ctx->tracker, ref_id);
}

static void destroy_map_child(const char* key, void* value, void* userdata) {
    (void)key;
    destroy_collection_child((colyseus_schema_t*)value, (destroy_children_ctx_t*)userdata);
}

static void destroy_array_child(int index, void* value, void* userdata) {
    (void)index;
    destroy_collection_child((colyseus_schema_t*)value, (destroy_children_ctx_t*)userdata);
}

void colyseus_ref_tracker_destroy_static_refs(colyseus_ref_tracker_t* tracker, void* except_ref) {
    if (!tracker) return;
    colyseus_ref_entry_t* entry;
    colyseus_ref_entry_t* tmp;
    destroy_children_ctx_t ctx = { tracker, NULL, NULL };

    /*
     * Pass 1 — strings, freed and NULLed up front. Codegen's destroy() frees
     * its own char* fields too, so clearing the slot is what stops the two
     * from colliding on an instance this walk also destroys.
     */
    HASH_ITER(hh, tracker->refs, entry, tmp) {
        if (!static_schema_vtable(entry)) continue;
        colyseus_schema_free_string_fields((colyseus_schema_t*)entry->ref);
    }

    /*
     * Pass 2 — collections and the entries they hold. This is the ONLY orphaned
     * part: codegen's destroy() recurses into t.ref() children (so the root
     * frees those itself) but never into a map or array, so its items and the
     * collection structure would otherwise be lost.
     */
    HASH_ITER(hh, tracker->refs, entry, tmp) {
        if (!entry->ref || entry->ref == except_ref) continue;
        if (entry->ref_type == COLYSEUS_REF_TYPE_MAP) {
            colyseus_map_schema_t* map = (colyseus_map_schema_t*)entry->ref;
            if (map->has_schema_child) {
                ctx.child_vtable = map->child_vtable;
                colyseus_map_schema_foreach(map, destroy_map_child, &ctx);
            }
            entry->ref = NULL;
            colyseus_map_schema_free(map, NULL);
        } else if (entry->ref_type == COLYSEUS_REF_TYPE_ARRAY) {
            colyseus_array_schema_t* arr = (colyseus_array_schema_t*)entry->ref;
            if (arr->has_schema_child) {
                ctx.child_vtable = arr->child_vtable;
                colyseus_array_schema_foreach(arr, destroy_array_child, &ctx);
            }
            entry->ref = NULL;
            colyseus_array_schema_free(arr, NULL);
        }
    }

    /*
     * A t.ref() field can point at an instance we just destroyed as a
     * collection child — the same Player is both players["id"] and host.
     * Codegen's destroy() frees what its ref fields point at, so clear those
     * aliases before the caller's root destroy runs, or it frees them again.
     */
    if (ctx.destroyed) {
        HASH_ITER(hh, tracker->refs, entry, tmp) {
            const colyseus_schema_vtable_t* vt = static_schema_vtable(entry);
            if (!vt || !vt->fields) continue;
            for (int i = 0; i < vt->field_count; i++) {
                if (vt->fields[i].type != COLYSEUS_FIELD_REF) continue;
                void** slot = schema_field_slot(entry->ref, &vt->fields[i]);
                if (*slot && ref_seen(ctx.destroyed, *slot)) *slot = NULL;
            }
        }
    }

    destroyed_ref_t* mark;
    destroyed_ref_t* mark_tmp;
    HASH_ITER(hh, ctx.destroyed, mark, mark_tmp) {
        HASH_DEL(ctx.destroyed, mark);
        free(mark);
    }
}

colyseus_ref_tracker_t* colyseus_ref_tracker_create(void) {
    colyseus_ref_tracker_t* tracker = malloc(sizeof(colyseus_ref_tracker_t));
    if (!tracker) return NULL;

    tracker->refs = NULL;
    tracker->deleted = NULL;
    tracker->collect_count = 0;

    return tracker;
}

bool colyseus_ref_tracker_add_collect_listener(colyseus_ref_tracker_t* tracker,
    colyseus_ref_collect_fn listener, void* userdata) {
    if (!tracker || !listener) return false;
    for (int i = 0; i < tracker->collect_count; i++) {
        if (tracker->collect_listeners[i] == listener && tracker->collect_userdata[i] == userdata) return true;
    }
    if (tracker->collect_count >= COLYSEUS_REF_TRACKER_MAX_COLLECT_LISTENERS) {
        fprintf(stderr, "colyseus-schema: ref tracker already has %d collect listeners; this one is NOT registered.\n",
            COLYSEUS_REF_TRACKER_MAX_COLLECT_LISTENERS);
        return false;
    }
    tracker->collect_listeners[tracker->collect_count] = listener;
    tracker->collect_userdata[tracker->collect_count] = userdata;
    tracker->collect_count++;
    return true;
}

void colyseus_ref_tracker_remove_collect_listener(colyseus_ref_tracker_t* tracker,
    colyseus_ref_collect_fn listener, void* userdata) {
    if (!tracker) return;
    for (int i = 0; i < tracker->collect_count; i++) {
        if (tracker->collect_listeners[i] != listener || tracker->collect_userdata[i] != userdata) continue;
        for (int j = i + 1; j < tracker->collect_count; j++) {
            tracker->collect_listeners[j - 1] = tracker->collect_listeners[j];
            tracker->collect_userdata[j - 1] = tracker->collect_userdata[j];
        }
        tracker->collect_count--;
        return;
    }
}

void colyseus_ref_tracker_free(colyseus_ref_tracker_t* tracker) {
    if (!tracker) return;

    colyseus_ref_tracker_clear(tracker);
    free(tracker);
}

void colyseus_ref_tracker_add(colyseus_ref_tracker_t* tracker, int ref_id, void* ref,
    colyseus_ref_type_t ref_type, const colyseus_schema_vtable_t* vtable, bool increment_count) {
    if (!tracker) return;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    if (entry) {
        /* Update existing entry */
        entry->ref = ref;
        entry->ref_type = ref_type;
        entry->vtable = vtable;
        if (increment_count) {
            entry->ref_count++;
        }
    } else {
        /* Create new entry */
        entry = malloc(sizeof(colyseus_ref_entry_t));
        if (!entry) return;

        entry->ref_id = ref_id;
        entry->ref = ref;
        entry->ref_count = increment_count ? 1 : 0;
        entry->ref_type = ref_type;
        entry->vtable = vtable;

        HASH_ADD_INT(tracker->refs, ref_id, entry);
    }

    /* Remove from deleted list if present */
    colyseus_deleted_ref_t** curr = &tracker->deleted;
    while (*curr) {
        if ((*curr)->ref_id == ref_id) {
            colyseus_deleted_ref_t* to_delete = *curr;
            *curr = (*curr)->next;
            free(to_delete);
            break;
        }
        curr = &(*curr)->next;
    }
}

void* colyseus_ref_tracker_get(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return NULL;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    return entry ? entry->ref : NULL;
}

colyseus_ref_entry_t* colyseus_ref_tracker_get_entry(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return NULL;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    return entry;
}

bool colyseus_ref_tracker_has(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return false;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    return entry != NULL;
}

size_t colyseus_ref_tracker_count(colyseus_ref_tracker_t* tracker) {
    if (!tracker) return 0;
    return (size_t)HASH_COUNT(tracker->refs);
}

bool colyseus_ref_tracker_remove(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return false;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    if (!entry) {
        /* Not an error - might already be removed */
        return false;
    }

    entry->ref_count--;

    if (entry->ref_count <= 0) {
        /* Schedule for garbage collection */
        colyseus_deleted_ref_t* deleted = malloc(sizeof(colyseus_deleted_ref_t));
        if (deleted) {
            deleted->ref_id = ref_id;
            deleted->next = tracker->deleted;
            tracker->deleted = deleted;
        }
        return true;
    }

    return false;
}

/* Helper: check if ref_id is already in deleted list */
static bool is_in_deleted_list(colyseus_ref_tracker_t* tracker, int ref_id) {
    colyseus_deleted_ref_t* curr = tracker->deleted;
    while (curr) {
        if (curr->ref_id == ref_id) return true;
        curr = curr->next;
    }
    return false;
}

/* Callback for array iteration during GC */
typedef struct {
    colyseus_ref_tracker_t* tracker;
    bool has_schema_child;
} gc_foreach_ctx_t;

static void gc_array_foreach(int index, void* value, void* userdata) {
    (void)index;
    gc_foreach_ctx_t* ctx = (gc_foreach_ctx_t*)userdata;
    if (ctx->has_schema_child && value) {
        colyseus_schema_t* child = (colyseus_schema_t*)value;
        colyseus_ref_tracker_remove(ctx->tracker, child->__refId);
    }
}

static void gc_map_foreach(const char* key, void* value, void* userdata) {
    (void)key;
    gc_foreach_ctx_t* ctx = (gc_foreach_ctx_t*)userdata;
    if (ctx->has_schema_child && value) {
        colyseus_schema_t* child = (colyseus_schema_t*)value;
        colyseus_ref_tracker_remove(ctx->tracker, child->__refId);
    }
}

/* Schedule children of a ref for removal */
static void schedule_children_for_removal(colyseus_ref_tracker_t* tracker, colyseus_ref_entry_t* entry) {
    if (!entry || !entry->ref) return;

    switch (entry->ref_type) {
        case COLYSEUS_REF_TYPE_SCHEMA: {
            /* dynamic vtables have no static field table — walk dyn_fields */
            if (entry->vtable && colyseus_vtable_is_dynamic(entry->vtable)) {
                const colyseus_dynamic_vtable_t* dv = colyseus_vtable_as_dynamic(entry->vtable);
                colyseus_dynamic_schema_t* dschema = (colyseus_dynamic_schema_t*)entry->ref;

                for (int i = 0; i < dv->dyn_field_count; i++) {
                    const colyseus_dynamic_field_t* field = dv->dyn_fields[i];
                    if (field->type != COLYSEUS_FIELD_REF &&
                        field->type != COLYSEUS_FIELD_ARRAY &&
                        field->type != COLYSEUS_FIELD_MAP) {
                        continue;
                    }

                    colyseus_dynamic_value_t* dvv = colyseus_dynamic_schema_get(dschema, field->index);
                    if (!dvv || !dvv->data.ptr) continue;

                    int child_ref_id = COLYSEUS_REF_ID(dvv->data.ptr);
                    if (colyseus_ref_tracker_has(tracker, child_ref_id) &&
                        !is_in_deleted_list(tracker, child_ref_id)) {
                        colyseus_ref_tracker_remove(tracker, child_ref_id);
                    }
                }
                break;
            }

            if (!entry->vtable || !entry->vtable->fields) break;

            colyseus_schema_t* schema = (colyseus_schema_t*)entry->ref;

            /* Iterate through schema fields looking for ref children */
            for (int i = 0; i < entry->vtable->field_count; i++) {
                const colyseus_field_t* field = &entry->vtable->fields[i];

                /* Only process ref/array/map fields - skip primitives entirely
                 * to avoid reading non-pointer fields as pointers */
                if (field->type != COLYSEUS_FIELD_REF &&
                    field->type != COLYSEUS_FIELD_ARRAY &&
                    field->type != COLYSEUS_FIELD_MAP) {
                    continue;
                }

                void* field_value = *schema_field_slot(schema, field);

                if (!field_value) continue;

                int child_ref_id = COLYSEUS_REF_ID(field_value);

                /* Verify the child actually exists in the tracker before removing */
                if (colyseus_ref_tracker_has(tracker, child_ref_id) &&
                    !is_in_deleted_list(tracker, child_ref_id)) {
                    colyseus_ref_tracker_remove(tracker, child_ref_id);
                }
            }
            break;
        }

        case COLYSEUS_REF_TYPE_ARRAY: {
            colyseus_array_schema_t* arr = (colyseus_array_schema_t*)entry->ref;
            if (arr->has_schema_child) {
                gc_foreach_ctx_t ctx = { tracker, true };
                colyseus_array_schema_foreach(arr, gc_array_foreach, &ctx);
            }
            break;
        }

        case COLYSEUS_REF_TYPE_MAP: {
            colyseus_map_schema_t* map = (colyseus_map_schema_t*)entry->ref;
            if (map->has_schema_child) {
                gc_foreach_ctx_t ctx = { tracker, true };
                colyseus_map_schema_foreach(map, gc_map_foreach, &ctx);
            }
            break;
        }
    }
}

void colyseus_ref_tracker_gc(colyseus_ref_tracker_t* tracker) {
    if (!tracker) return;

    /* Process deleted list - may grow as we find children */
    int iterations = 0;
    const int max_iterations = 1000;  /* Safety limit */

    while (tracker->deleted && iterations < max_iterations) {
        colyseus_deleted_ref_t* curr = tracker->deleted;
        tracker->deleted = NULL;  /* Detach list, children may add more */

        while (curr) {
            colyseus_ref_entry_t* entry = NULL;
            HASH_FIND_INT(tracker->refs, &curr->ref_id, entry);

            if (entry && entry->ref_count <= 0) {
                /* First, schedule children for removal */
                schedule_children_for_removal(tracker, entry);

                /* Then remove this entry */
                int collected_id = entry->ref_id;
                HASH_DEL(tracker->refs, entry);
                free(entry);

                for (int i = 0; i < tracker->collect_count; i++) {
                    tracker->collect_listeners[i](collected_id, tracker->collect_userdata[i]);
                }
            }

            colyseus_deleted_ref_t* to_delete = curr;
            curr = curr->next;
            free(to_delete);
        }

        iterations++;
    }

    if (iterations >= max_iterations) {
        fprintf(stderr, "Warning: GC iteration limit reached\n");
    }
}

void colyseus_ref_tracker_clear(colyseus_ref_tracker_t* tracker) {
    if (!tracker) return;

    /*
     * For DYNAMIC schemas only: destroy all refs to prevent memory leaks.
     * Dynamic schemas don't recursively free children in their destroy functions,
     * so we handle it here.
     * 
     * For STATIC schemas: just clear the entries. Their destroy functions
     * already handle recursive cleanup of children.
     * 
     * Two-pass cleanup for dynamic schemas:
     * Pass 1: Destroy all SCHEMA refs (they may have userdata like GDScript instances)
     * Pass 2: Destroy all ARRAY and MAP refs (structure only - children already freed)
     */
    
    /* First, check if this tracker contains any dynamic schemas */
    bool has_dynamic_schemas = false;
    colyseus_ref_entry_t* entry;
    colyseus_ref_entry_t* tmp;
    HASH_ITER(hh, tracker->refs, entry, tmp) {
        if (entry->ref_type == COLYSEUS_REF_TYPE_SCHEMA && entry->vtable) {
            if (colyseus_vtable_is_dynamic(entry->vtable)) {
                has_dynamic_schemas = true;
                break;
            }
        }
    }
    
    if (has_dynamic_schemas) {
        /* Pass 1: Destroy all dynamic schemas */
        HASH_ITER(hh, tracker->refs, entry, tmp) {
            if (entry->ref && entry->ref_type == COLYSEUS_REF_TYPE_SCHEMA) {
                if (entry->vtable && colyseus_vtable_is_dynamic(entry->vtable)) {
                    if (entry->vtable->destroy) {
                        entry->vtable->destroy((colyseus_schema_t*)entry->ref);
                    }
                    entry->ref = NULL;  /* Mark as freed */
                }
            }
        }
        
        /* Pass 2: Destroy all arrays and maps (children already freed above) */
        HASH_ITER(hh, tracker->refs, entry, tmp) {
            if (entry->ref) {
                if (entry->ref_type == COLYSEUS_REF_TYPE_ARRAY) {
                    colyseus_array_schema_free((colyseus_array_schema_t*)entry->ref, NULL);
                } else if (entry->ref_type == COLYSEUS_REF_TYPE_MAP) {
                    colyseus_map_schema_free((colyseus_map_schema_t*)entry->ref, NULL);
                }
                entry->ref = NULL;
            }
            HASH_DEL(tracker->refs, entry);
            free(entry);
        }
    } else {
        /* Static schemas: just clear entries, destroy happens via state->destroy() */
        HASH_ITER(hh, tracker->refs, entry, tmp) {
            HASH_DEL(tracker->refs, entry);
            free(entry);
        }
    }

    /* Clear deleted list */
    colyseus_deleted_ref_t* curr = tracker->deleted;
    while (curr) {
        colyseus_deleted_ref_t* to_delete = curr;
        curr = curr->next;
        free(to_delete);
    }
    tracker->deleted = NULL;
}
