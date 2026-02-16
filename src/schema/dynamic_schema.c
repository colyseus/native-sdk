#include "colyseus/schema/dynamic_schema.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ============================================================================
 * Dynamic Value
 * ============================================================================ */

colyseus_dynamic_value_t* colyseus_dynamic_value_create(colyseus_field_type_t type) {
    colyseus_dynamic_value_t* value = calloc(1, sizeof(colyseus_dynamic_value_t));
    if (!value) return NULL;
    value->type = type;
    return value;
}

void colyseus_dynamic_value_free(colyseus_dynamic_value_t* value) {
    if (!value) return;
    
    switch (value->type) {
        case COLYSEUS_FIELD_STRING:
            free(value->data.str);
            break;
        /* Note: ref/array/map are not freed here - they're managed by ref tracker */
        default:
            break;
    }
    
    free(value);
}

colyseus_dynamic_value_t* colyseus_dynamic_value_clone(const colyseus_dynamic_value_t* value) {
    if (!value) return NULL;
    
    colyseus_dynamic_value_t* clone = colyseus_dynamic_value_create(value->type);
    if (!clone) return NULL;
    
    switch (value->type) {
        case COLYSEUS_FIELD_STRING:
            clone->data.str = value->data.str ? strdup(value->data.str) : NULL;
            break;
        default:
            clone->data = value->data;
            break;
    }
    
    return clone;
}

void colyseus_dynamic_value_set_string(colyseus_dynamic_value_t* value, const char* str) {
    if (!value) return;
    free(value->data.str);
    value->data.str = str ? strdup(str) : NULL;
    value->type = COLYSEUS_FIELD_STRING;
}

void colyseus_dynamic_value_set_number(colyseus_dynamic_value_t* value, double num) {
    if (!value) return;
    value->data.num = num;
    value->type = COLYSEUS_FIELD_NUMBER;
}

void colyseus_dynamic_value_set_float32(colyseus_dynamic_value_t* value, float f32) {
    if (!value) return;
    value->data.f32 = f32;
    value->type = COLYSEUS_FIELD_FLOAT32;
}

void colyseus_dynamic_value_set_boolean(colyseus_dynamic_value_t* value, bool b) {
    if (!value) return;
    value->data.boolean = b;
    value->type = COLYSEUS_FIELD_BOOLEAN;
}

void colyseus_dynamic_value_set_int8(colyseus_dynamic_value_t* value, int8_t i) {
    if (!value) return;
    value->data.i8 = i;
    value->type = COLYSEUS_FIELD_INT8;
}

void colyseus_dynamic_value_set_uint8(colyseus_dynamic_value_t* value, uint8_t u) {
    if (!value) return;
    value->data.u8 = u;
    value->type = COLYSEUS_FIELD_UINT8;
}

void colyseus_dynamic_value_set_int16(colyseus_dynamic_value_t* value, int16_t i) {
    if (!value) return;
    value->data.i16 = i;
    value->type = COLYSEUS_FIELD_INT16;
}

void colyseus_dynamic_value_set_uint16(colyseus_dynamic_value_t* value, uint16_t u) {
    if (!value) return;
    value->data.u16 = u;
    value->type = COLYSEUS_FIELD_UINT16;
}

void colyseus_dynamic_value_set_int32(colyseus_dynamic_value_t* value, int32_t i) {
    if (!value) return;
    value->data.i32 = i;
    value->type = COLYSEUS_FIELD_INT32;
}

void colyseus_dynamic_value_set_uint32(colyseus_dynamic_value_t* value, uint32_t u) {
    if (!value) return;
    value->data.u32 = u;
    value->type = COLYSEUS_FIELD_UINT32;
}

void colyseus_dynamic_value_set_int64(colyseus_dynamic_value_t* value, int64_t i) {
    if (!value) return;
    value->data.i64 = i;
    value->type = COLYSEUS_FIELD_INT64;
}

