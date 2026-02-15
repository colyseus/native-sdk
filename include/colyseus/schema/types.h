#ifndef COLYSEUS_SCHEMA_TYPES_H
#define COLYSEUS_SCHEMA_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Colyseus Schema Types
 * 
 * Primitive types: string, number, boolean, int8, uint8, int16, uint16,
 *                  int32, uint32, int64, uint64, float32, float64
 * 
 * Reference types: ref, array, map
 */

/* Forward declarations */
typedef struct colyseus_schema colyseus_schema_t;
typedef struct colyseus_array_schema colyseus_array_schema_t;
typedef struct colyseus_map_schema colyseus_map_schema_t;
typedef struct colyseus_schema_vtable colyseus_schema_vtable_t;
typedef struct colyseus_decoder colyseus_decoder_t;
typedef struct colyseus_ref_tracker colyseus_ref_tracker_t;

/* Operation codes */
typedef enum {
    COLYSEUS_OP_ADD = 128,
    COLYSEUS_OP_REPLACE = 0,
    COLYSEUS_OP_DELETE = 64,
    COLYSEUS_OP_DELETE_AND_MOVE = 96,
    COLYSEUS_OP_DELETE_AND_ADD = 192,
    COLYSEUS_OP_CLEAR = 10,
    COLYSEUS_OP_REVERSE = 15,
    COLYSEUS_OP_DELETE_BY_REFID = 33,
    COLYSEUS_OP_ADD_BY_REFID = 129,
} colyseus_operation_t;

/* Special bytes */
typedef enum {
    COLYSEUS_SPEC_SWITCH_TO_STRUCTURE = 255,
    COLYSEUS_SPEC_TYPE_ID = 213,
} colyseus_spec_t;

/* Field type enum for faster dispatch */
typedef enum {
    COLYSEUS_FIELD_STRING,
    COLYSEUS_FIELD_NUMBER,
    COLYSEUS_FIELD_BOOLEAN,
    COLYSEUS_FIELD_INT8,
    COLYSEUS_FIELD_UINT8,
    COLYSEUS_FIELD_INT16,
    COLYSEUS_FIELD_UINT16,
    COLYSEUS_FIELD_INT32,
    COLYSEUS_FIELD_UINT32,
    COLYSEUS_FIELD_INT64,
    COLYSEUS_FIELD_UINT64,
    COLYSEUS_FIELD_FLOAT32,
    COLYSEUS_FIELD_FLOAT64,
    COLYSEUS_FIELD_REF,
    COLYSEUS_FIELD_ARRAY,
    COLYSEUS_FIELD_MAP,
} colyseus_field_type_t;

/* Data change record */
typedef struct {
    int ref_id;
    uint8_t op;
    const char* field;          /* Field name for schema, NULL for collections */
    void* dynamic_index;        /* int* for array, char* for map */
    void* value;
    void* previous_value;
} colyseus_data_change_t;

/* Iterator for decoding */
typedef struct {
    int offset;
} colyseus_iterator_t;

/* Field metadata - describes a single field in a schema */
typedef struct {
    int index;                              /* Field index (from @type decorator) */
    const char* name;                       /* Field name */
    colyseus_field_type_t type;             /* Field type enum */
    const char* type_str;                   /* Type string ("string", "number", etc.) */
    size_t offset;                          /* offsetof() into struct */
    const colyseus_schema_vtable_t* child_vtable;  /* For ref/array/map of schema */
    const char* child_primitive_type;       /* For array/map of primitives */
} colyseus_field_t;

/* Schema vtable - replaces C# reflection */
struct colyseus_schema_vtable {
    const char* name;                       /* Schema type name */
    size_t size;                            /* sizeof(concrete_type) */
    colyseus_schema_t* (*create)(void);     /* Constructor */
    void (*destroy)(colyseus_schema_t*);    /* Destructor */
    const colyseus_field_t* fields;         /* Field array */
    int field_count;                        /* Number of fields */
};

/* Base schema - all schemas embed this as first member */
struct colyseus_schema {
    int __refId;
    const colyseus_schema_vtable_t* __vtable;
};

/* IRef interface - anything trackable by reference tracker */
typedef struct {
    int __refId;
} colyseus_ref_t;

/* Get refId from any ref type */
#define COLYSEUS_REF_ID(ptr) (((colyseus_ref_t*)(ptr))->__refId)

/* Check if a type is a schema child */
#define COLYSEUS_IS_SCHEMA(vtable) ((vtable) != NULL)

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_TYPES_H */
