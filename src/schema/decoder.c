#include "colyseus/schema/decoder.h"
#include "colyseus/schema/dynamic_schema.h"
#include "colyseus/schema/quantize.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* resync bookkeeping — defined alongside the other resync helpers below */
static colyseus_resync_visited_entry_t* resync_visited_for(colyseus_decoder_t* decoder, int ref_id);

/* ============================================================================
 * Type Context
 * ============================================================================ */

colyseus_type_context_t* colyseus_type_context_create(void) {
    colyseus_type_context_t* ctx = malloc(sizeof(colyseus_type_context_t));
    if (!ctx) return NULL;
    ctx->types = NULL;
    return ctx;
}

void colyseus_type_context_free(colyseus_type_context_t* ctx) {
    if (!ctx) return;

    colyseus_type_entry_t* entry;
    colyseus_type_entry_t* tmp;
    HASH_ITER(hh, ctx->types, entry, tmp) {
        HASH_DEL(ctx->types, entry);
        free(entry);
    }

    free(ctx);
}

void colyseus_type_context_set(colyseus_type_context_t* ctx, int type_id, const colyseus_schema_vtable_t* vtable) {
    if (!ctx) return;

    colyseus_type_entry_t* entry = NULL;
    HASH_FIND_INT(ctx->types, &type_id, entry);

    if (entry) {
        entry->vtable = vtable;
    } else {
        entry = malloc(sizeof(colyseus_type_entry_t));
        if (!entry) return;
        entry->type_id = type_id;
        entry->vtable = vtable;
        HASH_ADD_INT(ctx->types, type_id, entry);
    }
}

const colyseus_schema_vtable_t* colyseus_type_context_get(colyseus_type_context_t* ctx, int type_id) {
    if (!ctx) return NULL;

    colyseus_type_entry_t* entry = NULL;
    HASH_FIND_INT(ctx->types, &type_id, entry);

    return entry ? entry->vtable : NULL;
}

/* ============================================================================
 * Decoder
 * ============================================================================ */

/* Helper to create a schema instance from a vtable (handles both static and dynamic) */
static colyseus_schema_t* create_schema_from_vtable(const colyseus_schema_vtable_t* vtable) {
    if (!vtable) return NULL;
    
    if (colyseus_vtable_is_dynamic(vtable)) {
        /* Dynamic vtable - create dynamic schema */
        const colyseus_dynamic_vtable_t* dyn_vtable = colyseus_vtable_as_dynamic(vtable);
        return (colyseus_schema_t*)colyseus_dynamic_schema_create(dyn_vtable);
    } else {
        /* Static vtable - use create function */
        return vtable->create ? vtable->create() : NULL;
    }
}

colyseus_decoder_t* colyseus_decoder_create(const colyseus_schema_vtable_t* state_vtable) {
    colyseus_decoder_t* decoder = malloc(sizeof(colyseus_decoder_t));
    if (!decoder) return NULL;

    decoder->refs = colyseus_ref_tracker_create();
    decoder->context = colyseus_type_context_create();
    decoder->changes = colyseus_changes_create();
    decoder->state_vtable = state_vtable;
    decoder->trigger_changes = NULL;
    decoder->trigger_userdata = NULL;
    decoder->resync_visited = NULL;
    decoder->resync_active = false;
    decoder->resync_damaged = false;

    /* Create initial state (handles both static and dynamic vtables) */
    decoder->state = create_schema_from_vtable(state_vtable);
    if (decoder->state) {
        /* Use helper for dynamic schemas to propagate ref_id to userdata */
        if (colyseus_vtable_is_dynamic(state_vtable)) {
            colyseus_dynamic_schema_set_ref_id((colyseus_dynamic_schema_t*)decoder->state, 0);
        } else {
            decoder->state->__refId = 0;
        }
        decoder->state->__vtable = state_vtable;
        colyseus_ref_tracker_add(decoder->refs, 0, decoder->state,
            COLYSEUS_REF_TYPE_SCHEMA, state_vtable, true);
    }

    return decoder;
}

void colyseus_decoder_free(colyseus_decoder_t* decoder) {
    if (!decoder) return;

    colyseus_decoder_teardown(decoder);
    colyseus_ref_tracker_free(decoder->refs);
    colyseus_type_context_free(decoder->context);
    colyseus_changes_free(decoder->changes);

    /* Free state if vtable has destroy function.
     * For dynamic schemas, ref_tracker_clear already destroyed everything.
     * For static schemas, we need to call destroy here. */
    if (decoder->state && decoder->state_vtable && decoder->state_vtable->destroy) {
        if (!colyseus_vtable_is_dynamic(decoder->state_vtable)) {
            decoder->state_vtable->destroy(decoder->state);
        }
    }

    free(decoder);
}

void colyseus_decoder_set_trigger_callback(colyseus_decoder_t* decoder,
    colyseus_trigger_changes_fn callback, void* userdata) {
    if (!decoder) return;
    decoder->trigger_changes = callback;
    decoder->trigger_userdata = userdata;
}

colyseus_schema_t* colyseus_decoder_get_state(colyseus_decoder_t* decoder) {
    return decoder ? decoder->state : NULL;
}

void colyseus_decoder_teardown(colyseus_decoder_t* decoder) {
    if (!decoder) return;
    colyseus_ref_tracker_clear(decoder->refs);
}

/* ============================================================================
 * Ref type detection helpers
 * ============================================================================ */

typedef enum {
    DECODE_REF_SCHEMA,
    DECODE_REF_ARRAY,
    DECODE_REF_MAP,
    DECODE_REF_UNKNOWN
} decode_ref_type_t;

/* Track ref types for proper dispatch */
typedef struct decode_ref_info {
    int ref_id;
    decode_ref_type_t type;
    UT_hash_handle hh;
} decode_ref_info_t;

/* Get decode ref type from ref_tracker's stored type */
static decode_ref_type_t get_ref_type(colyseus_decoder_t* decoder, int ref_id) {
    if (!decoder || !decoder->refs) return DECODE_REF_UNKNOWN;
    
    colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(decoder->refs, ref_id);
    if (!entry) return DECODE_REF_UNKNOWN;
    
    /* Map ref_tracker's ref_type to decode_ref_type */
    switch (entry->ref_type) {
        case COLYSEUS_REF_TYPE_SCHEMA:
            return DECODE_REF_SCHEMA;
        case COLYSEUS_REF_TYPE_ARRAY:
            return DECODE_REF_ARRAY;
        case COLYSEUS_REF_TYPE_MAP:
            return DECODE_REF_MAP;
        default:
            return DECODE_REF_UNKNOWN;
    }
}

