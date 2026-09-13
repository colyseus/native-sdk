#include "colyseus/schema/callbacks.h"
#include "colyseus/schema/ref_tracker.h"
#include "colyseus/schema/dynamic_schema.h"
#include "uthash.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ============================================================================
 * Internal data structures
 * ============================================================================ */

/* Callback type constants */
#define CALLBACK_KEY_OPERATION  0   /* key_value is an operation code */
#define CALLBACK_KEY_FIELD      1   /* key_value is ignored, field_name is used */

/* Single callback entry */
typedef struct colyseus_callback_entry {
    int id;                                     /* Unique callback ID (handle) */
    int key_type;                               /* CALLBACK_KEY_OPERATION or CALLBACK_KEY_FIELD */
    int key_value;                              /* Operation code if key_type == CALLBACK_KEY_OPERATION */
    char* field_name;                           /* Field name if key_type == CALLBACK_KEY_FIELD */
    void* handler;                              /* Function pointer */
    void* userdata;                             /* User context */
    bool dead;                                  /* removed mid-dispatch; freed once the pass ends */
    struct colyseus_callback_entry* next;       /* Linked list next */
} colyseus_callback_entry_t;

/* Callbacks for a single refId */
typedef struct colyseus_ref_callbacks {
    int ref_id;
    colyseus_callback_entry_t* entries;         /* Linked list of callbacks */
    UT_hash_handle hh;
} colyseus_ref_callbacks_t;

/* Unique ref ID tracking (for avoiding duplicate REPLACE callbacks) */
typedef struct colyseus_unique_ref {
    int ref_id;
    UT_hash_handle hh;
} colyseus_unique_ref_t;

/* Main callbacks manager */
struct colyseus_callbacks {
    colyseus_decoder_t* decoder;
    colyseus_ref_callbacks_t* callbacks;        /* Hash by refId */
    int next_callback_id;
    int dispatch_depth;                         /* > 0 while trigger_changes runs */
    bool has_dead;                              /* entries waiting for the post-dispatch sweep */
    colyseus_unique_ref_t* unique_ref_ids;      /* For trigger_changes dedup */
};

/* ============================================================================
 * Forward declarations
 * ============================================================================ */

static void colyseus_callbacks_trigger_changes(colyseus_changes_t* changes, void* userdata);
static void callbacks_on_ref_collected(int ref_id, void* userdata);
static void on_collection_available(void* value, void* previous_value, void* userdata);
static void on_change_collection_available(void* value, void* previous_value, void* userdata);
static colyseus_callback_handle_t add_callback_internal(
    colyseus_callbacks_t* callbacks, int ref_id, int key_type, int key_value,
    const char* field_name, void* handler, void* userdata);

/* Frees an entry, plus the context of a registration still waiting for its
 * collection to exist. */
static void free_entry(colyseus_callback_entry_t* entry) {
    if (entry->handler == (void*)on_collection_available ||
        entry->handler == (void*)on_change_collection_available) {
        free(entry->userdata);
    }
    free(entry->field_name);
    free(entry);
}

static void free_ref_callbacks(colyseus_callbacks_t* cb, colyseus_ref_callbacks_t* ref_cb) {
    colyseus_callback_entry_t* entry = ref_cb->entries;
    while (entry) {
        colyseus_callback_entry_t* next = entry->next;
        free_entry(entry);
        entry = next;
    }
    HASH_DEL(cb->callbacks, ref_cb);
    free(ref_cb);
}

/* Frees the entries removed while a dispatch was walking the lists. */
static void sweep_dead(colyseus_callbacks_t* cb) {
    cb->has_dead = false;
    colyseus_ref_callbacks_t* ref_cb;
    colyseus_ref_callbacks_t* ref_tmp;
    HASH_ITER(hh, cb->callbacks, ref_cb, ref_tmp) {
        colyseus_callback_entry_t** link = &ref_cb->entries;
        while (*link) {
            colyseus_callback_entry_t* entry = *link;
            if (entry->dead) {
                *link = entry->next;
                free_entry(entry);
            } else {
                link = &entry->next;
            }
        }
        if (!ref_cb->entries) {
            HASH_DEL(cb->callbacks, ref_cb);
            free(ref_cb);
        }
    }
}

/*
 * The TS strategy skips `immediate` while it is dispatching: the patch's own
 * changes reach a registration made from a callback anyway. Several callbacks
 * layers can share a decoder here, so the question is per layer — skip only
 * while THIS one still has the current patch to deliver (running, or queued
 * behind another layer). Once it has delivered it, nothing else will.
 */
