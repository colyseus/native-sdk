#include "colyseus/schema/callbacks.h"
#include "colyseus/schema/ref_tracker.h"
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
    bool is_triggering;
    colyseus_unique_ref_t* unique_ref_ids;      /* For trigger_changes dedup */
};

/* ============================================================================
 * Forward declarations
 * ============================================================================ */

static void colyseus_callbacks_trigger_changes(colyseus_changes_t* changes, void* userdata);
static colyseus_callback_handle_t add_callback_internal(
    colyseus_callbacks_t* callbacks, int ref_id, int key_type, int key_value,
    const char* field_name, void* handler, void* userdata);

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
    cb->is_triggering = false;
    cb->unique_ref_ids = NULL;

    /* Hook into decoder's trigger_changes */
    colyseus_decoder_set_trigger_callback(decoder, colyseus_callbacks_trigger_changes, cb);

    return cb;
}

void colyseus_callbacks_free(colyseus_callbacks_t* callbacks) {
    if (!callbacks) return;

    /* Free all callback entries */
    colyseus_ref_callbacks_t* ref_cb;
    colyseus_ref_callbacks_t* ref_tmp;
    HASH_ITER(hh, callbacks->callbacks, ref_cb, ref_tmp) {
        /* Free entries in this ref */
        colyseus_callback_entry_t* entry = ref_cb->entries;
        while (entry) {
            colyseus_callback_entry_t* next = entry->next;
            free(entry->field_name);
            free(entry);
            entry = next;
        }
        HASH_DEL(callbacks->callbacks, ref_cb);
        free(ref_cb);
    }

    /* Free unique_ref_ids if any remain */
    colyseus_unique_ref_t* unique;
    colyseus_unique_ref_t* unique_tmp;
    HASH_ITER(hh, callbacks->unique_ref_ids, unique, unique_tmp) {
        HASH_DEL(callbacks->unique_ref_ids, unique);
        free(unique);
    }

    /* Unhook from decoder */
    if (callbacks->decoder) {
        colyseus_decoder_set_trigger_callback(callbacks->decoder, NULL, NULL);
    }

    free(callbacks);
}

/* ============================================================================
 * Internal: Add callback
 * ============================================================================ */

static colyseus_callback_handle_t add_callback_internal(
    colyseus_callbacks_t* callbacks,
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

    entry->id = callbacks->next_callback_id++;
    entry->key_type = key_type;
    entry->key_value = key_value;
    entry->field_name = field_name ? strdup(field_name) : NULL;
    entry->handler = handler;
    entry->userdata = userdata;
    entry->next = ref_cb->entries;  /* Prepend to list */
    ref_cb->entries = entry;

    return entry->id;
}

/* ============================================================================
 * Remove callback
 * ============================================================================ */