/* ============================================================================
 * Internal decode helpers
 * ============================================================================ */

/* Forward declarations */
static bool decode_schema(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length,
    colyseus_iterator_t* it, colyseus_schema_t* schema);
static bool decode_array_schema(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length,
    colyseus_iterator_t* it, colyseus_array_schema_t* arr);
static bool decode_map_schema(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length,
    colyseus_iterator_t* it, colyseus_map_schema_t* map);

/* Get concrete schema type from bytes (handles TYPE_ID marker) */
static const colyseus_schema_vtable_t* get_schema_type(colyseus_decoder_t* decoder,
    const uint8_t* bytes, size_t length, colyseus_iterator_t* it,
    const colyseus_schema_vtable_t* default_type) {

    if (it->offset < (int)length && bytes[it->offset] == (uint8_t)COLYSEUS_SPEC_TYPE_ID) {
        it->offset++;
        int type_id = colyseus_decode_varint(bytes, it);
        const colyseus_schema_vtable_t* vtable = colyseus_type_context_get(decoder->context, type_id);
        return vtable ? vtable : default_type;
    }
    return default_type;
}

/* Find field by index in vtable (handles both static and dynamic vtables) */
static const colyseus_field_t* find_field_by_index(const colyseus_schema_vtable_t* vtable, int index) {
    if (!vtable) return NULL;

    /* Check for dynamic vtable first */
    if (colyseus_vtable_is_dynamic(vtable)) {
        const colyseus_dynamic_vtable_t* dyn_vtable = colyseus_vtable_as_dynamic(vtable);
        const colyseus_dynamic_field_t* dyn_field = colyseus_dynamic_vtable_find_field(dyn_vtable, index);
        /* Note: For dynamic fields, we return NULL and handle them separately */
        (void)dyn_field;
        return NULL;  /* Dynamic vtables use different field handling */
    }
    
    /* Static vtable */
    if (!vtable->fields) return NULL;

    for (int i = 0; i < vtable->field_count; i++) {
        if (vtable->fields[i].index == index) {
            return &vtable->fields[i];
        }
    }
    return NULL;
}

/* Find dynamic field by index */
static const colyseus_dynamic_field_t* find_dyn_field_by_index(const colyseus_schema_vtable_t* vtable, int index) {
    if (!vtable || !colyseus_vtable_is_dynamic(vtable)) return NULL;
    
    const colyseus_dynamic_vtable_t* dyn_vtable = colyseus_vtable_as_dynamic(vtable);
    return colyseus_dynamic_vtable_find_field(dyn_vtable, index);
}

/* Helper: find index by value in array */
static int array_find_index_by_ref(colyseus_array_schema_t* arr, void* ref) {
    if (!arr || !ref) return -1;

    colyseus_array_item_t* item = arr->items;
    while (item) {
        if (item->value == ref) {
            return item->index;
        }
        item = item->next;
    }
    return -1;
}

