#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ============================================================================
 * Changes list implementation
 * ============================================================================ */

colyseus_changes_t* colyseus_changes_create(void) {
    colyseus_changes_t* changes = malloc(sizeof(colyseus_changes_t));
    if (!changes) return NULL;

    changes->items = NULL;
    changes->count = 0;
    changes->capacity = 0;

    return changes;
}

void colyseus_changes_free(colyseus_changes_t* changes) {
    if (!changes) return;
    free(changes->items);
    free(changes);
}

void colyseus_changes_add(colyseus_changes_t* changes, colyseus_data_change_t* change) {
    if (!changes || !change) return;

    if (changes->count >= changes->capacity) {
        int new_capacity = changes->capacity == 0 ? 16 : changes->capacity * 2;
        colyseus_data_change_t* new_items = realloc(changes->items,
            new_capacity * sizeof(colyseus_data_change_t));
        if (!new_items) return;
        changes->items = new_items;
        changes->capacity = new_capacity;
    }

    changes->items[changes->count++] = *change;
}

void colyseus_changes_clear(colyseus_changes_t* changes) {
    if (!changes) return;
    changes->count = 0;
}

/* ============================================================================
 * ArraySchema implementation
 * ============================================================================ */

colyseus_array_schema_t* colyseus_array_schema_create(void) {
    colyseus_array_schema_t* arr = malloc(sizeof(colyseus_array_schema_t));
    if (!arr) return NULL;

    arr->__refId = 0;
    arr->items = NULL;
    arr->count = 0;
    arr->capacity = 0;
    arr->has_schema_child = false;
    arr->child_primitive_type = NULL;
    arr->child_vtable = NULL;
    arr->deleted_keys = NULL;
    arr->deleted_count = 0;
    arr->deleted_capacity = 0;

    return arr;
}

void colyseus_array_schema_free(colyseus_array_schema_t* arr, colyseus_ref_tracker_t* refs) {
    if (!arr) return;

    /* Free items */
    colyseus_array_item_t* item = arr->items;
    while (item) {
        colyseus_array_item_t* next = item->next;

        /* Free value if it's a schema child */
        if (arr->has_schema_child && item->value && refs) {
            colyseus_schema_t* schema = (colyseus_schema_t*)item->value;
            colyseus_ref_tracker_remove(refs, schema->__refId);
        }
        /* Note: primitive values would need separate handling */

        free(item);
        item = next;
    }

    free(arr->deleted_keys);
    free(arr);
}

void colyseus_array_schema_set_child_type(colyseus_array_schema_t* arr, const colyseus_schema_vtable_t* vtable) {
    if (!arr) return;
    arr->child_vtable = vtable;
    arr->has_schema_child = (vtable != NULL);
}

void colyseus_array_schema_set_child_primitive(colyseus_array_schema_t* arr, const char* type) {
    if (!arr) return;
    arr->child_primitive_type = type;
    arr->has_schema_child = false;
}

static colyseus_array_item_t* array_find_item(colyseus_array_schema_t* arr, int index) {
    colyseus_array_item_t* item = arr->items;
    while (item) {
        if (item->index == index) return item;
        item = item->next;
    }
    return NULL;
}

static void array_remove_deleted_key(colyseus_array_schema_t* arr, int index) {
    for (int i = 0; i < arr->deleted_count; i++) {
        if (arr->deleted_keys[i] == index) {
            /* Shift remaining keys */
            memmove(&arr->deleted_keys[i], &arr->deleted_keys[i + 1],
                (arr->deleted_count - i - 1) * sizeof(int));
            arr->deleted_count--;
            return;
        }
    }
}