static bool suppress_immediate(colyseus_callbacks_t* cb) {
    return colyseus_decoder_trigger_pending(cb->decoder, colyseus_callbacks_trigger_changes, cb);
}

/* ============================================================================
 * Create / Free
 * ============================================================================ */

colyseus_callbacks_t* colyseus_callbacks_create(colyseus_decoder_t* decoder) {
    if (!decoder) return NULL;

    colyseus_callbacks_t* cb = malloc(sizeof(colyseus_callbacks_t));
    if (!cb) return NULL;

    cb->decoder = decoder;
    cb->callbacks = NULL;
    cb->next_callback_id = 1;
    cb->dispatch_depth = 0;
    cb->has_dead = false;
    cb->unique_ref_ids = NULL;

    if (!colyseus_decoder_set_trigger_callback(decoder, colyseus_callbacks_trigger_changes, cb)) {
        free(cb);
        return NULL;
    }
    /* a collected ref's registrations go with it: the server can reuse its refId */
    colyseus_ref_tracker_add_collect_listener(decoder->refs, callbacks_on_ref_collected, cb);

    return cb;
}

void colyseus_callbacks_free(colyseus_callbacks_t* callbacks) {
    if (!callbacks) return;

    if (callbacks->decoder) {
        colyseus_decoder_remove_trigger_callback(callbacks->decoder, colyseus_callbacks_trigger_changes, callbacks);
        colyseus_ref_tracker_remove_collect_listener(callbacks->decoder->refs, callbacks_on_ref_collected, callbacks);
    }

    colyseus_ref_callbacks_t* ref_cb;
    colyseus_ref_callbacks_t* ref_tmp;
    HASH_ITER(hh, callbacks->callbacks, ref_cb, ref_tmp) {
        free_ref_callbacks(callbacks, ref_cb);
    }

    colyseus_unique_ref_t* unique;
    colyseus_unique_ref_t* unique_tmp;
    HASH_ITER(hh, callbacks->unique_ref_ids, unique, unique_tmp) {
        HASH_DEL(callbacks->unique_ref_ids, unique);
        free(unique);
    }

    free(callbacks);
}

/* ============================================================================
 * Internal: Add callback
 * ============================================================================ */

/* `id` re-issues a handle the caller already holds; INVALID allocates one. */
static colyseus_callback_handle_t add_callback_with_id(
    colyseus_callbacks_t* callbacks,
    colyseus_callback_handle_t id,
    int ref_id,
    int key_type,
    int key_value,
    const char* field_name,
    void* handler,
    void* userdata)
{
    if (!callbacks || !handler) return COLYSEUS_INVALID_CALLBACK_HANDLE;

    /* Find or create ref_callbacks for this refId */
    colyseus_ref_callbacks_t* ref_cb = NULL;
    HASH_FIND_INT(callbacks->callbacks, &ref_id, ref_cb);

    if (!ref_cb) {
        ref_cb = malloc(sizeof(colyseus_ref_callbacks_t));
        if (!ref_cb) return COLYSEUS_INVALID_CALLBACK_HANDLE;
        ref_cb->ref_id = ref_id;
        ref_cb->entries = NULL;
        HASH_ADD_INT(callbacks->callbacks, ref_id, ref_cb);
    }

    /* Create new callback entry */
    colyseus_callback_entry_t* entry = malloc(sizeof(colyseus_callback_entry_t));
    if (!entry) return COLYSEUS_INVALID_CALLBACK_HANDLE;

    entry->id = id != COLYSEUS_INVALID_CALLBACK_HANDLE ? id : callbacks->next_callback_id++;
    entry->key_type = key_type;
    entry->key_value = key_value;
    entry->field_name = field_name ? strdup(field_name) : NULL;
    entry->handler = handler;
    entry->userdata = userdata;
    entry->dead = false;
    entry->next = ref_cb->entries;  /* Prepend: the newest fires first, as in TS */
    ref_cb->entries = entry;

    return entry->id;
}

static colyseus_callback_handle_t add_callback_internal(
    colyseus_callbacks_t* callbacks,
    int ref_id,
    int key_type,
    int key_value,
    const char* field_name,
    void* handler,
    void* userdata)
{
    return add_callback_with_id(callbacks, COLYSEUS_INVALID_CALLBACK_HANDLE,
        ref_id, key_type, key_value, field_name, handler, userdata);
}

