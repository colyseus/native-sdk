#ifndef COLYSEUS_SCHEMA_REF_TRACKER_H
#define COLYSEUS_SCHEMA_REF_TRACKER_H

#include "types.h"
#include "uthash.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Reference Tracker
 *
 * Tracks all schema/collection references by refId.
 * Manages reference counting and garbage collection.
 */

/* Ref type enum */
typedef enum {
    COLYSEUS_REF_TYPE_SCHEMA,
    COLYSEUS_REF_TYPE_ARRAY,
    COLYSEUS_REF_TYPE_MAP
} colyseus_ref_type_t;

/* Reference entry in hash table */
typedef struct {
    int ref_id;
    void* ref;                  /* Pointer to schema or collection */
    int ref_count;
    colyseus_ref_type_t ref_type;
    const colyseus_schema_vtable_t* vtable;  /* For schemas, to enumerate children */
    UT_hash_handle hh;
} colyseus_ref_entry_t;

/* Deleted ref entry */
typedef struct colyseus_deleted_ref {
    int ref_id;
    struct colyseus_deleted_ref* next;
} colyseus_deleted_ref_t;

/* Reference tracker */
struct colyseus_ref_tracker {
    colyseus_ref_entry_t* refs;         /* Hash table of refs */
    colyseus_deleted_ref_t* deleted;    /* List of refs pending deletion */
};

/* Create/destroy tracker */
colyseus_ref_tracker_t* colyseus_ref_tracker_create(void);
void colyseus_ref_tracker_free(colyseus_ref_tracker_t* tracker);

/* Add a reference */
void colyseus_ref_tracker_add(colyseus_ref_tracker_t* tracker, int ref_id, void* ref,
    colyseus_ref_type_t ref_type, const colyseus_schema_vtable_t* vtable, bool increment_count);

/* Get a reference by ID */
void* colyseus_ref_tracker_get(colyseus_ref_tracker_t* tracker, int ref_id);

/* Get a reference entry by ID (returns full entry with type info) */
colyseus_ref_entry_t* colyseus_ref_tracker_get_entry(colyseus_ref_tracker_t* tracker, int ref_id);

/* Check if reference exists */
bool colyseus_ref_tracker_has(colyseus_ref_tracker_t* tracker, int ref_id);

/* Number of tracked references */
size_t colyseus_ref_tracker_count(colyseus_ref_tracker_t* tracker);

/* Remove a reference (decrements count, schedules for GC if count reaches 0) */
bool colyseus_ref_tracker_remove(colyseus_ref_tracker_t* tracker, int ref_id);

/* Run garbage collection */
void colyseus_ref_tracker_gc(colyseus_ref_tracker_t* tracker);

/* Clear all references */
void colyseus_ref_tracker_clear(colyseus_ref_tracker_t* tracker);

/*
 * Release every STATIC-schema ref the tracker holds, except `except_ref`
 * (the caller's root, which it destroys itself).
 *
 * schema-codegen's generated `destroy` recurses into `t.ref()` children but
 * NEVER into a map or array, and never frees `char*` fields. So the orphans are
 * exactly: every collection structure, the schema entries it holds, and every
 * string. That is what this releases; ref children are left to the root's own
 * recursive destroy. Freed refs are NULLed, so a later clear() skips them.
 */
void colyseus_ref_tracker_destroy_static_refs(colyseus_ref_tracker_t* tracker, void* except_ref);

/* Free the heap `char*` fields of a static schema instance (codegen's destroy
 * doesn't). Safe on dynamic instances — it does nothing. */
void colyseus_schema_free_string_fields(colyseus_schema_t* instance);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_REF_TRACKER_H */