void colyseus_array_schema_set(colyseus_array_schema_t* arr, int index, void* value, uint8_t operation) {
    if (!arr) return;

    array_remove_deleted_key(arr, index);

    colyseus_array_item_t* item = array_find_item(arr, index);

    if (index == 0 && operation == (uint8_t)COLYSEUS_OP_ADD && arr->count > 0) {
        /* Handle unshift - insert at beginning */
        colyseus_array_item_t* new_item = malloc(sizeof(colyseus_array_item_t));
        if (!new_item) return;

        /* Shift all existing indices */
        colyseus_array_item_t* curr = arr->items;
        while (curr) {
            curr->index++;
            curr = curr->next;
        }

        new_item->index = 0;
        new_item->value = value;
        new_item->next = arr->items;
        arr->items = new_item;
        arr->count++;

    } else if (operation == (uint8_t)COLYSEUS_OP_DELETE_AND_MOVE) {
        /* Remove at index, then set at index */
        if (item) {
            item->value = value;
        } else {
            colyseus_array_item_t* new_item = malloc(sizeof(colyseus_array_item_t));
            if (!new_item) return;
            new_item->index = index;
            new_item->value = value;
            new_item->next = arr->items;
            arr->items = new_item;
            arr->count++;
        }

    } else {
        /* Regular set */
        if (item) {
            item->value = value;
        } else {
            colyseus_array_item_t* new_item = malloc(sizeof(colyseus_array_item_t));
            if (!new_item) return;
            new_item->index = index;
            new_item->value = value;
            new_item->next = arr->items;
            arr->items = new_item;
            arr->count++;
        }
    }
}

void* colyseus_array_schema_get(colyseus_array_schema_t* arr, int index) {
    if (!arr) return NULL;
    colyseus_array_item_t* item = array_find_item(arr, index);
    return item ? item->value : NULL;
}

void colyseus_array_schema_delete(colyseus_array_schema_t* arr, int index) {
    if (!arr) return;

    /* Add to deleted keys */
    if (arr->deleted_count >= arr->deleted_capacity) {
        int new_cap = arr->deleted_capacity == 0 ? 8 : arr->deleted_capacity * 2;
        int* new_keys = realloc(arr->deleted_keys, new_cap * sizeof(int));
        if (!new_keys) return;
        arr->deleted_keys = new_keys;
        arr->deleted_capacity = new_cap;
    }
    arr->deleted_keys[arr->deleted_count++] = index;

    /* Set value to NULL (but keep item for now) */
    colyseus_array_item_t* item = array_find_item(arr, index);
    if (item) {
        item->value = NULL;
    }
}

void colyseus_array_schema_clear(colyseus_array_schema_t* arr, colyseus_changes_t* changes, colyseus_ref_tracker_t* refs) {
    if (!arr) return;

    /* Add change events for each item being removed */
    colyseus_array_item_t* item = arr->items;
    while (item) {
        if (changes) {
            colyseus_data_change_t change = {
                .ref_id = arr->__refId,
                .op = (uint8_t)COLYSEUS_OP_DELETE,
                .field = NULL,
                .dynamic_index = malloc(sizeof(int)),
                .value = NULL,
                .previous_value = item->value
            };
            if (change.dynamic_index) {
                *(int*)change.dynamic_index = item->index;
            }
            colyseus_changes_add(changes, &change);
        }

        if (arr->has_schema_child && item->value && refs) {
            colyseus_schema_t* schema = (colyseus_schema_t*)item->value;
            colyseus_ref_tracker_remove(refs, schema->__refId);
        }

        colyseus_array_item_t* next = item->next;
        free(item);
        item = next;
    }

    arr->items = NULL;
    arr->count = 0;
}

void colyseus_array_schema_reverse(colyseus_array_schema_t* arr) {
    if (!arr || arr->count <= 1) return;

    /* Reverse the indices */
    int max_index = 0;
    colyseus_array_item_t* item = arr->items;
    while (item) {
        if (item->index > max_index) max_index = item->index;
        item = item->next;
    }

    item = arr->items;
    while (item) {
        item->index = max_index - item->index;
        item = item->next;
    }
}

void colyseus_array_schema_on_decode_end(colyseus_array_schema_t* arr) {
    if (!arr || arr->deleted_count == 0) return;

    /* Remove items marked for deletion and compact indices */
    colyseus_array_item_t** curr = &arr->items;
    while (*curr) {
        bool should_delete = false;
        for (int i = 0; i < arr->deleted_count; i++) {
            if ((*curr)->index == arr->deleted_keys[i]) {
                should_delete = true;
                break;
            }
        }

        if (should_delete) {
            colyseus_array_item_t* to_delete = *curr;
            *curr = (*curr)->next;
            free(to_delete);
            arr->count--;
        } else {
            curr = &(*curr)->next;
        }
    }

    arr->deleted_count = 0;
}