/* ============================================================================
 * Remove callback
 * ============================================================================ */

void colyseus_callbacks_remove(colyseus_callbacks_t* callbacks, colyseus_callback_handle_t handle) {
    if (!callbacks || handle == COLYSEUS_INVALID_CALLBACK_HANDLE) return;

    colyseus_ref_callbacks_t* ref_cb;
    colyseus_ref_callbacks_t* ref_tmp;
    HASH_ITER(hh, callbacks->callbacks, ref_cb, ref_tmp) {
        for (colyseus_callback_entry_t** link = &ref_cb->entries; *link; link = &(*link)->next) {
            colyseus_callback_entry_t* entry = *link;
            if (entry->id != handle || entry->dead) continue;

            if (callbacks->dispatch_depth > 0) {
                /* the dispatch may be standing on this entry, or be about to */
                entry->dead = true;
                callbacks->has_dead = true;
                return;
            }

            *link = entry->next;
            free_entry(entry);
            if (!ref_cb->entries) {
                HASH_DEL(callbacks->callbacks, ref_cb);
                free(ref_cb);
            }
            return;
        }
    }
}

/* ============================================================================
 * Helper: Get callbacks for a ref_id
 * ============================================================================ */

static colyseus_ref_callbacks_t* get_ref_callbacks(colyseus_callbacks_t* callbacks, int ref_id) {
    colyseus_ref_callbacks_t* ref_cb = NULL;
    HASH_FIND_INT(callbacks->callbacks, &ref_id, ref_cb);
    return ref_cb;
}

/* The GC collected `ref_id`: forget its registrations, as the TS decoder does.
 * A StateView re-add brings the SAME refId back as a new instance, which must
 * not inherit the old instance's listeners. */
static void callbacks_on_ref_collected(int ref_id, void* userdata) {
    colyseus_callbacks_t* cb = (colyseus_callbacks_t*)userdata;
    colyseus_ref_callbacks_t* ref_cb = get_ref_callbacks(cb, ref_id);
    if (!ref_cb) return;

    if (cb->dispatch_depth > 0) {
        for (colyseus_callback_entry_t* entry = ref_cb->entries; entry; entry = entry->next) {
            entry->dead = true;
        }
        cb->has_dead = true;
        return;
    }
    free_ref_callbacks(cb, ref_cb);
}

/* ============================================================================
 * Helper: Check if ref is a schema (has vtable)
 * ============================================================================ */

static bool is_schema_ref(colyseus_callbacks_t* callbacks, int ref_id) {
    if (!callbacks || !callbacks->decoder || !callbacks->decoder->refs) return false;
    colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(callbacks->decoder->refs, ref_id);
    return entry && entry->ref_type == COLYSEUS_REF_TYPE_SCHEMA;
}

/* ============================================================================
 * Trigger changes (main dispatch)
 *
 * Entries are only ever marked dead during a pass (never freed), so walking
 * `entry->next` after a handler ran is safe whatever that handler removed.
 * ============================================================================ */