void colyseus_dynamic_value_set_uint64(colyseus_dynamic_value_t* value, uint64_t u) {
    if (!value) return;
    value->data.u64 = u;
    value->type = COLYSEUS_FIELD_UINT64;
}

void colyseus_dynamic_value_set_ref(colyseus_dynamic_value_t* value, colyseus_dynamic_schema_t* ref) {
    if (!value) return;
    value->data.ref = ref;
    value->type = COLYSEUS_FIELD_REF;
}

void colyseus_dynamic_value_set_array(colyseus_dynamic_value_t* value, colyseus_array_schema_t* arr) {
    if (!value) return;
    value->data.array = arr;
    value->type = COLYSEUS_FIELD_ARRAY;
}

void colyseus_dynamic_value_set_map(colyseus_dynamic_value_t* value, colyseus_map_schema_t* map) {
    if (!value) return;
    value->data.map = map;
    value->type = COLYSEUS_FIELD_MAP;
}

/* ============================================================================
 * Dynamic Schema
 * ============================================================================ */

/* Forward declare internal create function for vtable */
static colyseus_schema_t* dynamic_schema_create_internal(void);

colyseus_dynamic_schema_t* colyseus_dynamic_schema_create(const colyseus_dynamic_vtable_t* vtable) {
    colyseus_dynamic_schema_t* schema = calloc(1, sizeof(colyseus_dynamic_schema_t));
    if (!schema) return NULL;
    
    schema->__refId = -1;
    schema->__vtable = vtable ? &vtable->base : NULL;
    schema->__dyn_vtable = vtable;
    schema->fields = NULL;
    schema->userdata = NULL;
    schema->free_userdata = NULL;
    
    /* Initialize fields from vtable if available */
    if (vtable && vtable->dyn_fields) {
        for (int i = 0; i < vtable->dyn_field_count; i++) {
            colyseus_dynamic_field_t* field = vtable->dyn_fields[i];
            if (field) {
                /* Create entry with null value (will be set when decoded) */
                colyseus_dynamic_field_entry_t* entry = calloc(1, sizeof(colyseus_dynamic_field_entry_t));
                if (entry) {
                    entry->index = field->index;
                    entry->name = field->name ? strdup(field->name) : NULL;
                    entry->value = NULL;
                    HASH_ADD_INT(schema->fields, index, entry);
                }
            }
        }
    }
    
    /* Create platform-specific userdata if callback is set */
    if (vtable && vtable->create_userdata) {
        schema->userdata = vtable->create_userdata(vtable, vtable->callback_context);
        schema->free_userdata = vtable->free_userdata;
    }
    
    return schema;
}

void colyseus_dynamic_schema_free(colyseus_dynamic_schema_t* schema) {
    if (!schema) return;
    
    /* Free userdata first */
    if (schema->free_userdata && schema->userdata) {
        schema->free_userdata(schema->userdata);
    }
    
    /* Free field entries */
    colyseus_dynamic_field_entry_t* entry;
    colyseus_dynamic_field_entry_t* tmp;
    HASH_ITER(hh, schema->fields, entry, tmp) {
        HASH_DEL(schema->fields, entry);
        free(entry->name);
        colyseus_dynamic_value_free(entry->value);
        free(entry);
    }
    
    free(schema);
}

colyseus_dynamic_value_t* colyseus_dynamic_schema_get(colyseus_dynamic_schema_t* schema, int field_index) {
    if (!schema) return NULL;
    
    colyseus_dynamic_field_entry_t* entry = NULL;
    HASH_FIND_INT(schema->fields, &field_index, entry);
    
    return entry ? entry->value : NULL;
}