void colyseus_array_schema_foreach(colyseus_array_schema_t* arr, colyseus_array_foreach_fn callback, void* userdata) {
    if (!arr || !callback) return;

    colyseus_array_item_t* item = arr->items;
    while (item) {
        callback(item->index, item->value, userdata);
        item = item->next;
    }
}

colyseus_array_schema_t* colyseus_array_schema_clone(colyseus_array_schema_t* arr) {
    if (!arr) return NULL;

    colyseus_array_schema_t* clone = colyseus_array_schema_create();
    if (!clone) return NULL;

    clone->has_schema_child = arr->has_schema_child;
    clone->child_primitive_type = arr->child_primitive_type;
    clone->child_vtable = arr->child_vtable;

    colyseus_array_item_t* item = arr->items;
    while (item) {
        colyseus_array_schema_set(clone, item->index, item->value, COLYSEUS_OP_ADD);
        item = item->next;
    }

    return clone;
}

/* ============================================================================
 * MapSchema implementation
 * ============================================================================ */

colyseus_map_schema_t* colyseus_map_schema_create(void) {
    colyseus_map_schema_t* map = malloc(sizeof(colyseus_map_schema_t));
    if (!map) return NULL;

    map->__refId = 0;
    map->items = NULL;
    map->indexes = NULL;
    map->count = 0;
    map->has_schema_child = false;
    map->child_primitive_type = NULL;
    map->child_vtable = NULL;

    return map;
}

void colyseus_map_schema_free(colyseus_map_schema_t* map, colyseus_ref_tracker_t* refs) {
    if (!map) return;

    /* Free items */
    colyseus_map_item_t* item;
    colyseus_map_item_t* tmp;
    HASH_ITER(hh, map->items, item, tmp) {
        HASH_DEL(map->items, item);

        if (map->has_schema_child && item->value && refs) {
            colyseus_schema_t* schema = (colyseus_schema_t*)item->value;
            colyseus_ref_tracker_remove(refs, schema->__refId);
        }

        free(item->key);
        free(item);
    }

    /* Free indexes */
    colyseus_map_index_t* idx;
    colyseus_map_index_t* tmp_idx;
    HASH_ITER(hh, map->indexes, idx, tmp_idx) {
        HASH_DEL(map->indexes, idx);
        free(idx->key);
        free(idx);
    }

    free(map);
}

void colyseus_map_schema_set_child_type(colyseus_map_schema_t* map, const colyseus_schema_vtable_t* vtable) {
    if (!map) return;
    map->child_vtable = vtable;
    map->has_schema_child = (vtable != NULL);
}

void colyseus_map_schema_set_child_primitive(colyseus_map_schema_t* map, const char* type) {
    if (!map) return;
    map->child_primitive_type = type;
    map->has_schema_child = false;
}

void colyseus_map_schema_set_index(colyseus_map_schema_t* map, int index, const char* key) {
    if (!map || !key) return;

    colyseus_map_index_t* idx = NULL;
    HASH_FIND_INT(map->indexes, &index, idx);

    if (idx) {
        free(idx->key);
        idx->key = strdup(key);
    } else {
        idx = malloc(sizeof(colyseus_map_index_t));
        if (!idx) return;
        idx->index = index;
        idx->key = strdup(key);
        HASH_ADD_INT(map->indexes, index, idx);
    }
}

const char* colyseus_map_schema_get_index(colyseus_map_schema_t* map, int index) {
    if (!map) return NULL;

    colyseus_map_index_t* idx = NULL;
    HASH_FIND_INT(map->indexes, &index, idx);

    return idx ? idx->key : NULL;
}