static void colyseus_callbacks_trigger_changes(colyseus_changes_t* changes, void* userdata) {
    colyseus_callbacks_t* cb = (colyseus_callbacks_t*)userdata;
    if (!cb || !changes) return;

    /* Clear unique_ref_ids */
    colyseus_unique_ref_t* unique;
    colyseus_unique_ref_t* unique_tmp;
    HASH_ITER(hh, cb->unique_ref_ids, unique, unique_tmp) {
        HASH_DEL(cb->unique_ref_ids, unique);
        free(unique);
    }
    cb->unique_ref_ids = NULL;

    cb->dispatch_depth++;

    for (int i = 0; i < changes->count; i++) {
        colyseus_data_change_t* change = &changes->items[i];
        int ref_id = change->ref_id;

        colyseus_ref_callbacks_t* ref_cb = get_ref_callbacks(cb, ref_id);
        if (!ref_cb) {
            continue;
        }

        /*
         * onRemove on the child itself when the previous value was a Schema
         * (TS: Schema.isSchema(previousValue)). Only a REF can be one: a
         * collection's DELETE entries are item callbacks with a different
         * signature, and a string's previous_value is a char*.
         */
        if ((change->op & COLYSEUS_OP_DELETE) == COLYSEUS_OP_DELETE &&
            change->previous_value != NULL &&
            change->field_type == COLYSEUS_FIELD_REF) {

            int child_ref_id = COLYSEUS_REF_ID(change->previous_value);
            colyseus_ref_callbacks_t* child_cb = get_ref_callbacks(cb, child_ref_id);

            if (child_cb) {
                for (colyseus_callback_entry_t* entry = child_cb->entries; entry; entry = entry->next) {
                    if (!entry->dead &&
                        entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_DELETE) {
                        /* onRemove on self: no args, just userdata */
                        ((colyseus_instance_change_callback_fn)entry->handler)(entry->userdata);
                    }
                }
            }
        }

        if (is_schema_ref(cb, ref_id)) {
            /*
             * Handle Schema instance
             */

            /* Check if we've already triggered REPLACE for this refId */
            colyseus_unique_ref_t* found = NULL;
            HASH_FIND_INT(cb->unique_ref_ids, &ref_id, found);

            if (!found) {
                /* Trigger onChange (REPLACE) callbacks */
                for (colyseus_callback_entry_t* entry = ref_cb->entries; entry; entry = entry->next) {
                    if (!entry->dead &&
                        entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_REPLACE) {
                        ((colyseus_instance_change_callback_fn)entry->handler)(entry->userdata);
                    }
                }
            }

            /* Trigger field-specific callbacks */
            if (change->field) {
                for (colyseus_callback_entry_t* entry = ref_cb->entries; entry; entry = entry->next) {
                    if (!entry->dead &&
                        entry->key_type == CALLBACK_KEY_FIELD &&
                        entry->field_name &&
                        strcmp(entry->field_name, change->field) == 0) {
                        ((colyseus_property_callback_fn)entry->handler)(
                            change->value, change->previous_value, entry->userdata);
                    }
                }
            }

        } else {
            /*
             * Handle collection of items
             */
            void* dynamic_index = change->dynamic_index;

            if ((change->op & COLYSEUS_OP_DELETE) == COLYSEUS_OP_DELETE) {
                if (change->previous_value != NULL) {
                    /* Trigger onRemove (value, key) */
                    for (colyseus_callback_entry_t* entry = ref_cb->entries; entry; entry = entry->next) {
                        if (!entry->dead &&
                            entry->key_type == CALLBACK_KEY_OPERATION &&
                            entry->key_value == (int)COLYSEUS_OP_DELETE) {
                            ((colyseus_item_callback_fn)entry->handler)(
                                change->previous_value, dynamic_index, entry->userdata);
                        }
                    }
                }

                /* Handle DELETE_AND_ADD */
                if ((change->op & COLYSEUS_OP_ADD) == COLYSEUS_OP_ADD) {
                    for (colyseus_callback_entry_t* entry = ref_cb->entries; entry; entry = entry->next) {
                        if (!entry->dead &&
                            entry->key_type == CALLBACK_KEY_OPERATION &&
                            entry->key_value == (int)COLYSEUS_OP_ADD) {
                            ((colyseus_item_callback_fn)entry->handler)(
                                change->value, dynamic_index, entry->userdata);
                        }
                    }
                }

            } else if ((change->op & COLYSEUS_OP_ADD) == COLYSEUS_OP_ADD &&
                       change->previous_value != change->value) {
                /* Trigger onAdd (value, key) */
                for (colyseus_callback_entry_t* entry = ref_cb->entries; entry; entry = entry->next) {
                    if (!entry->dead &&
                        entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_ADD) {
                        ((colyseus_item_callback_fn)entry->handler)(
                            change->value, dynamic_index, entry->userdata);
                    }
                }
            }

            /* Trigger onChange (REPLACE) for collection item change */
            if (change->value != change->previous_value) {
                for (colyseus_callback_entry_t* entry = ref_cb->entries; entry; entry = entry->next) {
                    if (!entry->dead &&
                        entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_REPLACE) {
                        ((colyseus_collection_change_callback_fn)entry->handler)(
                            dynamic_index, change->value, entry->userdata);
                    }
                }
            }
        }

        /* Mark this refId as processed */
        colyseus_unique_ref_t* new_unique = malloc(sizeof(colyseus_unique_ref_t));
        if (new_unique) {
            new_unique->ref_id = ref_id;
            HASH_ADD_INT(cb->unique_ref_ids, ref_id, new_unique);
        }
    }

    cb->dispatch_depth--;
    if (cb->dispatch_depth == 0 && cb->has_dead) {
        sweep_dead(cb);
    }
}

