#include "colyseus/schema/ref_tracker.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Forward declaration for recursive removal */
static void schedule_children_for_removal(colyseus_ref_tracker_t* tracker, colyseus_ref_entry_t* entry);

colyseus_ref_tracker_t* colyseus_ref_tracker_create(void) {
    colyseus_ref_tracker_t* tracker = malloc(sizeof(colyseus_ref_tracker_t));
    if (!tracker) return NULL;

    tracker->refs = NULL;
    tracker->deleted = NULL;

    return tracker;
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

bool colyseus_ref_tracker_has(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return false;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    return entry != NULL;
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
            if (!entry->vtable) break;

            colyseus_schema_t* schema = (colyseus_schema_t*)entry->ref;

            /* Iterate through schema fields looking for ref children */
            for (int i = 0; i < entry->vtable->field_count; i++) {
                const colyseus_field_t* field = &entry->vtable->fields[i];
                void* field_ptr = (char*)schema + field->offset;
                void* field_value = *(void**)field_ptr;

                if (!field_value) continue;

                if (field->type == COLYSEUS_FIELD_REF ||
                    field->type == COLYSEUS_FIELD_ARRAY ||
                    field->type == COLYSEUS_FIELD_MAP) {

                    int child_ref_id = COLYSEUS_REF_ID(field_value);
                    if (!is_in_deleted_list(tracker, child_ref_id)) {
                        colyseus_ref_tracker_remove(tracker, child_ref_id);
                    }
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
                HASH_DEL(tracker->refs, entry);
                free(entry);
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

    /* Clear refs hash table */
    colyseus_ref_entry_t* entry;
    colyseus_ref_entry_t* tmp;
    HASH_ITER(hh, tracker->refs, entry, tmp) {
        HASH_DEL(tracker->refs, entry);
        free(entry);
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