#include "colyseus/schema/decoder.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

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

colyseus_decoder_t* colyseus_decoder_create(const colyseus_schema_vtable_t* state_vtable) {
    colyseus_decoder_t* decoder = malloc(sizeof(colyseus_decoder_t));
    if (!decoder) return NULL;

    decoder->refs = colyseus_ref_tracker_create();
    decoder->context = colyseus_type_context_create();
    decoder->changes = colyseus_changes_create();
    decoder->state_vtable = state_vtable;
    decoder->trigger_changes = NULL;
    decoder->trigger_userdata = NULL;

    /* Create initial state */
    decoder->state = state_vtable->create();
    if (decoder->state) {
        decoder->state->__refId = 0;
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

    /* Free state if vtable has destroy function */
    if (decoder->state && decoder->state_vtable && decoder->state_vtable->destroy) {
        decoder->state_vtable->destroy(decoder->state);
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
        int type_id = (int)colyseus_decode_number(bytes, it);
        const colyseus_schema_vtable_t* vtable = colyseus_type_context_get(decoder->context, type_id);
        return vtable ? vtable : default_type;
    }
    return default_type;
}

/* Find field by index in vtable */
static const colyseus_field_t* find_field_by_index(const colyseus_schema_vtable_t* vtable, int index) {
    if (!vtable || !vtable->fields) return NULL;

    for (int i = 0; i < vtable->field_count; i++) {
        if (vtable->fields[i].index == index) {
            return &vtable->fields[i];
        }
    }
    return NULL;
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

/* Set field value in schema based on type */
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

        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT32:
            if (value) {
                *(float*)field_ptr = *(float*)value;
                free(value);
            }
            break;

        case COLYSEUS_FIELD_FLOAT64:
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

/* Get field value from schema */
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
        int ref_id = (int)colyseus_decode_number(bytes, it);
        value = colyseus_ref_tracker_get(decoder->refs, ref_id);

        if ((operation & (uint8_t)COLYSEUS_OP_ADD) == (uint8_t)COLYSEUS_OP_ADD) {
            const colyseus_schema_vtable_t* concrete_type = get_schema_type(
                decoder, bytes, length, it, child_vtable);

            if (value == NULL && concrete_type) {
                value = concrete_type->create();
                if (value) {
                    ((colyseus_schema_t*)value)->__refId = ref_id;
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
        int ref_id = (int)colyseus_decode_number(bytes, it);

        colyseus_array_schema_t* arr_ref = colyseus_ref_tracker_has(decoder->refs, ref_id)
            ? (previous_value ? (colyseus_array_schema_t*)previous_value
                              : (colyseus_array_schema_t*)colyseus_ref_tracker_get(decoder->refs, ref_id))
            : NULL;

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
        int ref_id = (int)colyseus_decode_number(bytes, it);

        colyseus_map_schema_t* map_ref = colyseus_ref_tracker_has(decoder->refs, ref_id)
            ? (previous_value ? (colyseus_map_schema_t*)previous_value
                              : (colyseus_map_schema_t*)colyseus_ref_tracker_get(decoder->refs, ref_id))
            : NULL;

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

    const colyseus_field_t* field = find_field_by_index(schema->__vtable, field_index);
    if (!field) {
        return false;  /* Field not found - schema mismatch */
    }

    void* previous_value = get_schema_field(schema, field);
    void* value = NULL;

    /* Handle DELETE operations */
    if ((operation & (uint8_t)COLYSEUS_OP_DELETE) == (uint8_t)COLYSEUS_OP_DELETE) {
        if (previous_value != NULL) {
            /* Check if previous value is a ref type */
            if (field->type == COLYSEUS_FIELD_REF ||
                field->type == COLYSEUS_FIELD_ARRAY ||
                field->type == COLYSEUS_FIELD_MAP) {
                colyseus_ref_tracker_remove(decoder->refs, COLYSEUS_REF_ID(previous_value));
            }
        }

        if (operation != (uint8_t)COLYSEUS_OP_DELETE_AND_ADD) {
            set_schema_field(schema, field, NULL);
            value = NULL;
        }
    }

    if (operation == (uint8_t)COLYSEUS_OP_DELETE) {
        /* Record change and return */
        if (previous_value != value) {
            colyseus_data_change_t change = {
                .ref_id = schema->__refId,
                .op = operation,
                .field = field->name,
                .dynamic_index = NULL,
                .value = value,
                .previous_value = previous_value
            };
            colyseus_changes_add(decoder->changes, &change);
        }
        return true;
    }

    /* Decode value using unified decode_value function */
    const char* field_type_str;
    switch (field->type) {
        case COLYSEUS_FIELD_REF:   field_type_str = "ref"; break;
        case COLYSEUS_FIELD_ARRAY: field_type_str = "array"; break;
        case COLYSEUS_FIELD_MAP:   field_type_str = "map"; break;
        default:                   field_type_str = field->type_str; break;
    }

    value = decode_value(decoder, bytes, length, it,
        field_type_str, field->child_vtable, field->child_primitive_type,
        operation, previous_value);

    /* Set field value */
    if (value != NULL || operation == (uint8_t)COLYSEUS_OP_DELETE) {
        set_schema_field(schema, field, value);
    }

    /* Record change */
    if (previous_value != value) {
        colyseus_data_change_t change = {
            .ref_id = schema->__refId,
            .op = operation,
            .field = field->name,
            .dynamic_index = NULL,
            .value = value,
            .previous_value = previous_value
        };
        colyseus_changes_add(decoder->changes, &change);
    }

    return true;
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

    int field_index = (int)colyseus_decode_number(bytes, it);

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

    /* Record change */
    if (previous_value != value) {
        colyseus_data_change_t change = {
            .ref_id = map->__refId,
            .op = operation,
            .field = NULL,
            .dynamic_index = dynamic_index,  /* Ownership transfers */
            .value = value,
            .previous_value = previous_value
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
        int ref_id = (int)colyseus_decode_number(bytes, it);
        void* item_by_ref = colyseus_ref_tracker_get(decoder->refs, ref_id);

        /* Find index of item */
        index = array_find_index_by_ref(arr, item_by_ref);

        if (index >= 0) {
            colyseus_array_schema_delete(arr, index);

            int* idx_ptr = malloc(sizeof(int));
            if (idx_ptr) *idx_ptr = index;

            colyseus_data_change_t change = {
                .ref_id = arr->__refId,
                .op = (uint8_t)COLYSEUS_OP_DELETE,
                .field = NULL,
                .dynamic_index = idx_ptr,
                .value = NULL,
                .previous_value = item_by_ref
            };
            colyseus_changes_add(decoder->changes, &change);
        }
        return true;
    }

    if (operation == (uint8_t)COLYSEUS_OP_ADD_BY_REFID) {
        int ref_id = (int)colyseus_decode_number(bytes, it);
        void* item_by_ref = colyseus_ref_tracker_get(decoder->refs, ref_id);
        if (item_by_ref) {
            index = array_find_index_by_ref(arr, item_by_ref);
            if (index < 0) index = arr->count;
        } else {
            index = arr->count;
        }
    } else {
        index = (int)colyseus_decode_number(bytes, it);
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
            colyseus_array_schema_set(arr, index, value, operation);
        }
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
            .previous_value = previous_value
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
    void* _ref = decoder->state;
    decode_ref_type_t current_ref_type = DECODE_REF_SCHEMA;

    colyseus_changes_clear(decoder->changes);

    while (it->offset < (int)length) {
        /* Check for SWITCH_TO_STRUCTURE */
        if (bytes[it->offset] == (uint8_t)COLYSEUS_SPEC_SWITCH_TO_STRUCTURE) {
            it->offset++;
            ref_id = (int)colyseus_decode_number(bytes, it);

            /* Finalize previous array if needed */
            if (current_ref_type == DECODE_REF_ARRAY && _ref) {
                colyseus_array_schema_on_decode_end((colyseus_array_schema_t*)_ref);
            }

            _ref = colyseus_ref_tracker_get(decoder->refs, ref_id);
            if (!_ref) {
                /* refId not in tracker - might be from stale message during cleanup */
                return;
            }

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
            colyseus_iterator_t next_it = {it->offset};

            while (it->offset < (int)length) {
                if (colyseus_decode_switch_check(bytes, it)) {
                    next_it.offset = it->offset + 1;
                    int potential_ref = (int)colyseus_decode_number(bytes, &next_it);
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

    /* Trigger changes callback */
    if (decoder->trigger_changes) {
        decoder->trigger_changes(decoder->changes, decoder->trigger_userdata);
    }

    /* Run garbage collection */
    colyseus_ref_tracker_gc(decoder->refs);
}