/* ============================================================================
 * Helper: Get field info from schema
 * ============================================================================ */

static const colyseus_field_t* get_field_by_name(const colyseus_schema_vtable_t* vtable, const char* name) {
    if (!vtable || !name) return NULL;

    /* Dynamic vtables don't have a fields array */
    if (colyseus_vtable_is_dynamic(vtable)) {
        return NULL;  /* Use get_dyn_field_by_name instead */
    }

    if (!vtable->fields) return NULL;

    for (int i = 0; i < vtable->field_count; i++) {
        if (vtable->fields[i].name && strcmp(vtable->fields[i].name, name) == 0) {
            return &vtable->fields[i];
        }
    }
    return NULL;
}

/* Get dynamic field by name */
static const colyseus_dynamic_field_t* get_dyn_field_by_name(const colyseus_schema_vtable_t* vtable, const char* name) {
    if (!vtable || !name || !colyseus_vtable_is_dynamic(vtable)) return NULL;

    const colyseus_dynamic_vtable_t* dyn_vtable = colyseus_vtable_as_dynamic(vtable);
    return colyseus_dynamic_vtable_find_field_by_name(dyn_vtable, name);
}

/* ============================================================================
 * Property Listening (listen)
 * ============================================================================ */

colyseus_callback_handle_t colyseus_callbacks_listen(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_property_callback_fn handler,
    void* userdata,
    bool immediate)
{
    if (!callbacks || !instance || !property || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    int ref_id = COLYSEUS_REF_ID(instance);

    /* Call immediately if the property has a value */
    if (immediate && !suppress_immediate(callbacks)) {
        colyseus_schema_t* schema = (colyseus_schema_t*)instance;
        if (schema->__vtable) {
            void* current_value = NULL;

            if (colyseus_vtable_is_dynamic(schema->__vtable)) {
                /* Dynamic schema */
                const colyseus_dynamic_field_t* dyn_field = get_dyn_field_by_name(schema->__vtable, property);
                if (dyn_field) {
                    colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)schema;
                    colyseus_dynamic_value_t* dyn_value = colyseus_dynamic_schema_get(dyn_schema, dyn_field->index);
                    if (dyn_value) {
                        switch (dyn_field->type) {
                            case COLYSEUS_FIELD_REF:
                                current_value = dyn_value->data.ref;
                                break;
                            case COLYSEUS_FIELD_ARRAY:
                                current_value = dyn_value->data.array;
                                break;
                            case COLYSEUS_FIELD_MAP:
                                current_value = dyn_value->data.map;
                                break;
                            case COLYSEUS_FIELD_STRING:
                                current_value = dyn_value->data.str;
                                break;
                            default:
                                /* For primitives, pass the value pointer */
                                current_value = &dyn_value->data;
                                break;
                        }
                    }
                }
            } else {
                /* Static schema */
                const colyseus_field_t* field = get_field_by_name(schema->__vtable, property);
                if (field) {
                    void* field_ptr = (char*)schema + field->offset;

                    switch (field->type) {
                        case COLYSEUS_FIELD_REF:
                        case COLYSEUS_FIELD_ARRAY:
                        case COLYSEUS_FIELD_MAP:
                        case COLYSEUS_FIELD_STRING:
                            current_value = *(void**)field_ptr;
                            break;
                        default:
                            /* a static scalar has no "unset": it reports its storage */
                            current_value = field_ptr;
                            break;
                    }
                }
            }

            if (current_value != NULL) {
                handler(current_value, NULL, userdata);
            }
        }
    }

    return add_callback_internal(callbacks, ref_id,
        CALLBACK_KEY_FIELD, 0, property, (void*)handler, userdata);
}

/* ============================================================================
 * Collection callbacks helper
 * ============================================================================ */

/*
 * A collection registration made before the collection exists waits on the
 * parent's property. The handle given to the caller is that wait's, and the
 * real registration reuses it once the collection arrives — so the caller's
 * colyseus_callbacks_remove() keeps working across the switch, like the TS
 * closure returned by onAdd().
 */
typedef struct {
    colyseus_callbacks_t* callbacks;
    colyseus_item_callback_fn handler;
    void* userdata;
    int operation;
    bool immediate;
    colyseus_callback_handle_t property_handle;
} deferred_collection_context_t;

