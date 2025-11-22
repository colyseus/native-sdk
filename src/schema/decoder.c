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
        colyseus_ref_tracker_add(decoder->refs, 0, decoder->state, true, true);
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

/* Decode a value based on field type */
static void decode_value(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length,
    colyseus_iterator_t* it, void* _ref, int field_index, const char* field_type,
    const colyseus_schema_vtable_t* child_vtable, const char* child_primitive_type,
    uint8_t operation, void** out_value, void** out_previous_value) {

    *out_previous_value = NULL;
    *out_value = NULL;

    /* Get previous value based on ref type */
    bool is_schema = false;
    bool is_array = false;
    bool is_map = false;

    /* Detect type by checking if _ref is schema, array, or map */
    /* This is a simplification - in practice you'd track this better */
    colyseus_schema_t* schema_ref = (colyseus_schema_t*)_ref;
    if (schema_ref->__vtable != NULL) {
        is_schema = true;
        *out_previous_value = schema_ref->__vtable->fields[field_index].offset > 0 ?
            *(void**)((char*)schema_ref + schema_ref->__vtable->fields[field_index].offset) : NULL;
    }

    /* Handle DELETE operations */
    if ((operation & (uint8_t)COLYSEUS_OP_DELETE) == (uint8_t)COLYSEUS_OP_DELETE) {
        if (*out_previous_value != NULL) {
            /* Check if previous value is a ref type */
            /* Flag for garbage collection */
            /* TODO: proper ref detection */
        }

        if (operation != (uint8_t)COLYSEUS_OP_DELETE_AND_ADD) {
            /* Actually delete the field */
            if (is_schema) {
                /* Set field to NULL */
            }
        }
    }

    if (operation == (uint8_t)COLYSEUS_OP_DELETE) {
        *out_value = NULL;
        return;
    }

    /* Decode based on field type */
    if (strcmp(field_type, "ref") == 0) {
        int ref_id = (int)colyseus_decode_number(bytes, it);
        *out_value = colyseus_ref_tracker_get(decoder->refs, ref_id);

        if ((operation & (uint8_t)COLYSEUS_OP_ADD) == (uint8_t)COLYSEUS_OP_ADD) {
            const colyseus_schema_vtable_t* concrete_type = get_schema_type(decoder, bytes, length, it, child_vtable);

            if (*out_value == NULL && concrete_type) {
                *out_value = concrete_type->create();
                if (*out_value) {
                    ((colyseus_schema_t*)*out_value)->__refId = ref_id;
                    ((colyseus_schema_t*)*out_value)->__vtable = concrete_type;
                }
            }

            bool increment = (*out_value != *out_previous_value) ||
                (operation == (uint8_t)COLYSEUS_OP_DELETE_AND_ADD && *out_value == *out_previous_value);

            colyseus_ref_tracker_add(decoder->refs, ref_id, *out_value, true, increment);
        }

    } else if (child_vtable == NULL && child_primitive_type == NULL) {
        /* Primitive value */
        *out_value = colyseus_decode_primitive(field_type, bytes, it);

    } else {
        /* Collection (array or map) */
        int ref_id = (int)colyseus_decode_number(bytes, it);

        void* value_ref = colyseus_ref_tracker_has(decoder->refs, ref_id)
            ? (*out_previous_value ? *out_previous_value : colyseus_ref_tracker_get(decoder->refs, ref_id))
            : NULL;

        /* Determine if array or map based on field type */
        if (strstr(field_type, "array") != NULL || strcmp(field_type, "array") == 0) {
            colyseus_array_schema_t* arr = value_ref
                ? colyseus_array_schema_clone((colyseus_array_schema_t*)value_ref)
                : colyseus_array_schema_create();

            if (arr) {
                arr->__refId = ref_id;
                if (child_vtable) {
                    colyseus_array_schema_set_child_type(arr, child_vtable);
                } else if (child_primitive_type) {
                    colyseus_array_schema_set_child_primitive(arr, child_primitive_type);
                }
            }
            *out_value = arr;

        } else if (strstr(field_type, "map") != NULL || strcmp(field_type, "map") == 0) {
            colyseus_map_schema_t* map = value_ref
                ? colyseus_map_schema_clone((colyseus_map_schema_t*)value_ref)
                : colyseus_map_schema_create();

            if (map) {
                map->__refId = ref_id;
                if (child_vtable) {
                    colyseus_map_schema_set_child_type(map, child_vtable);
                } else if (child_primitive_type) {
                    colyseus_map_schema_set_child_primitive(map, child_primitive_type);
                }
            }
            *out_value = map;
        }

        /* Handle previous value cleanup */
        if (*out_previous_value != NULL) {
            int prev_ref_id = 0;
            /* Get prev ref id - this is simplified */
            if (prev_ref_id > 0 && ref_id != prev_ref_id) {
                /* Add delete changes for each item */
            }
        }

        bool increment = (value_ref != *out_previous_value) ||
            (operation == (uint8_t)COLYSEUS_OP_DELETE_AND_ADD && value_ref == *out_previous_value);

        colyseus_ref_tracker_add(decoder->refs, ref_id, *out_value, false, increment);
    }
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

/* Decode schema fields */
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

    void* value = NULL;
    void* previous_value = NULL;

    decode_value(decoder, bytes, length, it, schema, field_index,
        field->type_str, field->child_vtable, field->child_primitive_type,
        operation, &value, &previous_value);

    /* Set field value */
    if (value != NULL) {
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
                *(float*)field_ptr = *(float*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_FLOAT64:
                *(double*)field_ptr = *(double*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_BOOLEAN:
                *(bool*)field_ptr = *(bool*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_INT8:
                *(int8_t*)field_ptr = *(int8_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_UINT8:
                *(uint8_t*)field_ptr = *(uint8_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_INT16:
                *(int16_t*)field_ptr = *(int16_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_UINT16:
                *(uint16_t*)field_ptr = *(uint16_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_INT32:
                *(int32_t*)field_ptr = *(int32_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_UINT32:
                *(uint32_t*)field_ptr = *(uint32_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_INT64:
                *(int64_t*)field_ptr = *(int64_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_UINT64:
                *(uint64_t*)field_ptr = *(uint64_t*)value;
                free(value);
                break;

            case COLYSEUS_FIELD_REF:
            case COLYSEUS_FIELD_ARRAY:
            case COLYSEUS_FIELD_MAP:
                *(void**)field_ptr = value;
                break;
        }
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

/* Decode map schema */
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
        /* Decode value */
        if (strcmp(field_type, "ref") == 0) {
            int ref_id = (int)colyseus_decode_number(bytes, it);
            value = colyseus_ref_tracker_get(decoder->refs, ref_id);

            if ((operation & (uint8_t)COLYSEUS_OP_ADD) == (uint8_t)COLYSEUS_OP_ADD) {
                const colyseus_schema_vtable_t* concrete_type = get_schema_type(decoder, bytes, length, it, child_vtable);

                if (value == NULL && concrete_type) {
                    value = concrete_type->create();
                    if (value) {
                        ((colyseus_schema_t*)value)->__refId = ref_id;
                        ((colyseus_schema_t*)value)->__vtable = concrete_type;
                    }
                }

                colyseus_ref_tracker_add(decoder->refs, ref_id, value, true, true);
            }
        } else {
            value = colyseus_decode_primitive(field_type, bytes, it);
        }

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

/* Decode array schema */
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
        index = -1;
        /* TODO: iterate to find index */

        colyseus_array_schema_delete(arr, index);

        colyseus_data_change_t change = {
            .ref_id = arr->__refId,
            .op = (uint8_t)COLYSEUS_OP_DELETE,
            .field = NULL,
            .dynamic_index = malloc(sizeof(int)),
            .value = NULL,
            .previous_value = item_by_ref
        };
        if (change.dynamic_index) {
            *(int*)change.dynamic_index = index;
        }
        colyseus_changes_add(decoder->changes, &change);
        return true;
    }

    if (operation == (uint8_t)COLYSEUS_OP_ADD_BY_REFID) {
        int ref_id = (int)colyseus_decode_number(bytes, it);
        void* item_by_ref = colyseus_ref_tracker_get(decoder->refs, ref_id);
        if (item_by_ref) {
            /* Find existing index */
            index = -1;
            /* TODO: iterate to find */
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
        /* Decode value */
        if (field_type && strcmp(field_type, "ref") == 0) {
            int ref_id = (int)colyseus_decode_number(bytes, it);
            value = colyseus_ref_tracker_get(decoder->refs, ref_id);

            if ((operation & (uint8_t)COLYSEUS_OP_ADD) == (uint8_t)COLYSEUS_OP_ADD) {
                const colyseus_schema_vtable_t* concrete_type = get_schema_type(decoder, bytes, length, it, child_vtable);

                if (value == NULL && concrete_type) {
                    value = concrete_type->create();
                    if (value) {
                        ((colyseus_schema_t*)value)->__refId = ref_id;
                        ((colyseus_schema_t*)value)->__vtable = concrete_type;
                    }
                }

                colyseus_ref_tracker_add(decoder->refs, ref_id, value, true, true);
            }
        } else if (field_type) {
            value = colyseus_decode_primitive(field_type, bytes, it);
        }

        if (value != NULL) {
            colyseus_array_schema_set(arr, index, value, operation);
        }
    }

    /* Record change */
    if (previous_value != value) {
        colyseus_data_change_t change = {
            .ref_id = arr->__refId,
            .op = operation,
            .field = NULL,
            .dynamic_index = malloc(sizeof(int)),
            .value = value,
            .previous_value = previous_value
        };
        if (change.dynamic_index) {
            *(int*)change.dynamic_index = index;
        }
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

    colyseus_changes_clear(decoder->changes);

    while (it->offset < (int)length) {
        /* Check for SWITCH_TO_STRUCTURE */
        if (bytes[it->offset] == (uint8_t)COLYSEUS_SPEC_SWITCH_TO_STRUCTURE) {
            it->offset++;
            ref_id = (int)colyseus_decode_number(bytes, it);

            /* Finalize previous array if needed */
            /* TODO: check if _ref is array and call on_decode_end */

            _ref = colyseus_ref_tracker_get(decoder->refs, ref_id);
            if (!_ref) {
                fprintf(stderr, "refId not found: %d\n", ref_id);
                return;
            }
            continue;
        }

        bool success = false;

        /* Determine type of _ref and decode accordingly */
        colyseus_schema_t* schema = (colyseus_schema_t*)_ref;
        if (schema->__vtable != NULL) {
            /* It's a schema */
            success = decode_schema(decoder, bytes, length, it, schema);
        } else {
            /* Try as collection - need better type detection */
            /* For now, assume we track collection types differently */
            /* This is a simplification */
            success = false;
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
    /* TODO: check and call on_decode_end */

    /* Trigger changes callback */
    if (decoder->trigger_changes) {
        decoder->trigger_changes(decoder->changes, decoder->trigger_userdata);
    }

    /* Run garbage collection */
    colyseus_ref_tracker_gc(decoder->refs);
}