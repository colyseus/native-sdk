#include "colyseus/schema/ref_tracker.h"
#include <stdlib.h>
#include <stdio.h>

colyseus_ref_tracker_t* colyseus_ref_tracker_create(void) {
    colyseus_ref_tracker_t* tracker = malloc(sizeof(colyseus_ref_tracker_t));
    if (!tracker) return NULL;

    tracker->refs = NULL;
    tracker->deleted = NULL;

    return tracker;
}

void colyseus_ref_tracker_free(colyseus_ref_tracker_t* tracker) {
    if (!tracker) return;

    colyseus_ref_tracker_clear(tracker);
    free(tracker);
}

void colyseus_ref_tracker_add(colyseus_ref_tracker_t* tracker, int ref_id, void* ref, bool is_schema, bool increment_count) {
    if (!tracker) return;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    if (entry) {
        /* Update existing entry */
        entry->ref = ref;
        if (increment_count) {
            entry->ref_count++;
        }
    } else {
        /* Create new entry */
        entry = malloc(sizeof(colyseus_ref_entry_t));
        if (!entry) return;

        entry->ref_id = ref_id;
        entry->ref = ref;
        entry->ref_count = increment_count ? 1 : 0;
        entry->is_schema = is_schema;

        HASH_ADD_INT(tracker->refs, ref_id, entry);
    }

    /* Remove from deleted list if present */
    colyseus_deleted_ref_t** curr = &tracker->deleted;
    while (*curr) {
        if ((*curr)->ref_id == ref_id) {
            colyseus_deleted_ref_t* to_delete = *curr;
            *curr = (*curr)->next;
            free(to_delete);
            break;
        }
        curr = &(*curr)->next;
    }
}

void* colyseus_ref_tracker_get(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return NULL;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    return entry ? entry->ref : NULL;
}

bool colyseus_ref_tracker_has(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return false;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    return entry != NULL;
}

bool colyseus_ref_tracker_remove(colyseus_ref_tracker_t* tracker, int ref_id) {
    if (!tracker) return false;

    colyseus_ref_entry_t* entry = NULL;
    HASH_FIND_INT(tracker->refs, &ref_id, entry);

    if (!entry) {
        fprintf(stderr, "Trying to remove refId that doesn't exist: %d\n", ref_id);
        return false;
    }

    entry->ref_count--;

    if (entry->ref_count <= 0) {
        /* Schedule for garbage collection */
        colyseus_deleted_ref_t* deleted = malloc(sizeof(colyseus_deleted_ref_t));
        if (deleted) {
            deleted->ref_id = ref_id;
            deleted->next = tracker->deleted;
            tracker->deleted = deleted;
        }
        return true;
    }

    return false;
}

void colyseus_ref_tracker_gc(colyseus_ref_tracker_t* tracker) {
    if (!tracker) return;

    colyseus_deleted_ref_t* curr = tracker->deleted;
    while (curr) {
        colyseus_ref_entry_t* entry = NULL;
        HASH_FIND_INT(tracker->refs, &curr->ref_id, entry);

        if (entry && entry->ref_count <= 0) {
            /* 
             * TODO: Recursively remove children
             * For now, just remove the entry from hash table.
             * The actual memory cleanup should be done by the caller
             * who owns the schema/collection objects.
             */
            HASH_DEL(tracker->refs, entry);
            free(entry);
        }

        colyseus_deleted_ref_t* to_delete = curr;
        curr = curr->next;
        free(to_delete);
    }

    tracker->deleted = NULL;
}

void colyseus_ref_tracker_clear(colyseus_ref_tracker_t* tracker) {
    if (!tracker) return;

    /* Clear refs hash table */
    colyseus_ref_entry_t* entry;
    colyseus_ref_entry_t* tmp;
    HASH_ITER(hh, tracker->refs, entry, tmp) {
        HASH_DEL(tracker->refs, entry);
        free(entry);
    }

    /* Clear deleted list */
    colyseus_deleted_ref_t* curr = tracker->deleted;
    while (curr) {
        colyseus_deleted_ref_t* to_delete = curr;
        curr = curr->next;
        free(to_delete);
    }
    tracker->deleted = NULL;
}