static void on_collection_available(void* value, void* previous_value, void* userdata) {
    (void)previous_value;
    deferred_collection_context_t* ctx = (deferred_collection_context_t*)userdata;
    if (!ctx || !value) return;

    colyseus_callbacks_t* callbacks = ctx->callbacks;
    colyseus_item_callback_fn handler = ctx->handler;
    void* handler_userdata = ctx->userdata;
    int operation = ctx->operation;
    bool immediate = ctx->immediate;
    colyseus_callback_handle_t handle = ctx->property_handle;

    /* frees ctx (now, or when this pass ends) — only the locals are used below */
    colyseus_callbacks_remove(callbacks, handle);

    int collection_ref_id = COLYSEUS_REF_ID(value);
    add_callback_with_id(callbacks, handle, collection_ref_id,
        CALLBACK_KEY_OPERATION, operation, NULL, (void*)handler, handler_userdata);

    /*
     * If immediate and ADD operation, call for existing items.
     * Skipped while this layer is still delivering the patch — the ADD
     * changes in it reach the new registration anyway.
     */
    if (immediate && !suppress_immediate(callbacks) && operation == (int)COLYSEUS_OP_ADD) {
        colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(
            callbacks->decoder->refs, collection_ref_id);

        if (entry) {
            if (entry->ref_type == COLYSEUS_REF_TYPE_ARRAY) {
                colyseus_array_schema_t* arr = (colyseus_array_schema_t*)value;
                for (colyseus_array_item_t* item = arr->items; item; item = item->next) {
                    int idx = item->index;
                    handler(item->value, &idx, handler_userdata);
                }
            } else if (entry->ref_type == COLYSEUS_REF_TYPE_MAP) {
                colyseus_map_schema_t* map = (colyseus_map_schema_t*)value;
                colyseus_map_item_t* item;
                colyseus_map_item_t* tmp;
                HASH_ITER(hh, map->items, item, tmp) {
                    handler(item->value, item->key, handler_userdata);
                }
            }
        }
    }
}

static colyseus_callback_handle_t add_collection_callback_or_wait(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    int operation,
    colyseus_item_callback_fn handler,
    void* userdata,
    bool immediate)
{
    if (!callbacks || !instance || !property || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    colyseus_schema_t* schema = (colyseus_schema_t*)instance;
    if (!schema->__vtable) return COLYSEUS_INVALID_CALLBACK_HANDLE;

    void* collection = NULL;

    /* Get collection from schema - handle both static and dynamic vtables */
    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        /* Dynamic schema */
        const colyseus_dynamic_field_t* dyn_field = get_dyn_field_by_name(schema->__vtable, property);
        if (!dyn_field) return COLYSEUS_INVALID_CALLBACK_HANDLE;

        colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)schema;
        colyseus_dynamic_value_t* dyn_value = colyseus_dynamic_schema_get(dyn_schema, dyn_field->index);
        if (dyn_value) {
            switch (dyn_field->type) {
                case COLYSEUS_FIELD_ARRAY:
                    collection = dyn_value->data.array;
                    break;
                case COLYSEUS_FIELD_MAP:
                    collection = dyn_value->data.map;
                    break;
                default:
                    return COLYSEUS_INVALID_CALLBACK_HANDLE;  /* Not a collection type */
            }
        }
    } else {
        /* Static schema */
        const colyseus_field_t* field = get_field_by_name(schema->__vtable, property);
        if (!field) return COLYSEUS_INVALID_CALLBACK_HANDLE;

        collection = *(void**)((char*)schema + field->offset);
    }

    if (!collection) {
        /* Collection not available yet - wait for it */
        deferred_collection_context_t* ctx = malloc(sizeof(deferred_collection_context_t));
        if (!ctx) return COLYSEUS_INVALID_CALLBACK_HANDLE;

        ctx->callbacks = callbacks;
        ctx->handler = handler;
        ctx->userdata = userdata;
        ctx->operation = operation;
        ctx->immediate = immediate;
        ctx->property_handle = add_callback_internal(callbacks, COLYSEUS_REF_ID(instance),
            CALLBACK_KEY_FIELD, 0, property, (void*)on_collection_available, ctx);
        if (ctx->property_handle == COLYSEUS_INVALID_CALLBACK_HANDLE) free(ctx);
        return ctx->property_handle;
    }

    int collection_ref_id = COLYSEUS_REF_ID(collection);

    /* If immediate and ADD operation, call for existing items */
    immediate = immediate && !suppress_immediate(callbacks);

    if (operation == (int)COLYSEUS_OP_ADD && immediate) {
        colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(
            callbacks->decoder->refs, collection_ref_id);

        if (entry) {
            if (entry->ref_type == COLYSEUS_REF_TYPE_ARRAY) {
                colyseus_array_schema_t* arr = (colyseus_array_schema_t*)collection;
                for (colyseus_array_item_t* item = arr->items; item; item = item->next) {
                    int idx = item->index;
                    handler(item->value, &idx, userdata);
                }
            } else if (entry->ref_type == COLYSEUS_REF_TYPE_MAP) {
                colyseus_map_schema_t* map = (colyseus_map_schema_t*)collection;
                colyseus_map_item_t* item;
                colyseus_map_item_t* tmp;
                HASH_ITER(hh, map->items, item, tmp) {
                    handler(item->value, item->key, userdata);
                }
            }
        }
    }

    return add_callback_internal(callbacks, collection_ref_id,
        CALLBACK_KEY_OPERATION, operation, NULL, (void*)handler, userdata);
}

