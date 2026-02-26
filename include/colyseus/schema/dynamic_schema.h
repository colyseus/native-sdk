#ifndef COLYSEUS_SCHEMA_DYNAMIC_H
#define COLYSEUS_SCHEMA_DYNAMIC_H

#include "types.h"
#include "collections.h"
#include "uthash.h"
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Dynamic Schema System
 * 
 * Provides flexible field storage for schemas where the structure
 * is not known at compile time (e.g., GDScript-defined schemas or
 * auto-detected from server reflection).
 */

/* Forward declarations */
typedef struct colyseus_dynamic_schema colyseus_dynamic_schema_t;
typedef struct colyseus_dynamic_vtable colyseus_dynamic_vtable_t;
typedef struct colyseus_dynamic_field colyseus_dynamic_field_t;
typedef struct colyseus_dynamic_value colyseus_dynamic_value_t;

/* ============================================================================
 * Dynamic Value
 * ============================================================================ */

/* Tagged union for storing any value type */
struct colyseus_dynamic_value {
    colyseus_field_type_t type;
    union {
        char* str;
        double num;
        float f32;
        bool boolean;
        int8_t i8;
        uint8_t u8;
        int16_t i16;
        uint16_t u16;
        int32_t i32;
        uint32_t u32;
        int64_t i64;
        uint64_t u64;
        colyseus_dynamic_schema_t* ref;
        colyseus_array_schema_t* array;
        colyseus_map_schema_t* map;
        void* ptr;  /* Generic pointer */
    } data;
};

/* Create/destroy dynamic values */
colyseus_dynamic_value_t* colyseus_dynamic_value_create(colyseus_field_type_t type);
void colyseus_dynamic_value_free(colyseus_dynamic_value_t* value);
colyseus_dynamic_value_t* colyseus_dynamic_value_clone(const colyseus_dynamic_value_t* value);

/* Value setters */
void colyseus_dynamic_value_set_string(colyseus_dynamic_value_t* value, const char* str);
void colyseus_dynamic_value_set_number(colyseus_dynamic_value_t* value, double num);
void colyseus_dynamic_value_set_float32(colyseus_dynamic_value_t* value, float f32);
void colyseus_dynamic_value_set_boolean(colyseus_dynamic_value_t* value, bool b);
void colyseus_dynamic_value_set_int8(colyseus_dynamic_value_t* value, int8_t i);
void colyseus_dynamic_value_set_uint8(colyseus_dynamic_value_t* value, uint8_t u);
void colyseus_dynamic_value_set_int16(colyseus_dynamic_value_t* value, int16_t i);
void colyseus_dynamic_value_set_uint16(colyseus_dynamic_value_t* value, uint16_t u);
void colyseus_dynamic_value_set_int32(colyseus_dynamic_value_t* value, int32_t i);
void colyseus_dynamic_value_set_uint32(colyseus_dynamic_value_t* value, uint32_t u);
void colyseus_dynamic_value_set_int64(colyseus_dynamic_value_t* value, int64_t i);
void colyseus_dynamic_value_set_uint64(colyseus_dynamic_value_t* value, uint64_t u);
void colyseus_dynamic_value_set_ref(colyseus_dynamic_value_t* value, colyseus_dynamic_schema_t* ref);
void colyseus_dynamic_value_set_array(colyseus_dynamic_value_t* value, colyseus_array_schema_t* arr);
void colyseus_dynamic_value_set_map(colyseus_dynamic_value_t* value, colyseus_map_schema_t* map);

/* ============================================================================
 * Dynamic Field Entry (stored in hash table)
 * ============================================================================ */

typedef struct colyseus_dynamic_field_entry {
    int index;                          /* Field index (key) */
    char* name;                         /* Field name */
    colyseus_dynamic_value_t* value;    /* Field value */
    UT_hash_handle hh;
} colyseus_dynamic_field_entry_t;

/* ============================================================================
 * Dynamic Schema
 * ============================================================================ */

/*
 * Dynamic schema instance that stores fields in a hash table instead of
 * fixed struct offsets. Compatible with colyseus_schema_t (same base layout).
 */
struct colyseus_dynamic_schema {
    /* Base fields - must match colyseus_schema_t layout */
    int __refId;
    const colyseus_schema_vtable_t* __vtable;
    
    /* Dynamic fields storage */
    colyseus_dynamic_field_entry_t* fields;  /* Hash table by field index */
    
    /* Reference to dynamic vtable for type info */
    const colyseus_dynamic_vtable_t* __dyn_vtable;
    
    /* Platform-specific userdata (e.g., GDScript object pointer) */
    void* userdata;
    
    /* Callback to free userdata */
    void (*free_userdata)(void* userdata);
};

/* Create/destroy dynamic schema */
colyseus_dynamic_schema_t* colyseus_dynamic_schema_create(const colyseus_dynamic_vtable_t* vtable);
void colyseus_dynamic_schema_free(colyseus_dynamic_schema_t* schema);

/* Set __refId and notify userdata (if callback is set) */
void colyseus_dynamic_schema_set_ref_id(colyseus_dynamic_schema_t* schema, int ref_id);