void colyseus_dynamic_schema_set(colyseus_dynamic_schema_t* schema, int field_index,
    const char* field_name, colyseus_dynamic_value_t* value) {
    if (!schema) return;
    
    colyseus_dynamic_field_entry_t* entry = NULL;
    HASH_FIND_INT(schema->fields, &field_index, entry);
    
    if (entry) {
        /* Free old value */
        colyseus_dynamic_value_free(entry->value);
        entry->value = value;
        
        /* Update name if provided and entry doesn't have one */
        if (field_name && !entry->name) {
            entry->name = strdup(field_name);
        }
    } else {
        /* Create new entry */
        entry = calloc(1, sizeof(colyseus_dynamic_field_entry_t));
        if (!entry) {
            colyseus_dynamic_value_free(value);
            return;
        }
        entry->index = field_index;
        entry->name = field_name ? strdup(field_name) : NULL;
        entry->value = value;
        HASH_ADD_INT(schema->fields, index, entry);
    }
    
    /* Notify platform userdata if callback is set */
    if (schema->__dyn_vtable && schema->__dyn_vtable->set_field_userdata && schema->userdata) {
        const char* name = entry->name;
        if (!name && schema->__dyn_vtable) {
            const colyseus_dynamic_field_t* field = colyseus_dynamic_vtable_find_field(
                schema->__dyn_vtable, field_index);
            if (field) name = field->name;
        }
        if (name) {
            schema->__dyn_vtable->set_field_userdata(schema->userdata, name, value);
        }
    }
}

colyseus_dynamic_value_t* colyseus_dynamic_schema_get_by_name(colyseus_dynamic_schema_t* schema, const char* name) {
    if (!schema || !name) return NULL;
    
    colyseus_dynamic_field_entry_t* entry;
    colyseus_dynamic_field_entry_t* tmp;
    HASH_ITER(hh, schema->fields, entry, tmp) {
        if (entry->name && strcmp(entry->name, name) == 0) {
            return entry->value;
        }
    }
    
    return NULL;
}

void colyseus_dynamic_schema_foreach(colyseus_dynamic_schema_t* schema,
    colyseus_dynamic_schema_foreach_fn callback, void* userdata) {
    if (!schema || !callback) return;
    
    colyseus_dynamic_field_entry_t* entry;
    colyseus_dynamic_field_entry_t* tmp;
    HASH_ITER(hh, schema->fields, entry, tmp) {
        callback(entry->index, entry->name, entry->value, userdata);
    }
}

/* ============================================================================
 * Dynamic Field
 * ============================================================================ */

colyseus_dynamic_field_t* colyseus_dynamic_field_create(int index, const char* name,
    colyseus_field_type_t type, const char* type_str) {
    colyseus_dynamic_field_t* field = calloc(1, sizeof(colyseus_dynamic_field_t));
    if (!field) return NULL;
    
    field->index = index;
    field->name = name ? strdup(name) : NULL;
    field->type = type;
    field->type_str = type_str ? strdup(type_str) : NULL;
    field->child_vtable = NULL;
    field->child_primitive_type = NULL;
    
    return field;
}

void colyseus_dynamic_field_free(colyseus_dynamic_field_t* field) {
    if (!field) return;
    free(field->name);
    free(field->type_str);
    free(field->child_primitive_type);
    free(field);
}

/* ============================================================================
 * Dynamic Vtable
 * ============================================================================ */

/* Marker to identify dynamic vtables */
#define DYNAMIC_VTABLE_MAGIC_SIZE ((size_t)0xDEADBEEF)

/* Internal create function that returns colyseus_schema_t* for vtable compatibility */
static colyseus_schema_t* dynamic_schema_create_for_vtable(void) {
    /* This will be replaced with the actual vtable when set */
    return NULL;
}

/* Internal destroy function */
static void dynamic_schema_destroy_for_vtable(colyseus_schema_t* schema) {
    colyseus_dynamic_schema_free((colyseus_dynamic_schema_t*)schema);
}

