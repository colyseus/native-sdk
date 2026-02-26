#ifndef COLYSEUS_SCHEMA_COLLECTIONS_H
#define COLYSEUS_SCHEMA_COLLECTIONS_H

#include "types.h"
#include "ref_tracker.h"
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Collection types for Colyseus Schema
 * 
 * ArraySchema - ordered list with integer indices
 * MapSchema - key-value map with string keys
 */

/* Forward declarations */
typedef struct colyseus_array_schema colyseus_array_schema_t;
typedef struct colyseus_map_schema colyseus_map_schema_t;
typedef struct colyseus_changes colyseus_changes_t;

/* ============================================================================
 * ArraySchema
 * ============================================================================ */

/* Array item entry */
typedef struct colyseus_array_item {
    int index;
    void* value;
    struct colyseus_array_item* next;
} colyseus_array_item_t;

/* ArraySchema structure */
struct colyseus_array_schema {
    int __refId;
    
    colyseus_array_item_t* items;       /* Linked list of items */
    int count;                          /* Number of items */
    int capacity;                       /* For array-based storage */
    
    /* Type info */
    bool has_schema_child;
    const char* child_primitive_type;
    const colyseus_schema_vtable_t* child_vtable;
    
    /* Pending deletions (indices marked for removal at end of decode) */
    int* deleted_keys;
    int deleted_count;
    int deleted_capacity;
};

/* Create/destroy */
colyseus_array_schema_t* colyseus_array_schema_create(void);
void colyseus_array_schema_free(colyseus_array_schema_t* arr, colyseus_ref_tracker_t* refs);

/* Set type info */
void colyseus_array_schema_set_child_type(colyseus_array_schema_t* arr, const colyseus_schema_vtable_t* vtable);
void colyseus_array_schema_set_child_primitive(colyseus_array_schema_t* arr, const char* type);

/* Operations */
void colyseus_array_schema_set(colyseus_array_schema_t* arr, int index, void* value, uint8_t operation);
void* colyseus_array_schema_get(colyseus_array_schema_t* arr, int index);
void colyseus_array_schema_delete(colyseus_array_schema_t* arr, int index);
void colyseus_array_schema_clear(colyseus_array_schema_t* arr, colyseus_changes_t* changes, colyseus_ref_tracker_t* refs);
void colyseus_array_schema_reverse(colyseus_array_schema_t* arr);

/* Called at end of decode to finalize deletions */
void colyseus_array_schema_on_decode_end(colyseus_array_schema_t* arr);

/* Iteration */
typedef void (*colyseus_array_foreach_fn)(int index, void* value, void* userdata);
void colyseus_array_schema_foreach(colyseus_array_schema_t* arr, colyseus_array_foreach_fn callback, void* userdata);

/* Clone */
colyseus_array_schema_t* colyseus_array_schema_clone(colyseus_array_schema_t* arr);

/* ============================================================================
 * MapSchema
 * ============================================================================ */

/* Map item entry (using uthash internally) */
typedef struct colyseus_map_item {
    char* key;
    void* value;
    int field_index;                /* For tracking by numeric index */
    UT_hash_handle hh;
} colyseus_map_item_t;

/* Index to key mapping */
typedef struct colyseus_map_index {
    int index;
    char* key;
    UT_hash_handle hh;
} colyseus_map_index_t;

/* MapSchema structure */
struct colyseus_map_schema {
    int __refId;
    
    colyseus_map_item_t* items;         /* Hash table of items */
    colyseus_map_index_t* indexes;      /* Index to key mapping */
    int count;
    
    /* Type info */
    bool has_schema_child;
    const char* child_primitive_type;
    const colyseus_schema_vtable_t* child_vtable;
};

/* Create/destroy */
colyseus_map_schema_t* colyseus_map_schema_create(void);
void colyseus_map_schema_free(colyseus_map_schema_t* map, colyseus_ref_tracker_t* refs);

/* Set type info */
void colyseus_map_schema_set_child_type(colyseus_map_schema_t* map, const colyseus_schema_vtable_t* vtable);
void colyseus_map_schema_set_child_primitive(colyseus_map_schema_t* map, const char* type);

/* Index operations */
void colyseus_map_schema_set_index(colyseus_map_schema_t* map, int index, const char* key);
const char* colyseus_map_schema_get_index(colyseus_map_schema_t* map, int index);

/* Operations */
void colyseus_map_schema_set_by_index(colyseus_map_schema_t* map, int index, const char* key, void* value);
void* colyseus_map_schema_get(colyseus_map_schema_t* map, const char* key);
void* colyseus_map_schema_get_by_index(colyseus_map_schema_t* map, int index);
void colyseus_map_schema_delete_by_index(colyseus_map_schema_t* map, int index);
void colyseus_map_schema_clear(colyseus_map_schema_t* map, colyseus_changes_t* changes, colyseus_ref_tracker_t* refs);
bool colyseus_map_schema_contains(colyseus_map_schema_t* map, const char* key);

/* Iteration */
typedef void (*colyseus_map_foreach_fn)(const char* key, void* value, void* userdata);
void colyseus_map_schema_foreach(colyseus_map_schema_t* map, colyseus_map_foreach_fn callback, void* userdata);

/* Clone */
colyseus_map_schema_t* colyseus_map_schema_clone(colyseus_map_schema_t* map);

/* ============================================================================
 * Changes list (for tracking data changes during decode)
 * ============================================================================ */

struct colyseus_changes {
    colyseus_data_change_t* items;
    int count;
    int capacity;
};

colyseus_changes_t* colyseus_changes_create(void);
void colyseus_changes_free(colyseus_changes_t* changes);
void colyseus_changes_add(colyseus_changes_t* changes, colyseus_data_change_t* change);
void colyseus_changes_clear(colyseus_changes_t* changes);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_COLLECTIONS_H */