/* ============================================================================
 * onAdd
 * ============================================================================ */

colyseus_callback_handle_t colyseus_callbacks_on_add(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_item_callback_fn handler,
    void* userdata,
    bool immediate)
{
    return add_collection_callback_or_wait(callbacks, instance, property,
        (int)COLYSEUS_OP_ADD, handler, userdata, immediate);
}

/* ============================================================================
 * onRemove
 * ============================================================================ */

colyseus_callback_handle_t colyseus_callbacks_on_remove(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_item_callback_fn handler,
    void* userdata)
{
    return add_collection_callback_or_wait(callbacks, instance, property,
        (int)COLYSEUS_OP_DELETE, handler, userdata, false);
}

/* ============================================================================
 * onChange (instance)
 * ============================================================================ */

colyseus_callback_handle_t colyseus_callbacks_on_change_instance(
    colyseus_callbacks_t* callbacks,
    void* instance,
    colyseus_instance_change_callback_fn handler,
    void* userdata)
{
    if (!callbacks || !instance || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    int ref_id = COLYSEUS_REF_ID(instance);
    return add_callback_internal(callbacks, ref_id,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_REPLACE, NULL, (void*)handler, userdata);
}

/* ============================================================================
 * onChange (collection) — deferred helper
 * ============================================================================ */

typedef struct {
    colyseus_callbacks_t* callbacks;
    colyseus_collection_change_callback_fn handler;
    void* userdata;
    colyseus_callback_handle_t property_handle;
} deferred_change_collection_context_t;

static void on_change_collection_available(void* value, void* previous_value, void* userdata) {
    (void)previous_value;
    deferred_change_collection_context_t* ctx = (deferred_change_collection_context_t*)userdata;
    if (!ctx || !value) return;

    colyseus_callbacks_t* callbacks = ctx->callbacks;
    colyseus_collection_change_callback_fn handler = ctx->handler;
    void* handler_userdata = ctx->userdata;
    colyseus_callback_handle_t handle = ctx->property_handle;

    /* frees ctx (now, or when this pass ends) — only the locals are used below */
    colyseus_callbacks_remove(callbacks, handle);

    add_callback_with_id(callbacks, handle, COLYSEUS_REF_ID(value),
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_REPLACE, NULL, (void*)handler, handler_userdata);
}

/* ============================================================================
 * onChange (collection)
 * ============================================================================ */

colyseus_callback_handle_t colyseus_callbacks_on_change_collection(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_collection_change_callback_fn handler,
    void* userdata)
{
    if (!callbacks || !instance || !property || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    colyseus_schema_t* schema = (colyseus_schema_t*)instance;
    if (!schema->__vtable) return COLYSEUS_INVALID_CALLBACK_HANDLE;

    void* collection = NULL;

    /* Get collection from schema - handle both static and dynamic vtables */
    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        /* Dynamic schema */
        const colyseus_dynamic_field_t* dyn_field = get_dyn_field_by_name(schema->__vtable, property);
        if (!dyn_field) return COLYSEUS_INVALID_CALLBACK_HANDLE;

        colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)schema;
        colyseus_dynamic_value_t* dyn_value = colyseus_dynamic_schema_get(dyn_schema, dyn_field->index);
        if (dyn_value) {
            switch (dyn_field->type) {
                case COLYSEUS_FIELD_ARRAY:
                    collection = dyn_value->data.array;
                    break;
                case COLYSEUS_FIELD_MAP:
                    collection = dyn_value->data.map;
                    break;
                default:
                    return COLYSEUS_INVALID_CALLBACK_HANDLE;
            }
        }
    } else {
        /* Static schema */
        const colyseus_field_t* field = get_field_by_name(schema->__vtable, property);
        if (!field) return COLYSEUS_INVALID_CALLBACK_HANDLE;

        collection = *(void**)((char*)schema + field->offset);
    }

    if (!collection) {
        /* Collection not available yet - defer registration until it arrives */
        deferred_change_collection_context_t* ctx = malloc(sizeof(deferred_change_collection_context_t));
        if (!ctx) return COLYSEUS_INVALID_CALLBACK_HANDLE;

        ctx->callbacks = callbacks;
        ctx->handler = handler;
        ctx->userdata = userdata;
        ctx->property_handle = add_callback_internal(callbacks, COLYSEUS_REF_ID(instance),
            CALLBACK_KEY_FIELD, 0, property, (void*)on_change_collection_available, ctx);
        if (ctx->property_handle == COLYSEUS_INVALID_CALLBACK_HANDLE) free(ctx);
        return ctx->property_handle;
    }

    int collection_ref_id = COLYSEUS_REF_ID(collection);
    return add_callback_internal(callbacks, collection_ref_id,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_REPLACE, NULL, (void*)handler, userdata);
}