/* Set field value in dynamic schema */
static void set_dyn_schema_field(colyseus_dynamic_schema_t* schema, 
    const colyseus_dynamic_field_t* field, void* value) {
    if (!schema || !field) return;
    
    colyseus_dynamic_value_t* dyn_value = colyseus_dynamic_value_create(field->type);
    if (!dyn_value) return;
    
    switch (field->type) {
        case COLYSEUS_FIELD_STRING:
            dyn_value->data.str = (char*)value;  /* Transfer ownership */
            break;
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT64:
        case COLYSEUS_FIELD_QUANTIZED: /* dequantized double */
            if (value) {
                dyn_value->data.num = *(double*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_FLOAT32:
            if (value) {
                dyn_value->data.f32 = *(float*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_BOOLEAN:
            if (value) {
                dyn_value->data.boolean = *(bool*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_INT8:
            if (value) {
                dyn_value->data.i8 = *(int8_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_UINT8:
            if (value) {
                dyn_value->data.u8 = *(uint8_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_INT16:
            if (value) {
                dyn_value->data.i16 = *(int16_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_UINT16:
            if (value) {
                dyn_value->data.u16 = *(uint16_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_INT32:
            if (value) {
                dyn_value->data.i32 = *(int32_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_UINT32:
            if (value) {
                dyn_value->data.u32 = *(uint32_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_INT64:
            if (value) {
                dyn_value->data.i64 = *(int64_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_UINT64:
            if (value) {
                dyn_value->data.u64 = *(uint64_t*)value;
                free(value);
            }
            break;
        case COLYSEUS_FIELD_REF:
            dyn_value->data.ref = (colyseus_dynamic_schema_t*)value;
            break;
        case COLYSEUS_FIELD_ARRAY:
            dyn_value->data.array = (colyseus_array_schema_t*)value;
            break;
        case COLYSEUS_FIELD_MAP:
            dyn_value->data.map = (colyseus_map_schema_t*)value;
            break;
    }
    
    colyseus_dynamic_schema_set(schema, field->index, field->name, dyn_value);
}

/* Get field value from dynamic schema */
static void* get_dyn_schema_field(colyseus_dynamic_schema_t* schema, 
    const colyseus_dynamic_field_t* field) {
    if (!schema || !field) return NULL;
    
    colyseus_dynamic_value_t* dyn_value = colyseus_dynamic_schema_get(schema, field->index);
    if (!dyn_value) return NULL;
    
    switch (field->type) {
        case COLYSEUS_FIELD_REF:
            return dyn_value->data.ref;
        case COLYSEUS_FIELD_ARRAY:
            return dyn_value->data.array;
        case COLYSEUS_FIELD_MAP:
            return dyn_value->data.map;
        case COLYSEUS_FIELD_STRING:
            return dyn_value->data.str;
        default:
            return &dyn_value->data;  /* Return pointer to primitive */
    }
}

/* Set field value in schema based on type (static schema) */
static void set_schema_field(colyseus_schema_t* schema, const colyseus_field_t* field, void* value) {
    if (!schema || !field) return;

    void* field_ptr = (char*)schema + field->offset;

    switch (field->type) {
        case COLYSEUS_FIELD_STRING:
            /* Free old string if present */
            if (*(char**)field_ptr) {
                free(*(char**)field_ptr);
            }
            *(char**)field_ptr = (char*)value;
            break;

        case COLYSEUS_FIELD_FLOAT32:
            if (value) {
                *(float*)field_ptr = *(float*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT64:
        case COLYSEUS_FIELD_QUANTIZED: /* dequantized double */
            if (value) {
                *(double*)field_ptr = *(double*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_BOOLEAN:
            if (value) {
                *(bool*)field_ptr = *(bool*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_INT8:
            if (value) {
                *(int8_t*)field_ptr = *(int8_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_UINT8:
            if (value) {
                *(uint8_t*)field_ptr = *(uint8_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_INT16:
            if (value) {
                *(int16_t*)field_ptr = *(int16_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_UINT16:
            if (value) {
                *(uint16_t*)field_ptr = *(uint16_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_INT32:
            if (value) {
                *(int32_t*)field_ptr = *(int32_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_UINT32:
            if (value) {
                *(uint32_t*)field_ptr = *(uint32_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_INT64:
            if (value) {
                *(int64_t*)field_ptr = *(int64_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_UINT64:
            if (value) {
                *(uint64_t*)field_ptr = *(uint64_t*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_REF:
        case COLYSEUS_FIELD_ARRAY:
        case COLYSEUS_FIELD_MAP:
            *(void**)field_ptr = value;
            break;
    }
}

/* Get field value from schema (static schema) */
static void* get_schema_field(colyseus_schema_t* schema, const colyseus_field_t* field) {
    if (!schema || !field) return NULL;
    void* field_ptr = (char*)schema + field->offset;

    switch (field->type) {
        case COLYSEUS_FIELD_REF:
        case COLYSEUS_FIELD_ARRAY:
        case COLYSEUS_FIELD_MAP:
        case COLYSEUS_FIELD_STRING:
            return *(void**)field_ptr;
        default:
            return field_ptr;  /* Return pointer to primitive */
    }
}

/* ============================================================================
 * Unified decode_value function
 * ============================================================================ */

typedef struct {
    void* value;
    void* previous_value;
} decode_value_result_t;

/*
 * Decode a value based on field type.
 *
 * Parameters:
 *   decoder       - The decoder instance
 *   bytes/length  - Input buffer
 *   it            - Iterator (current position)
 *   field_type    - Type string ("ref", "string", "number", etc.)
 *   child_vtable  - For ref/array/map of schema types
 *   child_primitive_type - For array/map of primitives
 *   operation     - The operation code
 *   previous_value - Previous value at this location (for ref counting)
 *
 * Returns decoded value. Caller is responsible for cleanup based on type.
 */
static void* decode_value(
    colyseus_decoder_t* decoder,
    const uint8_t* bytes,
    size_t length,
    colyseus_iterator_t* it,
    const char* field_type,
    const colyseus_schema_vtable_t* child_vtable,
    const char* child_primitive_type,
    uint8_t operation,
    void* previous_value)
{
    void* value = NULL;

    /* ref type (schema child) */
    if (strcmp(field_type, "ref") == 0) {
        int ref_id = colyseus_decode_varint(bytes, it);
        
        /* Check if ref exists AND is actually a SCHEMA type */
        colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(decoder->refs, ref_id);
        if (entry && entry->ref_type == COLYSEUS_REF_TYPE_SCHEMA) {
            value = entry->ref;
        }

        if ((operation & (uint8_t)COLYSEUS_OP_ADD) == (uint8_t)COLYSEUS_OP_ADD) {
            const colyseus_schema_vtable_t* concrete_type = get_schema_type(
                decoder, bytes, length, it, child_vtable);

            if (value == NULL && concrete_type) {
                /* Use helper that handles both static and dynamic vtables */
                value = create_schema_from_vtable(concrete_type);
                if (value) {
                    /* Use helper for dynamic schemas to propagate ref_id to userdata */
                    if (colyseus_vtable_is_dynamic(concrete_type)) {
                        colyseus_dynamic_schema_set_ref_id((colyseus_dynamic_schema_t*)value, ref_id);
                    } else {
                        ((colyseus_schema_t*)value)->__refId = ref_id;
                    }
                    ((colyseus_schema_t*)value)->__vtable = concrete_type;
                }
            }

            bool increment = (value != previous_value) ||
                (operation == (uint8_t)COLYSEUS_OP_DELETE_AND_ADD && value == previous_value);

            colyseus_ref_tracker_add(decoder->refs, ref_id, value,
                COLYSEUS_REF_TYPE_SCHEMA, concrete_type, increment);
        }
        return value;
    }

    /* array type */
    if (strcmp(field_type, "array") == 0) {
        int ref_id = colyseus_decode_varint(bytes, it);

        /* resync bookkeeping: mark the collection present in the payload —
         * even with zero entries — so the sweep knows it participated */
        if (decoder->resync_active) { (void)resync_visited_for(decoder, ref_id); }

        /* Check if ref exists AND is actually an ARRAY type */
        colyseus_array_schema_t* arr_ref = NULL;
        colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(decoder->refs, ref_id);
        if (entry && entry->ref_type == COLYSEUS_REF_TYPE_ARRAY) {
            arr_ref = previous_value 
                ? (colyseus_array_schema_t*)previous_value
                : (colyseus_array_schema_t*)entry->ref;
        }

        colyseus_array_schema_t* arr = arr_ref
            ? colyseus_array_schema_clone(arr_ref)
            : colyseus_array_schema_create();

        if (arr) {
            arr->__refId = ref_id;
            if (child_vtable) {
                colyseus_array_schema_set_child_type(arr, child_vtable);
            } else if (child_primitive_type) {
                colyseus_array_schema_set_child_primitive(arr, child_primitive_type);
            }
        }

        /* For new arrays (arr_ref==NULL), always increment so ref_count starts at 1.
         * For existing arrays, increment when the reference changed. */
        bool increment = (arr_ref == NULL) ||
            (arr_ref != previous_value) ||
            (operation == (uint8_t)COLYSEUS_OP_DELETE_AND_ADD && arr_ref == previous_value);

        colyseus_ref_tracker_add(decoder->refs, ref_id, arr,
            COLYSEUS_REF_TYPE_ARRAY, NULL, increment);

        return arr;
    }

    /* map type */
    if (strcmp(field_type, "map") == 0) {
        int ref_id = colyseus_decode_varint(bytes, it);

        /* resync bookkeeping: mark the collection present in the payload —
         * even with zero entries — so the sweep knows it participated */
        if (decoder->resync_active) { (void)resync_visited_for(decoder, ref_id); }

        /* Check if ref exists AND is actually a MAP type */
        colyseus_map_schema_t* map_ref = NULL;
        colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(decoder->refs, ref_id);
        if (entry && entry->ref_type == COLYSEUS_REF_TYPE_MAP) {
            map_ref = previous_value 
                ? (colyseus_map_schema_t*)previous_value
                : (colyseus_map_schema_t*)entry->ref;
        }

        colyseus_map_schema_t* map = map_ref
            ? colyseus_map_schema_clone(map_ref)
            : colyseus_map_schema_create();

        if (map) {
            map->__refId = ref_id;
            if (child_vtable) {
                colyseus_map_schema_set_child_type(map, child_vtable);
            } else if (child_primitive_type) {
                colyseus_map_schema_set_child_primitive(map, child_primitive_type);
            }
        }

        /* For new maps (map_ref==NULL), always increment so ref_count starts at 1.
         * For existing maps, increment when the reference changed. */
        bool increment = (map_ref == NULL) ||
            (map_ref != previous_value) ||
            (operation == (uint8_t)COLYSEUS_OP_DELETE_AND_ADD && map_ref == previous_value);

        colyseus_ref_tracker_add(decoder->refs, ref_id, map,
            COLYSEUS_REF_TYPE_MAP, NULL, increment);

        return map;
    }

    /* Primitive types */
    return colyseus_decode_primitive(field_type, bytes, it);
}

/* ============================================================================
 * Schema decode
 * ============================================================================ */

static bool decode_schema(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length,
    colyseus_iterator_t* it, colyseus_schema_t* schema) {

    if (!schema || !schema->__vtable) return false;

    uint8_t first_byte = bytes[it->offset++];
    uint8_t operation = (first_byte >> 6) << 6;  /* Extract operation from high bits */
    int field_index = first_byte % (operation == 0 ? 255 : operation);
    
    /* Check if this is a dynamic vtable */
    bool is_dynamic = colyseus_vtable_is_dynamic(schema->__vtable);
    
    /* For static vtables, use static field lookup */
    const colyseus_field_t* field = NULL;
    const colyseus_dynamic_field_t* dyn_field = NULL;
    
    colyseus_field_type_t field_type;
    const char* field_name = NULL;
    const char* field_type_str = NULL;
    const colyseus_schema_vtable_t* child_vtable = NULL;
    const char* child_primitive_type = NULL;
    
    if (is_dynamic) {
        dyn_field = find_dyn_field_by_index(schema->__vtable, field_index);
        if (!dyn_field) {
            return false;  /* Field not found - schema mismatch */
        }
        field_type = dyn_field->type;
        field_name = dyn_field->name;
        field_type_str = dyn_field->type_str;
        child_vtable = dyn_field->child_vtable ? &dyn_field->child_vtable->base : NULL;
        child_primitive_type = dyn_field->child_primitive_type;
    } else {
        field = find_field_by_index(schema->__vtable, field_index);
        if (!field) {
            return false;  /* Field not found - schema mismatch */
        }
        field_type = field->type;
        field_name = field->name;
        field_type_str = field->type_str;
        child_vtable = field->child_vtable;
        child_primitive_type = field->child_primitive_type;
    }

    void* previous_value = is_dynamic 
        ? get_dyn_schema_field((colyseus_dynamic_schema_t*)schema, dyn_field)
        : get_schema_field(schema, field);
    void* value = NULL;
    
    /* For string fields being deleted, we need to duplicate previous_value before it gets freed.
     * Otherwise the change record will point to freed memory when callbacks are triggered. */
    // TODO: refactor this!
    void* previous_value_for_change = previous_value;
    bool owns_previous_value = false;
    if (previous_value && field_type == COLYSEUS_FIELD_STRING && 
        (operation & (uint8_t)COLYSEUS_OP_DELETE) == (uint8_t)COLYSEUS_OP_DELETE) {
        previous_value_for_change = strdup((const char*)previous_value);
        owns_previous_value = true;
    }

    /* Handle DELETE operations */
    if ((operation & (uint8_t)COLYSEUS_OP_DELETE) == (uint8_t)COLYSEUS_OP_DELETE) {
        if (previous_value != NULL) {
            /* Check if previous value is a ref type */
            if (field_type == COLYSEUS_FIELD_REF ||
                field_type == COLYSEUS_FIELD_ARRAY ||
                field_type == COLYSEUS_FIELD_MAP) {
                colyseus_ref_tracker_remove(decoder->refs, COLYSEUS_REF_ID(previous_value));
            }
        }

        if (operation != (uint8_t)COLYSEUS_OP_DELETE_AND_ADD) {
            if (is_dynamic) {
                set_dyn_schema_field((colyseus_dynamic_schema_t*)schema, dyn_field, NULL);
            } else {
                set_schema_field(schema, field, NULL);
            }
            value = NULL;
        }
    }

    if (operation == (uint8_t)COLYSEUS_OP_DELETE) {
        /* Record change and return */
        if (previous_value != value) {
            colyseus_data_change_t change = {
                .ref_id = schema->__refId,
                .op = operation,
                .field = field_name,
                .dynamic_index = NULL,
                .value = value,
                .previous_value = previous_value_for_change,
                .field_type = field_type,
                .owns_previous_value = owns_previous_value
            };
            colyseus_changes_add(decoder->changes, &change);
            /* Transfer ownership of duplicated string to changes - don't free here */
            owns_previous_value = false;
        }
        /* Free duplicated string if change wasn't added */
        if (owns_previous_value) {
            free(previous_value_for_change);
        }
        return true;
    }

    /* Decode value using unified decode_value function */
    if (field_type == COLYSEUS_FIELD_QUANTIZED) {
        /* Quantized scalar: read the unsigned int of the descriptor's wire
         * width, then dequantize — the instance only ever holds the
         * wire-exact double (see quantize.h). */
        const colyseus_quantized_descriptor_t* desc = is_dynamic
            ? dyn_field->quantized
            : field->quantized;

        uint32_t q = (desc->bits == 8) ? colyseus_decode_uint8(bytes, it)
                   : (desc->bits == 16) ? colyseus_decode_uint16(bytes, it)
                   : colyseus_decode_uint32(bytes, it);

        double* decoded = malloc(sizeof(double));
        if (decoded) { *decoded = colyseus_dequantize(desc, q); }
        value = decoded;
    } else {
        const char* decode_type_str;
        switch (field_type) {
            case COLYSEUS_FIELD_REF:   decode_type_str = "ref"; break;
            case COLYSEUS_FIELD_ARRAY: decode_type_str = "array"; break;
            case COLYSEUS_FIELD_MAP:   decode_type_str = "map"; break;
            default:                   decode_type_str = field_type_str; break;
        }

        value = decode_value(decoder, bytes, length, it,
            decode_type_str, child_vtable, child_primitive_type,
            operation, previous_value);
    }

    /* Set field value */
    if (value != NULL || operation == (uint8_t)COLYSEUS_OP_DELETE) {
        if (is_dynamic) {
            /* For dynamic schemas, set_dyn_schema_field frees:
             * - The heap-allocated primitive from decode_value (value pointer)
             * - The old dyn_value entry (where previous_value points into)
             * Save previous_value before, and re-fetch value after. */
            if (previous_value_for_change != NULL && !owns_previous_value) {
                switch (field_type) {
                    case COLYSEUS_FIELD_STRING: {
                        previous_value_for_change = strdup((const char*)previous_value_for_change);
                        owns_previous_value = true;
                        break;
                    }
                    case COLYSEUS_FIELD_REF:
                    case COLYSEUS_FIELD_ARRAY:
                    case COLYSEUS_FIELD_MAP:
                        /* Managed by ref_tracker, pointer stays valid */
                        break;
                    default: {
                        /* Primitive: copy value (all fit in sizeof(double)) */
                        void* copy = malloc(sizeof(double));
                        if (copy) {
                            memcpy(copy, previous_value_for_change, sizeof(double));
                            previous_value_for_change = copy;
                            owns_previous_value = true;
                        }
                        break;
                    }
                }
            }

            set_dyn_schema_field((colyseus_dynamic_schema_t*)schema, dyn_field, value);

            /* Re-fetch — points into stable dynamic value storage */
            value = get_dyn_schema_field((colyseus_dynamic_schema_t*)schema, dyn_field);
        } else {
            set_schema_field(schema, field, value);
        }
    }

    /* Record change */
    if (previous_value != value) {
        colyseus_data_change_t change = {
            .ref_id = schema->__refId,
            .op = operation,
            .field = field_name,
            .dynamic_index = NULL,
            .value = value,
            .previous_value = previous_value_for_change,
            .field_type = field_type,
            .owns_previous_value = owns_previous_value
        };
        colyseus_changes_add(decoder->changes, &change);
        /* Transfer ownership of duplicated string to changes - don't free here */
        owns_previous_value = false;
    }
    
    /* Free duplicated string if change wasn't added */
    if (owns_previous_value) {
        free(previous_value_for_change);
    }

    return true;
}

/* ============================================================================
 * Resync bookkeeping (see PORTING_RESYNC.md in @colyseus/schema)
 *
 * All entry points are guarded by `decoder->resync_active` at the call
 * sites — the normal decode path never pays for any of this.
 * ============================================================================ */

static colyseus_resync_visited_entry_t* resync_visited_for(colyseus_decoder_t* decoder, int ref_id) {
    colyseus_resync_visited_entry_t* entry = NULL;
    HASH_FIND_INT(decoder->resync_visited, &ref_id, entry);
    if (!entry) {
        entry = calloc(1, sizeof(*entry));
        if (!entry) return NULL;
        entry->ref_id = ref_id;
        HASH_ADD_INT(decoder->resync_visited, ref_id, entry);
    }
    return entry;
}

static void resync_touch_key(colyseus_decoder_t* decoder, int ref_id, const char* key) {
    if (!key) return;
    colyseus_resync_visited_entry_t* entry = resync_visited_for(decoder, ref_id);
    if (!entry) return;

    colyseus_resync_str_id_t* id = NULL;
    HASH_FIND_STR(entry->keys, key, id);
    if (!id) {
        id = malloc(sizeof(*id));
        if (!id) return;
        id->key = strdup(key); /* the visited set owns its own copy */
        HASH_ADD_KEYPTR(hh, entry->keys, id->key, strlen(id->key), id);
    }
}

static void resync_touch_index(colyseus_decoder_t* decoder, int ref_id, int index) {
    colyseus_resync_visited_entry_t* entry = resync_visited_for(decoder, ref_id);
    if (!entry) return;

    colyseus_resync_int_id_t* id = NULL;
    HASH_FIND_INT(entry->indexes, &index, id);
    if (!id) {
        id = malloc(sizeof(*id));
        if (!id) return;
        id->index = index;
        HASH_ADD_INT(entry->indexes, index, id);
    }
}

/*
 * Release a replaced occupant: full-sync emits plain ADD (never
 * DELETE_AND_ADD), so an entry whose instance changed while this client was
 * off the wire would otherwise leak its previous ref. Resync-only — a live
 * patch's plain ADD can be a positional rewrite where the occupant moved
 * and is still alive.
 */
static void resync_release_replaced(colyseus_decoder_t* decoder, int parent_ref_id,
    uint8_t operation, bool has_schema_child,
    const char* key_identity, int index_identity,
    void* previous_value, void* value)
{
    if (previous_value == NULL || previous_value == value) return;
    if (operation != (uint8_t)COLYSEUS_OP_ADD) return;
    if (!has_schema_child) return;

    colyseus_ref_tracker_remove(decoder->refs, ((colyseus_schema_t*)previous_value)->__refId);

    void* dynamic_index;
    if (key_identity) {
        dynamic_index = strdup(key_identity);
    } else {
        int* idx_ptr = malloc(sizeof(int));
        if (idx_ptr) *idx_ptr = index_identity;
        dynamic_index = idx_ptr;
    }

    colyseus_data_change_t change = {
        .ref_id = parent_ref_id,
        .op = (uint8_t)COLYSEUS_OP_DELETE,
        .field = NULL,
        .dynamic_index = dynamic_index,
        .value = NULL,
        .previous_value = previous_value,
        .field_type = COLYSEUS_FIELD_REF,
        .owns_previous_value = false
    };
    colyseus_changes_add(decoder->changes, &change);
}

static void resync_free_visited(colyseus_decoder_t* decoder) {
    colyseus_resync_visited_entry_t *entry, *tmp;
    HASH_ITER(hh, decoder->resync_visited, entry, tmp) {
        colyseus_resync_str_id_t *sid, *stmp;
        HASH_ITER(hh, entry->keys, sid, stmp) {
            HASH_DEL(entry->keys, sid);
            free(sid->key);
            free(sid);
        }
        colyseus_resync_int_id_t *iid, *itmp;
        HASH_ITER(hh, entry->indexes, iid, itmp) {
            HASH_DEL(entry->indexes, iid);
            free(iid);
        }
        HASH_DEL(decoder->resync_visited, entry);
        free(entry);
    }
}

/* ── the post-decode sweep ────────────────────────────────────────────── */

static bool resync_seen_add(colyseus_resync_int_id_t** seen, int ref_id) {
    colyseus_resync_int_id_t* entry = NULL;
    HASH_FIND_INT(*seen, &ref_id, entry);
    if (entry) return false;
    entry = malloc(sizeof(*entry));
    if (!entry) return false;
    entry->index = ref_id;
    HASH_ADD_INT(*seen, index, entry);
    return true;
}

static void resync_sweep_schema(colyseus_decoder_t* decoder, colyseus_schema_t* schema, colyseus_resync_int_id_t** seen);
static void resync_sweep_array(colyseus_decoder_t* decoder, colyseus_array_schema_t* arr, colyseus_resync_int_id_t** seen);
static void resync_sweep_map(colyseus_decoder_t* decoder, colyseus_map_schema_t* map, colyseus_resync_int_id_t** seen);

static void resync_sweep_schema(colyseus_decoder_t* decoder, colyseus_schema_t* schema, colyseus_resync_int_id_t** seen) {
    if (!schema || !schema->__vtable) return;
    if (!resync_seen_add(seen, schema->__refId)) return;

    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        const colyseus_dynamic_vtable_t* dv = colyseus_vtable_as_dynamic(schema->__vtable);
        for (int i = 0; i < dv->dyn_field_count; i++) {
            const colyseus_dynamic_field_t* field = dv->dyn_fields[i];
            if (field->type != COLYSEUS_FIELD_REF &&
                field->type != COLYSEUS_FIELD_ARRAY &&
                field->type != COLYSEUS_FIELD_MAP) {
                continue;
            }
            colyseus_dynamic_value_t* v = colyseus_dynamic_schema_get((colyseus_dynamic_schema_t*)schema, field->index);
            if (!v || !v->data.ptr) continue;

            if (field->type == COLYSEUS_FIELD_REF) {
                resync_sweep_schema(decoder, (colyseus_schema_t*)v->data.ref, seen);
            } else if (field->type == COLYSEUS_FIELD_ARRAY) {
                resync_sweep_array(decoder, v->data.array, seen);
            } else {
                resync_sweep_map(decoder, v->data.map, seen);
            }
        }
    } else {
        const colyseus_schema_vtable_t* vt = schema->__vtable;
        for (int i = 0; i < vt->field_count; i++) {
            const colyseus_field_t* field = &vt->fields[i];
            if (field->type != COLYSEUS_FIELD_REF &&
                field->type != COLYSEUS_FIELD_ARRAY &&
                field->type != COLYSEUS_FIELD_MAP) {
                continue;
            }
            void* value = *(void**)((char*)schema + field->offset);
            if (!value) continue;

            if (field->type == COLYSEUS_FIELD_REF) {
                resync_sweep_schema(decoder, (colyseus_schema_t*)value, seen);
            } else if (field->type == COLYSEUS_FIELD_ARRAY) {
                resync_sweep_array(decoder, (colyseus_array_schema_t*)value, seen);
            } else {
                resync_sweep_map(decoder, (colyseus_map_schema_t*)value, seen);
            }
        }
    }
}

static void resync_sweep_map(colyseus_decoder_t* decoder, colyseus_map_schema_t* map, colyseus_resync_int_id_t** seen) {
    if (!map) return;
    if (!resync_seen_add(seen, map->__refId)) return;

    /* absent = the collection never appeared in the payload at all — it is
     * not part of full-sync (@transient, view-invisible) and must be left
     * alone. An empty entry means "present with zero entries". */
    colyseus_resync_visited_entry_t* visited = NULL;
    HASH_FIND_INT(decoder->resync_visited, &map->__refId, visited);
    if (!visited) return;

    colyseus_map_item_t *item, *tmp;
    HASH_ITER(hh, map->items, item, tmp) {
        colyseus_resync_str_id_t* hit = NULL;
        HASH_FIND_STR(visited->keys, item->key, hit);
        if (hit) {
            /* recurse so nested collections of retained entries sweep too;
             * swept subtrees are left to the GC's transitive walk instead */
            if (map->has_schema_child && item->value) {
                resync_sweep_schema(decoder, (colyseus_schema_t*)item->value, seen);
            }
            continue;
        }

        colyseus_data_change_t change = {
            .ref_id = map->__refId,
            .op = (uint8_t)COLYSEUS_OP_DELETE,
            .field = NULL,
            .dynamic_index = strdup(item->key),
            .value = NULL,
            .previous_value = item->value,
            .field_type = map->has_schema_child ? COLYSEUS_FIELD_REF : COLYSEUS_FIELD_STRING,
            .owns_previous_value = false
        };
        colyseus_changes_add(decoder->changes, &change);

        if (map->has_schema_child && item->value) {
            colyseus_ref_tracker_remove(decoder->refs, ((colyseus_schema_t*)item->value)->__refId);
        }

        /* scrub ALL index→key rows of the swept key — including stale ones
         * left behind by re-indexing (the journal never evicts them) */
        colyseus_map_index_t *idx, *idxtmp;
        HASH_ITER(hh, map->indexes, idx, idxtmp) {
            if (strcmp(idx->key, item->key) == 0) {
                HASH_DEL(map->indexes, idx);
                free(idx->key);
                free(idx);
            }
        }

        /* same ownership as colyseus_map_schema_delete_by_index: item node +
         * key only — the value pointer stays alive for the pending change */
        HASH_DEL(map->items, item);
        free(item->key);
        free(item);
        map->count--;
    }
}

static void resync_sweep_array(colyseus_decoder_t* decoder, colyseus_array_schema_t* arr, colyseus_resync_int_id_t** seen) {
    if (!arr) return;
    if (!resync_seen_add(seen, arr->__refId)) return;

    colyseus_resync_visited_entry_t* visited = NULL;
    HASH_FIND_INT(decoder->resync_visited, &arr->__refId, visited);
    if (!visited) return;

    /* colyseus_array_schema_delete only NULLs the slot + records the key,
     * so iterating the linked list while deleting is safe */
    bool removed = false;
    for (colyseus_array_item_t* item = arr->items; item; item = item->next) {
        if (item->value == NULL) continue;

        colyseus_resync_int_id_t* hit = NULL;
        HASH_FIND_INT(visited->indexes, &item->index, hit);
        if (hit) {
            if (arr->has_schema_child) {
                resync_sweep_schema(decoder, (colyseus_schema_t*)item->value, seen);
            }
            continue;
        }

        int* idx_ptr = malloc(sizeof(int));
        if (idx_ptr) *idx_ptr = item->index;
        colyseus_data_change_t change = {
            .ref_id = arr->__refId,
            .op = (uint8_t)COLYSEUS_OP_DELETE,
            .field = NULL,
            .dynamic_index = idx_ptr,
            .value = NULL,
            .previous_value = item->value,
            .field_type = arr->has_schema_child ? COLYSEUS_FIELD_REF : COLYSEUS_FIELD_STRING,
            .owns_previous_value = false
        };
        colyseus_changes_add(decoder->changes, &change);

        if (arr->has_schema_child) {
            colyseus_ref_tracker_remove(decoder->refs, ((colyseus_schema_t*)item->value)->__refId);
        }

        colyseus_array_schema_delete(arr, item->index);
        removed = true;
    }

    if (removed) {
        /* removes the holes AND renumbers survivors 0..n-1 */
        colyseus_array_schema_on_decode_end(arr);
    }
}

static void resync_sweep(colyseus_decoder_t* decoder) {
    if (decoder->resync_damaged) {
        fprintf(stderr, "colyseus-schema: resync sweep skipped — parts of the payload could not be decoded. Stale entries may persist until the next resync.\n");
        return;
    }

    colyseus_resync_int_id_t* seen = NULL;
    resync_sweep_schema(decoder, decoder->state, &seen);

    colyseus_resync_int_id_t *entry, *tmp;
    HASH_ITER(hh, seen, entry, tmp) {
        HASH_DEL(seen, entry);
        free(entry);
    }
}

/* ============================================================================
 * Map decode
 * ============================================================================ */

static bool decode_map_schema(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length,
    colyseus_iterator_t* it, colyseus_map_schema_t* map) {

    uint8_t operation = bytes[it->offset++];

    if (operation == (uint8_t)COLYSEUS_OP_CLEAR) {
        colyseus_map_schema_clear(map, decoder->changes, decoder->refs);
        return true;
    }

    int field_index = colyseus_decode_varint(bytes, it);

    const char* field_type = map->has_schema_child ? "ref" : map->child_primitive_type;
    const colyseus_schema_vtable_t* child_vtable = map->child_vtable;

    char* dynamic_index = NULL;

    if ((operation & (uint8_t)COLYSEUS_OP_ADD) == (uint8_t)COLYSEUS_OP_ADD) {
        dynamic_index = colyseus_decode_string(bytes, it);
        colyseus_map_schema_set_index(map, field_index, dynamic_index);
    } else {
        const char* existing_key = colyseus_map_schema_get_index(map, field_index);
        dynamic_index = existing_key ? strdup(existing_key) : NULL;
    }

    void* value = NULL;
    void* previous_value = colyseus_map_schema_get_by_index(map, field_index);

    /* Handle DELETE */
    if ((operation & (uint8_t)COLYSEUS_OP_DELETE) == (uint8_t)COLYSEUS_OP_DELETE) {
        if (previous_value != NULL && map->has_schema_child) {
            colyseus_ref_tracker_remove(decoder->refs, ((colyseus_schema_t*)previous_value)->__refId);
        }
        if (operation != (uint8_t)COLYSEUS_OP_DELETE_AND_ADD) {
            colyseus_map_schema_delete_by_index(map, field_index);
        }
    }

    if (operation != (uint8_t)COLYSEUS_OP_DELETE) {
        /* Decode value using unified decode_value function */
        value = decode_value(decoder, bytes, length, it,
            field_type, child_vtable, NULL, operation, previous_value);

        if (value != NULL && dynamic_index) {
            colyseus_map_schema_set_by_index(map, field_index, dynamic_index, value);
        }
    }

    /* resync bookkeeping — record even when the value is unchanged (the
     * change list can't serve as the record: its pushes are gated). Runs
     * BEFORE dynamic_index ownership transfers to the change list. */
    if (decoder->resync_active) {
        resync_touch_key(decoder, map->__refId, dynamic_index);
        resync_release_replaced(decoder, map->__refId, operation, map->has_schema_child,
            dynamic_index, 0, previous_value, value);
    }

    /* Record change */
    if (previous_value != value) {
        colyseus_data_change_t change = {
            .ref_id = map->__refId,
            .op = operation,
            .field = NULL,
            .dynamic_index = dynamic_index,  /* Ownership transfers */
            .value = value,
            .previous_value = previous_value,
            .field_type = map->has_schema_child ? COLYSEUS_FIELD_REF : COLYSEUS_FIELD_STRING,
            .owns_previous_value = false
        };
        colyseus_changes_add(decoder->changes, &change);
    } else {
        free(dynamic_index);
    }

    return true;
}

/* ============================================================================
 * Array decode
 * ============================================================================ */

static bool decode_array_schema(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length,
    colyseus_iterator_t* it, colyseus_array_schema_t* arr) {

    uint8_t operation = bytes[it->offset++];
    int index = 0;

    if (operation == (uint8_t)COLYSEUS_OP_CLEAR) {
        colyseus_array_schema_clear(arr, decoder->changes, decoder->refs);
        return true;
    }

    if (operation == (uint8_t)COLYSEUS_OP_REVERSE) {
        colyseus_array_schema_reverse(arr);
        return true;
    }

    if (operation == (uint8_t)COLYSEUS_OP_DELETE_BY_REFID) {
        int ref_id = colyseus_decode_varint(bytes, it);
        void* item_by_ref = colyseus_ref_tracker_get(decoder->refs, ref_id);

        /* Stale DELETE — refId unknown to this decoder (mid-tick joiner
         * bootstrapped after the item was removed): no write, no change. */
        if (item_by_ref == NULL) return true;

        /* Ref-count decrement — this branch never reaches decode_value(),
         * so it must do the DELETE bookkeeping itself. Must run even when
         * the item is absent from THIS array (view membership churn). */
        colyseus_ref_tracker_remove(decoder->refs, ref_id);

        index = array_find_index_by_ref(arr, item_by_ref);

        /* Not present in this decoder's array — nothing to remove locally. */
        if (index < 0) return true;

        colyseus_array_schema_delete(arr, index);

        int* idx_ptr = malloc(sizeof(int));
        if (idx_ptr) *idx_ptr = index;

        colyseus_data_change_t change = {
            .ref_id = arr->__refId,
            .op = (uint8_t)COLYSEUS_OP_DELETE,
            .field = NULL,
            .dynamic_index = idx_ptr,
            .value = NULL,
            .previous_value = item_by_ref,
            .field_type = arr->has_schema_child ? COLYSEUS_FIELD_REF : COLYSEUS_FIELD_STRING,
            .owns_previous_value = false
        };
        colyseus_changes_add(decoder->changes, &change);
        return true;
    }

    if (operation == (uint8_t)COLYSEUS_OP_ADD_BY_REFID) {
        int ref_id = colyseus_decode_varint(bytes, it);
        void* item_by_ref = colyseus_ref_tracker_get(decoder->refs, ref_id);
        if (item_by_ref) {
            index = array_find_index_by_ref(arr, item_by_ref);
            if (index < 0) index = arr->count;
        } else {
            index = arr->count;
        }
    } else {
        index = colyseus_decode_varint(bytes, it);
    }

    const char* field_type = arr->has_schema_child ? "ref" : arr->child_primitive_type;
    const colyseus_schema_vtable_t* child_vtable = arr->child_vtable;

    void* value = NULL;
    void* previous_value = colyseus_array_schema_get(arr, index);

    /* Handle DELETE */
    if ((operation & (uint8_t)COLYSEUS_OP_DELETE) == (uint8_t)COLYSEUS_OP_DELETE) {
        if (previous_value != NULL && arr->has_schema_child) {
            colyseus_ref_tracker_remove(decoder->refs, ((colyseus_schema_t*)previous_value)->__refId);
        }
        if (operation != (uint8_t)COLYSEUS_OP_DELETE_AND_ADD) {
            colyseus_array_schema_delete(arr, index);
        }
    }

    if (operation != (uint8_t)COLYSEUS_OP_DELETE) {
        /* Decode value using unified decode_value function */
        value = decode_value(decoder, bytes, length, it,
            field_type, child_vtable, NULL, operation, previous_value);

        if (value != NULL) {
            /* resync snapshot ADDs are positional overwrites, not inserts */
            colyseus_array_schema_set(arr, index, value,
                (decoder->resync_active && operation == (uint8_t)COLYSEUS_OP_ADD)
                    ? (uint8_t)COLYSEUS_OP_REPLACE
                    : operation);
        }
    }

    /* resync bookkeeping — identity is the resolved client-side index
     * (ADD_BY_REFID resolves above, so visited indexes may be sparse) */
    if (decoder->resync_active) {
        resync_touch_index(decoder, arr->__refId, index);
        resync_release_replaced(decoder, arr->__refId, operation, arr->has_schema_child,
            NULL, index, previous_value, value);
    }

    /* Record change */
    if (previous_value != value) {
        int* idx_ptr = malloc(sizeof(int));
        if (idx_ptr) *idx_ptr = index;

        colyseus_data_change_t change = {
            .ref_id = arr->__refId,
            .op = operation,
            .field = NULL,
            .dynamic_index = idx_ptr,
            .value = value,
            .previous_value = previous_value,
            .field_type = arr->has_schema_child ? COLYSEUS_FIELD_REF : COLYSEUS_FIELD_STRING,
            .owns_previous_value = false
        };
        colyseus_changes_add(decoder->changes, &change);
    }

    return true;
}

/* ============================================================================
 * Main decode function
 * ============================================================================ */

void colyseus_decoder_decode(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length, colyseus_iterator_t* it) {
    if (!decoder || !bytes || length == 0) return;

    colyseus_iterator_t local_it = {0};
    if (!it) {
        it = &local_it;
    }

    int ref_id = 0;
    int previous_ref_id = 0;
    void* _ref = decoder->state;
    decode_ref_type_t current_ref_type = DECODE_REF_SCHEMA;

    colyseus_changes_clear(decoder->changes);

    while (it->offset < (int)length) {
        /* Check for SWITCH_TO_STRUCTURE */
        if (bytes[it->offset] == (uint8_t)COLYSEUS_SPEC_SWITCH_TO_STRUCTURE) {
            it->offset++;
            ref_id = colyseus_decode_varint(bytes, it);

            /* Finalize previous array if needed */
            if (current_ref_type == DECODE_REF_ARRAY && _ref) {
                colyseus_array_schema_on_decode_end((colyseus_array_schema_t*)_ref);
            }

            _ref = colyseus_ref_tracker_get(decoder->refs, ref_id);
            if (!_ref) {
                fprintf(stderr, "colyseus-schema: \"refId\" not found: %d (previous refId: %d)\n",
                    ref_id, previous_ref_id);

                /* a skipped range can swallow other structures' ops — resync
                 * visited data is no longer trustworthy */
                if (decoder->resync_active) { decoder->resync_damaged = true; }

                /* Skip to next SWITCH_TO_STRUCTURE with a known refId.
                 * Must validate the refId after each 0xFF marker to avoid
                 * false matches on data bytes that happen to be 0xFF. */
                while (it->offset < (int)length) {
                    if (colyseus_decode_switch_check(bytes, it)) {
                        colyseus_iterator_t peek = { .offset = it->offset + 1 };
                        int potential_ref = colyseus_decode_varint(bytes, &peek);
                        if (colyseus_ref_tracker_has(decoder->refs, potential_ref)) {
                            break;
                        }
                    }
                    it->offset++;
                }
                continue;
            }

            previous_ref_id = ref_id;

            current_ref_type = get_ref_type(decoder, ref_id);
            continue;
        }

        bool success = false;

        /* Decode based on ref type */
        switch (current_ref_type) {
            case DECODE_REF_SCHEMA:
                success = decode_schema(decoder, bytes, length, it, (colyseus_schema_t*)_ref);
                break;
            case DECODE_REF_ARRAY:
                success = decode_array_schema(decoder, bytes, length, it, (colyseus_array_schema_t*)_ref);
                break;
            case DECODE_REF_MAP:
                success = decode_map_schema(decoder, bytes, length, it, (colyseus_map_schema_t*)_ref);
                break;
            default:
                /* Try as schema first */
                success = decode_schema(decoder, bytes, length, it, (colyseus_schema_t*)_ref);
                break;
        }

        if (!success) {
            /* Schema mismatch - skip until next known structure */

            /* a skipped range can swallow other structures' ops — resync
             * visited data is no longer trustworthy */
            if (decoder->resync_active) { decoder->resync_damaged = true; }

            colyseus_iterator_t next_it = {it->offset};

            while (it->offset < (int)length) {
                if (colyseus_decode_switch_check(bytes, it)) {
                    next_it.offset = it->offset + 1;
                    int potential_ref = colyseus_decode_varint(bytes, &next_it);
                    if (colyseus_ref_tracker_has(decoder->refs, potential_ref)) {
                        break;
                    }
                }
                it->offset++;
            }
            continue;
        }
    }

    /* Finalize array if last ref was array */
    if (current_ref_type == DECODE_REF_ARRAY && _ref) {
        colyseus_array_schema_on_decode_end((colyseus_array_schema_t*)_ref);
    }

    /* resync mode: prune everything the snapshot didn't visit. Runs before
     * trigger_changes (DELETE changes fire on-remove with the real
     * previous_value) and before GC (ref_tracker_remove feeds the list). */
    if (decoder->resync_active) { resync_sweep(decoder); }

    /* Trigger changes callback */
    if (decoder->trigger_changes) {
        decoder->trigger_changes(decoder->changes, decoder->trigger_userdata);
    }

    /* Run garbage collection */
    colyseus_ref_tracker_gc(decoder->refs);
}

void colyseus_decoder_decode_resync(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length, colyseus_iterator_t* it) {
    if (!decoder) return;

    decoder->resync_visited = NULL;
    decoder->resync_active = true;
    decoder->resync_damaged = false;

    colyseus_decoder_decode(decoder, bytes, length, it);

    resync_free_visited(decoder);
    decoder->resync_visited = NULL;
    decoder->resync_active = false;
}