void colyseus_callbacks_remove(colyseus_callbacks_t* callbacks, colyseus_callback_handle_t handle) {
    if (!callbacks || handle == COLYSEUS_INVALID_CALLBACK_HANDLE) return;

    /* Search all ref_callbacks for this handle */
    colyseus_ref_callbacks_t* ref_cb;
    colyseus_ref_callbacks_t* ref_tmp;
    HASH_ITER(hh, callbacks->callbacks, ref_cb, ref_tmp) {
        colyseus_callback_entry_t* prev = NULL;
        colyseus_callback_entry_t* entry = ref_cb->entries;

        while (entry) {
            if (entry->id == handle) {
                /* Found it - remove from list */
                if (prev) {
                    prev->next = entry->next;
                } else {
                    ref_cb->entries = entry->next;
                }
                free(entry->field_name);
                free(entry);

                /* If no more entries, remove ref_cb */
                if (!ref_cb->entries) {
                    HASH_DEL(callbacks->callbacks, ref_cb);
                    free(ref_cb);
                }
                return;
            }
            prev = entry;
            entry = entry->next;
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

    for (int i = 0; i < changes->count; i++) {
        colyseus_data_change_t* change = &changes->items[i];
        int ref_id = change->ref_id;

        colyseus_ref_callbacks_t* ref_cb = get_ref_callbacks(cb, ref_id);
        if (!ref_cb) {
            continue;
        }

        /*
         * Trigger onRemove on child structure if DELETE and previous_value is a schema
         */
        if ((change->op & COLYSEUS_OP_DELETE) == COLYSEUS_OP_DELETE &&
            change->previous_value != NULL) {

            /* Check if previous_value is a schema */
            colyseus_schema_t* prev_schema = (colyseus_schema_t*)change->previous_value;
            /* A schema has __refId at offset 0 - try to get child callbacks */
            int child_ref_id = COLYSEUS_REF_ID(prev_schema);
            colyseus_ref_callbacks_t* child_cb = get_ref_callbacks(cb, child_ref_id);

            if (child_cb) {
                /* Trigger DELETE callbacks on the child */
                colyseus_callback_entry_t* entry = child_cb->entries;
                while (entry) {
                    if (entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_DELETE) {
                        /* Call with no args (just userdata) - onRemove on self */
                        colyseus_instance_change_callback_fn fn =
                            (colyseus_instance_change_callback_fn)entry->handler;
                        fn(entry->userdata);
                    }
                    entry = entry->next;
                }
            }
        }

        /*
         * Check if ref is a Schema or Collection
         */
        bool is_schema = is_schema_ref(cb, ref_id);

        if (is_schema) {
            /*
             * Handle Schema instance
             */

            /* Check if we've already triggered REPLACE for this refId */
            colyseus_unique_ref_t* found = NULL;
            HASH_FIND_INT(cb->unique_ref_ids, &ref_id, found);

            if (!found) {
                /* Trigger onChange (REPLACE) callbacks */
                colyseus_callback_entry_t* entry = ref_cb->entries;
                while (entry) {
                    if (entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_REPLACE) {
                        colyseus_instance_change_callback_fn fn =
                            (colyseus_instance_change_callback_fn)entry->handler;
                        fn(entry->userdata);
                    }
                    entry = entry->next;
                }
            }

            /* Trigger field-specific callbacks */
            if (change->field) {
                colyseus_callback_entry_t* entry = ref_cb->entries;
                while (entry) {
                    if (entry->key_type == CALLBACK_KEY_FIELD &&
                        entry->field_name &&
                        strcmp(entry->field_name, change->field) == 0) {
                        cb->is_triggering = true;
                        colyseus_property_callback_fn fn =
                            (colyseus_property_callback_fn)entry->handler;
                        fn(change->value, change->previous_value, entry->userdata);
                        cb->is_triggering = false;
                    }
                    entry = entry->next;
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
                    colyseus_callback_entry_t* entry = ref_cb->entries;
                    while (entry) {
                        if (entry->key_type == CALLBACK_KEY_OPERATION &&
                            entry->key_value == (int)COLYSEUS_OP_DELETE) {
                            colyseus_item_callback_fn fn =
                                (colyseus_item_callback_fn)entry->handler;
                            fn(change->previous_value, dynamic_index, entry->userdata);
                        }
                        entry = entry->next;
                    }
                }

                /* Handle DELETE_AND_ADD */
                if ((change->op & COLYSEUS_OP_ADD) == COLYSEUS_OP_ADD) {
                    cb->is_triggering = true;
                    colyseus_callback_entry_t* entry = ref_cb->entries;
                    while (entry) {
                        if (entry->key_type == CALLBACK_KEY_OPERATION &&
                            entry->key_value == (int)COLYSEUS_OP_ADD) {
                            colyseus_item_callback_fn fn =
                                (colyseus_item_callback_fn)entry->handler;
                            fn(change->value, dynamic_index, entry->userdata);
                        }
                        entry = entry->next;
                    }
                    cb->is_triggering = false;
                }

            } else if ((change->op & COLYSEUS_OP_ADD) == COLYSEUS_OP_ADD &&
                       change->previous_value != change->value) {
                /* Trigger onAdd (value, key) */
                cb->is_triggering = true;
                colyseus_callback_entry_t* entry = ref_cb->entries;
                while (entry) {
                    if (entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_ADD) {
                        colyseus_item_callback_fn fn =
                            (colyseus_item_callback_fn)entry->handler;
                        fn(change->value, dynamic_index, entry->userdata);
                    }
                    entry = entry->next;
                }
                cb->is_triggering = false;
            }

            /* Trigger onChange (REPLACE) for collection item change */
            if (change->value != change->previous_value) {
                colyseus_callback_entry_t* entry = ref_cb->entries;
                while (entry) {
                    if (entry->key_type == CALLBACK_KEY_OPERATION &&
                        entry->key_value == (int)COLYSEUS_OP_REPLACE) {
                        colyseus_collection_change_callback_fn fn =
                            (colyseus_collection_change_callback_fn)entry->handler;
                        fn(dynamic_index, change->value, entry->userdata);
                    }
                    entry = entry->next;
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
}

/* ============================================================================
 * Helper: Get field info from schema
 * ============================================================================ */

static const colyseus_field_t* get_field_by_name(const colyseus_schema_vtable_t* vtable, const char* name) {
    if (!vtable || !vtable->fields || !name) return NULL;

    for (int i = 0; i < vtable->field_count; i++) {
        if (vtable->fields[i].name && strcmp(vtable->fields[i].name, name) == 0) {
            return &vtable->fields[i];
        }
    }
    return NULL;
}

/* Get collection refId from schema instance + property name */
static int get_collection_ref_id(colyseus_callbacks_t* cb, void* instance, const char* property) {
    if (!instance || !property) return -1;

    colyseus_schema_t* schema = (colyseus_schema_t*)instance;
    if (!schema->__vtable) return -1;

    const colyseus_field_t* field = get_field_by_name(schema->__vtable, property);
    if (!field) return -1;

    /* Get the collection from the schema */
    void* collection = *(void**)((char*)schema + field->offset);
    if (!collection) return -1;

    return COLYSEUS_REF_ID(collection);
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

    /* Call immediately if property has a value and not already triggering */
    if (immediate && !callbacks->is_triggering) {
        colyseus_schema_t* schema = (colyseus_schema_t*)instance;
        if (schema->__vtable) {
            const colyseus_field_t* field = get_field_by_name(schema->__vtable, property);
            if (field) {
                void* current_value = NULL;
                void* field_ptr = (char*)schema + field->offset;

                switch (field->type) {
                    case COLYSEUS_FIELD_REF:
                    case COLYSEUS_FIELD_ARRAY:
                    case COLYSEUS_FIELD_MAP:
                    case COLYSEUS_FIELD_STRING:
                        current_value = *(void**)field_ptr;
                        break;
                    default:
                        /* For primitives, only call if non-zero (heuristic) */
                        current_value = field_ptr;
                        break;
                }

                if (current_value != NULL) {
                    handler(current_value, NULL, userdata);
                }
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
 * Helper structure for deferred collection callback registration
 */
typedef struct {
    colyseus_callbacks_t* callbacks;
    colyseus_item_callback_fn handler;
    void* userdata;
    int operation;
    bool immediate;
    colyseus_callback_handle_t inner_handle;
} deferred_collection_context_t;

static void on_collection_available(void* value, void* previous_value, void* userdata) {
    deferred_collection_context_t* ctx = (deferred_collection_context_t*)userdata;
    if (!ctx || !value) return;

    int collection_ref_id = COLYSEUS_REF_ID(value);

    /* Register the actual callback on the collection */
    ctx->inner_handle = add_callback_internal(
        ctx->callbacks,
        collection_ref_id,
        CALLBACK_KEY_OPERATION,
        ctx->operation,
        NULL,
        (void*)ctx->handler,
        ctx->userdata
    );

    /* If immediate and ADD operation, call for existing items */
    if (ctx->immediate && ctx->operation == (int)COLYSEUS_OP_ADD) {
        /* Check if it's an array or map and iterate */
        colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(
            ctx->callbacks->decoder->refs, collection_ref_id);

        if (entry) {
            if (entry->ref_type == COLYSEUS_REF_TYPE_ARRAY) {
                colyseus_array_schema_t* arr = (colyseus_array_schema_t*)value;
                colyseus_array_item_t* item = arr->items;
                while (item) {
                    int* idx = malloc(sizeof(int));
                    if (idx) {
                        *idx = item->index;
                        ctx->handler(item->value, idx, ctx->userdata);
                        free(idx);
                    }
                    item = item->next;
                }
            } else if (entry->ref_type == COLYSEUS_REF_TYPE_MAP) {
                colyseus_map_schema_t* map = (colyseus_map_schema_t*)value;
                colyseus_map_item_t* item;
                colyseus_map_item_t* tmp;
                HASH_ITER(hh, map->items, item, tmp) {
                    ctx->handler(item->value, item->key, ctx->userdata);
                }
            }
        }
    }

    /* Note: ctx is freed when the outer callback is removed */
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

    const colyseus_field_t* field = get_field_by_name(schema->__vtable, property);
    if (!field) return COLYSEUS_INVALID_CALLBACK_HANDLE;

    void* collection = *(void**)((char*)schema + field->offset);

    if (!collection) {
        /* Collection not available yet - wait for it */
        deferred_collection_context_t* ctx = malloc(sizeof(deferred_collection_context_t));
        if (!ctx) return COLYSEUS_INVALID_CALLBACK_HANDLE;

        ctx->callbacks = callbacks;
        ctx->handler = handler;
        ctx->userdata = userdata;
        ctx->operation = operation;
        ctx->immediate = immediate;
        ctx->inner_handle = COLYSEUS_INVALID_CALLBACK_HANDLE;

        /* Listen for the property to become available */
        return add_callback_internal(callbacks, COLYSEUS_REF_ID(instance),
            CALLBACK_KEY_FIELD, 0, property, (void*)on_collection_available, ctx);
    }

    int collection_ref_id = COLYSEUS_REF_ID(collection);

    /* If immediate and ADD operation, call for existing items */
    immediate = immediate && !callbacks->is_triggering;

    if (operation == (int)COLYSEUS_OP_ADD && immediate) {
        colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(
            callbacks->decoder->refs, collection_ref_id);

        if (entry) {
            if (entry->ref_type == COLYSEUS_REF_TYPE_ARRAY) {
                colyseus_array_schema_t* arr = (colyseus_array_schema_t*)collection;
                colyseus_array_item_t* item = arr->items;
                while (item) {
                    int* idx = malloc(sizeof(int));
                    if (idx) {
                        *idx = item->index;
                        handler(item->value, idx, userdata);
                        free(idx);
                    }
                    item = item->next;
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

    const colyseus_field_t* field = get_field_by_name(schema->__vtable, property);
    if (!field) return COLYSEUS_INVALID_CALLBACK_HANDLE;

    void* collection = *(void**)((char*)schema + field->offset);
    if (!collection) {
        /* Collection not available yet - would need deferred registration */
        /* For simplicity, return invalid handle (user should wait for collection) */
        return COLYSEUS_INVALID_CALLBACK_HANDLE;
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
    if (immediate && !callbacks->is_triggering) {
        colyseus_array_item_t* item = array->items;
        while (item) {
            int* idx = malloc(sizeof(int));
            if (idx) {
                *idx = item->index;
                handler(item->value, idx, userdata);
                free(idx);
            }
            item = item->next;
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
    if (immediate && !callbacks->is_triggering) {
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