void colyseus_map_schema_set_by_index(colyseus_map_schema_t* map, int index, const char* key, void* value) {
    if (!map || !key) return;

    colyseus_map_schema_set_index(map, index, key);

    colyseus_map_item_t* item = NULL;
    HASH_FIND_STR(map->items, key, item);

    if (item) {
        item->value = value;
        item->field_index = index;
    } else {
        item = malloc(sizeof(colyseus_map_item_t));
        if (!item) return;
        item->key = strdup(key);
        item->value = value;
        item->field_index = index;
        HASH_ADD_KEYPTR(hh, map->items, item->key, strlen(item->key), item);
        map->count++;
    }
}

void* colyseus_map_schema_get(colyseus_map_schema_t* map, const char* key) {
    if (!map || !key) return NULL;

    colyseus_map_item_t* item = NULL;
    HASH_FIND_STR(map->items, key, item);

    return item ? item->value : NULL;
}

void* colyseus_map_schema_get_by_index(colyseus_map_schema_t* map, int index) {
    if (!map) return NULL;

    const char* key = colyseus_map_schema_get_index(map, index);
    if (!key) return NULL;

    return colyseus_map_schema_get(map, key);
}

void colyseus_map_schema_delete_by_index(colyseus_map_schema_t* map, int index) {
    if (!map) return;

    const char* key = colyseus_map_schema_get_index(map, index);
    if (!key) return;

    colyseus_map_item_t* item = NULL;
    HASH_FIND_STR(map->items, key, item);

    if (item) {
        HASH_DEL(map->items, item);
        free(item->key);
        free(item);
        map->count--;
    }

    /* Remove index mapping */
    colyseus_map_index_t* idx = NULL;
    HASH_FIND_INT(map->indexes, &index, idx);
    if (idx) {
        HASH_DEL(map->indexes, idx);
        free(idx->key);
        free(idx);
    }
}

void colyseus_map_schema_clear(colyseus_map_schema_t* map, colyseus_changes_t* changes, colyseus_ref_tracker_t* refs) {
    if (!map) return;

    /* Add change events for each item being removed */
    colyseus_map_item_t* item;
    colyseus_map_item_t* tmp;
    HASH_ITER(hh, map->items, item, tmp) {
        if (changes) {
            colyseus_data_change_t change = {
                .ref_id = map->__refId,
                .op = (uint8_t)COLYSEUS_OP_DELETE,
                .field = NULL,
                .dynamic_index = strdup(item->key),
                .value = NULL,
                .previous_value = item->value
            };
            colyseus_changes_add(changes, &change);
        }

        if (map->has_schema_child && item->value && refs) {
            colyseus_schema_t* schema = (colyseus_schema_t*)item->value;
            colyseus_ref_tracker_remove(refs, schema->__refId);
        }

        HASH_DEL(map->items, item);
        free(item->key);
        free(item);
    }

    /* Clear indexes */
    colyseus_map_index_t* idx;
    colyseus_map_index_t* tmp_idx;
    HASH_ITER(hh, map->indexes, idx, tmp_idx) {
        HASH_DEL(map->indexes, idx);
        free(idx->key);
        free(idx);
    }

    map->count = 0;
}

bool colyseus_map_schema_contains(colyseus_map_schema_t* map, const char* key) {
    if (!map || !key) return false;

    colyseus_map_item_t* item = NULL;
    HASH_FIND_STR(map->items, key, item);

    return item != NULL;
}

void colyseus_map_schema_foreach(colyseus_map_schema_t* map, colyseus_map_foreach_fn callback, void* userdata) {
    if (!map || !callback) return;

    colyseus_map_item_t* item;
    colyseus_map_item_t* tmp;
    HASH_ITER(hh, map->items, item, tmp) {
        callback(item->key, item->value, userdata);
    }
}

colyseus_map_schema_t* colyseus_map_schema_clone(colyseus_map_schema_t* map) {
    if (!map) return NULL;

    colyseus_map_schema_t* clone = colyseus_map_schema_create();
    if (!clone) return NULL;

    clone->has_schema_child = map->has_schema_child;
    clone->child_primitive_type = map->child_primitive_type;
    clone->child_vtable = map->child_vtable;

    colyseus_map_item_t* item;
    colyseus_map_item_t* tmp;
    HASH_ITER(hh, map->items, item, tmp) {
        colyseus_map_schema_set_by_index(clone, item->field_index, item->key, item->value);
    }

    return clone;
}