colyseus_dynamic_vtable_t* colyseus_dynamic_vtable_create(const char* name) {
    colyseus_dynamic_vtable_t* vtable = calloc(1, sizeof(colyseus_dynamic_vtable_t));
    if (!vtable) return NULL;
    
    /* Initialize base vtable */
    vtable->base.name = name ? strdup(name) : NULL;
    vtable->base.size = DYNAMIC_VTABLE_MAGIC_SIZE;  /* Magic marker */
    vtable->base.create = NULL;  /* Will be set during finalization */
    vtable->base.destroy = dynamic_schema_destroy_for_vtable;
    vtable->base.fields = NULL;  /* Dynamic vtables don't use static fields */
    vtable->base.field_count = 0;
    
    /* Initialize dynamic fields */
    vtable->dyn_fields = NULL;
    vtable->dyn_field_count = 0;
    
    /* Initialize callbacks */
    vtable->create_userdata = NULL;
    vtable->free_userdata = NULL;
    vtable->set_field_userdata = NULL;
    vtable->callback_context = NULL;
    
    vtable->is_reflection_generated = false;
    
    return vtable;
}

void colyseus_dynamic_vtable_free(colyseus_dynamic_vtable_t* vtable) {
    if (!vtable) return;
    
    /* Free name */
    free((char*)vtable->base.name);
    
    /* Free dynamic fields */
    if (vtable->dyn_fields) {
        for (int i = 0; i < vtable->dyn_field_count; i++) {
            colyseus_dynamic_field_free(vtable->dyn_fields[i]);
        }
        free(vtable->dyn_fields);
    }
    
    free(vtable);
}

void colyseus_dynamic_vtable_add_field(colyseus_dynamic_vtable_t* vtable, colyseus_dynamic_field_t* field) {
    if (!vtable || !field) return;
    
    /* Grow array */
    int new_count = vtable->dyn_field_count + 1;
    colyseus_dynamic_field_t** new_fields = realloc(vtable->dyn_fields,
        new_count * sizeof(colyseus_dynamic_field_t*));
    
    if (!new_fields) {
        colyseus_dynamic_field_free(field);
        return;
    }
    
    vtable->dyn_fields = new_fields;
    vtable->dyn_fields[vtable->dyn_field_count] = field;
    vtable->dyn_field_count = new_count;
}

void colyseus_dynamic_vtable_set_child(colyseus_dynamic_vtable_t* vtable, int field_index,
    const colyseus_dynamic_vtable_t* child_vtable) {
    if (!vtable) return;
    
    for (int i = 0; i < vtable->dyn_field_count; i++) {
        if (vtable->dyn_fields[i] && vtable->dyn_fields[i]->index == field_index) {
            vtable->dyn_fields[i]->child_vtable = child_vtable;
            return;
        }
    }
}

void colyseus_dynamic_vtable_set_callbacks(colyseus_dynamic_vtable_t* vtable,
    colyseus_create_userdata_fn create_fn,
    colyseus_free_userdata_fn free_fn,
    colyseus_set_field_fn set_field_fn,
    void* context) {
    if (!vtable) return;
    
    vtable->create_userdata = create_fn;
    vtable->free_userdata = free_fn;
    vtable->set_field_userdata = set_field_fn;
    vtable->callback_context = context;
}

const colyseus_dynamic_field_t* colyseus_dynamic_vtable_find_field(
    const colyseus_dynamic_vtable_t* vtable, int index) {
    if (!vtable || !vtable->dyn_fields) return NULL;
    
    for (int i = 0; i < vtable->dyn_field_count; i++) {
        if (vtable->dyn_fields[i] && vtable->dyn_fields[i]->index == index) {
            return vtable->dyn_fields[i];
        }
    }
    
    return NULL;
}

const colyseus_dynamic_field_t* colyseus_dynamic_vtable_find_field_by_name(
    const colyseus_dynamic_vtable_t* vtable, const char* name) {
    if (!vtable || !vtable->dyn_fields || !name) return NULL;
    
    for (int i = 0; i < vtable->dyn_field_count; i++) {
        if (vtable->dyn_fields[i] && vtable->dyn_fields[i]->name &&
            strcmp(vtable->dyn_fields[i]->name, name) == 0) {
            return vtable->dyn_fields[i];
        }
    }
    
    return NULL;
}