/* Field access by index */
colyseus_dynamic_value_t* colyseus_dynamic_schema_get(colyseus_dynamic_schema_t* schema, int field_index);
void colyseus_dynamic_schema_set(colyseus_dynamic_schema_t* schema, int field_index, 
    const char* field_name, colyseus_dynamic_value_t* value);

/* Field access by name */
colyseus_dynamic_value_t* colyseus_dynamic_schema_get_by_name(colyseus_dynamic_schema_t* schema, const char* name);

/* Iteration */
typedef void (*colyseus_dynamic_schema_foreach_fn)(int index, const char* name, 
    colyseus_dynamic_value_t* value, void* userdata);
void colyseus_dynamic_schema_foreach(colyseus_dynamic_schema_t* schema, 
    colyseus_dynamic_schema_foreach_fn callback, void* userdata);

/* ============================================================================
 * Dynamic Field Definition
 * ============================================================================ */

/*
 * Describes a field in a dynamic vtable (similar to colyseus_field_t but
 * without the offset field since dynamic schemas use hash table storage).
 */
struct colyseus_dynamic_field {
    int index;                                  /* Field index */
    char* name;                                 /* Field name (owned) */
    colyseus_field_type_t type;                 /* Field type */
    char* type_str;                             /* Type string (owned) */
    const colyseus_dynamic_vtable_t* child_vtable;  /* For ref/array/map of schema */
    char* child_primitive_type;                 /* For array/map of primitives (owned) */
};

/* Create/destroy dynamic field */
colyseus_dynamic_field_t* colyseus_dynamic_field_create(int index, const char* name,
    colyseus_field_type_t type, const char* type_str);
void colyseus_dynamic_field_free(colyseus_dynamic_field_t* field);

/* ============================================================================
 * Dynamic Vtable
 * ============================================================================ */

/* Callback for creating platform-specific instances (e.g., GDScript objects) */
typedef void* (*colyseus_create_userdata_fn)(const colyseus_dynamic_vtable_t* vtable, void* context);
typedef void (*colyseus_free_userdata_fn)(void* userdata);
typedef void (*colyseus_set_field_fn)(void* userdata, const char* name, colyseus_dynamic_value_t* value);
typedef void (*colyseus_set_ref_id_fn)(void* userdata, int ref_id);

/*
 * Dynamic vtable - extends colyseus_schema_vtable_t with dynamic capabilities.
 * 
 * The base vtable is compatible with the regular schema system, but the
 * create/destroy functions work with colyseus_dynamic_schema_t instances.
 */
struct colyseus_dynamic_vtable {
    /* Base vtable - must be first for casting compatibility */
    colyseus_schema_vtable_t base;
    
    /* Dynamic field definitions */
    colyseus_dynamic_field_t** dyn_fields;  /* Array of field pointers */
    int dyn_field_count;
    
    /* Platform callbacks for userdata handling */
    colyseus_create_userdata_fn create_userdata;
    colyseus_free_userdata_fn free_userdata;
    colyseus_set_field_fn set_field_userdata;
    colyseus_set_ref_id_fn set_ref_id_userdata;  /* Called when __refId is assigned */
    void* callback_context;  /* Context passed to callbacks (e.g., GDScript class ref) */
    
    /* Whether this is an auto-generated vtable from reflection */
    bool is_reflection_generated;
    
    /* Type ID from reflection (for context registration) */
    int type_id;
};

/* Create/destroy dynamic vtable */
colyseus_dynamic_vtable_t* colyseus_dynamic_vtable_create(const char* name);
void colyseus_dynamic_vtable_free(colyseus_dynamic_vtable_t* vtable);

/* Add field to vtable */
void colyseus_dynamic_vtable_add_field(colyseus_dynamic_vtable_t* vtable, colyseus_dynamic_field_t* field);

/* Set child vtable for a field */
void colyseus_dynamic_vtable_set_child(colyseus_dynamic_vtable_t* vtable, int field_index,
    const colyseus_dynamic_vtable_t* child_vtable);

/* Set platform callbacks */
void colyseus_dynamic_vtable_set_callbacks(colyseus_dynamic_vtable_t* vtable,
    colyseus_create_userdata_fn create_fn,
    colyseus_free_userdata_fn free_fn,
    colyseus_set_field_fn set_field_fn,
    colyseus_set_ref_id_fn set_ref_id_fn,
    void* context);

/* Find field by index */
const colyseus_dynamic_field_t* colyseus_dynamic_vtable_find_field(
    const colyseus_dynamic_vtable_t* vtable, int index);

/* Find field by name */
const colyseus_dynamic_field_t* colyseus_dynamic_vtable_find_field_by_name(
    const colyseus_dynamic_vtable_t* vtable, const char* name);

/* ============================================================================
 * Utility Functions
 * ============================================================================ */

/* Check if a vtable is dynamic */
bool colyseus_vtable_is_dynamic(const colyseus_schema_vtable_t* vtable);

/* Cast vtable to dynamic vtable (returns NULL if not dynamic) */
const colyseus_dynamic_vtable_t* colyseus_vtable_as_dynamic(const colyseus_schema_vtable_t* vtable);

/* Convert field type string to enum */
colyseus_field_type_t colyseus_field_type_from_string(const char* type_str);

/* Convert field type enum to string */
const char* colyseus_field_type_to_string(colyseus_field_type_t type);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_DYNAMIC_H */