/* ============================================================================
 * Direct collection callbacks
 * ============================================================================ */

colyseus_callback_handle_t colyseus_callbacks_array_on_add(
    colyseus_callbacks_t* callbacks,
    colyseus_array_schema_t* array,
    colyseus_item_callback_fn handler,
    void* userdata,
    bool immediate)
{
    if (!callbacks || !array || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    int ref_id = array->__refId;

    /* Call for existing items if immediate */
    if (immediate && !suppress_immediate(callbacks)) {
        for (colyseus_array_item_t* item = array->items; item; item = item->next) {
            int idx = item->index;
            handler(item->value, &idx, userdata);
        }
    }

    return add_callback_internal(callbacks, ref_id,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_ADD, NULL, (void*)handler, userdata);
}

colyseus_callback_handle_t colyseus_callbacks_array_on_remove(
    colyseus_callbacks_t* callbacks,
    colyseus_array_schema_t* array,
    colyseus_item_callback_fn handler,
    void* userdata)
{
    if (!callbacks || !array || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    return add_callback_internal(callbacks, array->__refId,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_DELETE, NULL, (void*)handler, userdata);
}

colyseus_callback_handle_t colyseus_callbacks_array_on_change(
    colyseus_callbacks_t* callbacks,
    colyseus_array_schema_t* array,
    colyseus_collection_change_callback_fn handler,
    void* userdata)
{
    if (!callbacks || !array || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    return add_callback_internal(callbacks, array->__refId,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_REPLACE, NULL, (void*)handler, userdata);
}

colyseus_callback_handle_t colyseus_callbacks_map_on_add(
    colyseus_callbacks_t* callbacks,
    colyseus_map_schema_t* map,
    colyseus_item_callback_fn handler,
    void* userdata,
    bool immediate)
{
    if (!callbacks || !map || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    int ref_id = map->__refId;

    /* Call for existing items if immediate */
    if (immediate && !suppress_immediate(callbacks)) {
        colyseus_map_item_t* item;
        colyseus_map_item_t* tmp;
        HASH_ITER(hh, map->items, item, tmp) {
            handler(item->value, item->key, userdata);
        }
    }

    return add_callback_internal(callbacks, ref_id,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_ADD, NULL, (void*)handler, userdata);
}

colyseus_callback_handle_t colyseus_callbacks_map_on_remove(
    colyseus_callbacks_t* callbacks,
    colyseus_map_schema_t* map,
    colyseus_item_callback_fn handler,
    void* userdata)
{
    if (!callbacks || !map || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    return add_callback_internal(callbacks, map->__refId,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_DELETE, NULL, (void*)handler, userdata);
}

colyseus_callback_handle_t colyseus_callbacks_map_on_change(
    colyseus_callbacks_t* callbacks,
    colyseus_map_schema_t* map,
    colyseus_collection_change_callback_fn handler,
    void* userdata)
{
    if (!callbacks || !map || !handler) {
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
    }

    return add_callback_internal(callbacks, map->__refId,
        CALLBACK_KEY_OPERATION, (int)COLYSEUS_OP_REPLACE, NULL, (void*)handler, userdata);
}