/* ============================================================================
 * Utility Functions
 * ============================================================================ */

bool colyseus_vtable_is_dynamic(const colyseus_schema_vtable_t* vtable) {
    if (!vtable) return false;
    return vtable->size == DYNAMIC_VTABLE_MAGIC_SIZE;
}

const colyseus_dynamic_vtable_t* colyseus_vtable_as_dynamic(const colyseus_schema_vtable_t* vtable) {
    if (!colyseus_vtable_is_dynamic(vtable)) return NULL;
    return (const colyseus_dynamic_vtable_t*)vtable;
}

colyseus_field_type_t colyseus_field_type_from_string(const char* type_str) {
    if (!type_str) return COLYSEUS_FIELD_STRING;
    
    if (strcmp(type_str, "string") == 0) return COLYSEUS_FIELD_STRING;
    if (strcmp(type_str, "number") == 0) return COLYSEUS_FIELD_NUMBER;
    if (strcmp(type_str, "boolean") == 0) return COLYSEUS_FIELD_BOOLEAN;
    if (strcmp(type_str, "int8") == 0) return COLYSEUS_FIELD_INT8;
    if (strcmp(type_str, "uint8") == 0) return COLYSEUS_FIELD_UINT8;
    if (strcmp(type_str, "int16") == 0) return COLYSEUS_FIELD_INT16;
    if (strcmp(type_str, "uint16") == 0) return COLYSEUS_FIELD_UINT16;
    if (strcmp(type_str, "int32") == 0) return COLYSEUS_FIELD_INT32;
    if (strcmp(type_str, "uint32") == 0) return COLYSEUS_FIELD_UINT32;
    if (strcmp(type_str, "int64") == 0) return COLYSEUS_FIELD_INT64;
    if (strcmp(type_str, "uint64") == 0) return COLYSEUS_FIELD_UINT64;
    if (strcmp(type_str, "float32") == 0) return COLYSEUS_FIELD_FLOAT32;
    if (strcmp(type_str, "float64") == 0) return COLYSEUS_FIELD_FLOAT64;
    if (strcmp(type_str, "ref") == 0) return COLYSEUS_FIELD_REF;
    if (strcmp(type_str, "array") == 0) return COLYSEUS_FIELD_ARRAY;
    if (strcmp(type_str, "map") == 0) return COLYSEUS_FIELD_MAP;
    
    return COLYSEUS_FIELD_STRING;  /* Default */
}

const char* colyseus_field_type_to_string(colyseus_field_type_t type) {
    switch (type) {
        case COLYSEUS_FIELD_STRING:  return "string";
        case COLYSEUS_FIELD_NUMBER:  return "number";
        case COLYSEUS_FIELD_BOOLEAN: return "boolean";
        case COLYSEUS_FIELD_INT8:    return "int8";
        case COLYSEUS_FIELD_UINT8:   return "uint8";
        case COLYSEUS_FIELD_INT16:   return "int16";
        case COLYSEUS_FIELD_UINT16:  return "uint16";
        case COLYSEUS_FIELD_INT32:   return "int32";
        case COLYSEUS_FIELD_UINT32:  return "uint32";
        case COLYSEUS_FIELD_INT64:   return "int64";
        case COLYSEUS_FIELD_UINT64:  return "uint64";
        case COLYSEUS_FIELD_FLOAT32: return "float32";
        case COLYSEUS_FIELD_FLOAT64: return "float64";
        case COLYSEUS_FIELD_REF:     return "ref";
        case COLYSEUS_FIELD_ARRAY:   return "array";
        case COLYSEUS_FIELD_MAP:     return "map";
        default:                     return "unknown";
    }
}
