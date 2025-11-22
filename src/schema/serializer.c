#include "colyseus/schema.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "uthash.h"
#include "colyseus/schema/collections.h"
#include "colyseus/schema/decoder.h"
#include "colyseus/schema/types.h"

/* ============================================================================
 * Reflection Schema Definitions
 * These are used to decode the handshake from server
 * ============================================================================ */

/* ReflectionField schema */
typedef struct {
    colyseus_schema_t __base;
    char* name;
    char* type;
    float referenced_type;
} reflection_field_t;

/* ReflectionType schema */
typedef struct {
    colyseus_schema_t __base;
    float id;
    float extends_id;
    colyseus_array_schema_t* fields;
} reflection_type_t;

/* Reflection schema (root) */
typedef struct {
    colyseus_schema_t __base;
    colyseus_array_schema_t* types;
    float root_type;
} reflection_t;

/* Forward declarations for vtables */
static const colyseus_schema_vtable_t reflection_field_vtable;
static const colyseus_schema_vtable_t reflection_type_vtable;
static const colyseus_schema_vtable_t reflection_vtable;

/* ReflectionField */
static colyseus_schema_t* reflection_field_create(void) {
    reflection_field_t* f = calloc(1, sizeof(reflection_field_t));
    if (f) {
        f->referenced_type = -1;
        f->__base.__vtable = &reflection_field_vtable;
    }
    return (colyseus_schema_t*)f;
}

static void reflection_field_destroy(colyseus_schema_t* s) {
    reflection_field_t* f = (reflection_field_t*)s;
    if (f) {
        free(f->name);
        free(f->type);
        free(f);
    }
}

static const colyseus_field_t reflection_field_fields[] = {
    {0, "name", COLYSEUS_FIELD_STRING, "string", offsetof(reflection_field_t, name), NULL, NULL},
    {1, "type", COLYSEUS_FIELD_STRING, "string", offsetof(reflection_field_t, type), NULL, NULL},
    {2, "referenced_type", COLYSEUS_FIELD_NUMBER, "number", offsetof(reflection_field_t, referenced_type), NULL, NULL},
};

static const colyseus_schema_vtable_t reflection_field_vtable = {
    "ReflectionField",
    sizeof(reflection_field_t),
    reflection_field_create,
    reflection_field_destroy,
    reflection_field_fields,
    3
};

/* ReflectionType */
static colyseus_schema_t* reflection_type_create(void) {
    reflection_type_t* t = calloc(1, sizeof(reflection_type_t));
    if (t) {
        t->extends_id = -1;
        t->__base.__vtable = &reflection_type_vtable;
    }
    return (colyseus_schema_t*)t;
}

static void reflection_type_destroy(colyseus_schema_t* s) {
    reflection_type_t* t = (reflection_type_t*)s;
    if (t) {
        if (t->fields) {
            colyseus_array_schema_free(t->fields, NULL);
        }
        free(t);
    }
}

static const colyseus_field_t reflection_type_fields[] = {
    {0, "id", COLYSEUS_FIELD_NUMBER, "number", offsetof(reflection_type_t, id), NULL, NULL},
    {1, "extends_id", COLYSEUS_FIELD_NUMBER, "number", offsetof(reflection_type_t, extends_id), NULL, NULL},
    {2, "fields", COLYSEUS_FIELD_ARRAY, "array", offsetof(reflection_type_t, fields), &reflection_field_vtable, NULL},
};

static const colyseus_schema_vtable_t reflection_type_vtable = {
    "ReflectionType",
    sizeof(reflection_type_t),
    reflection_type_create,
    reflection_type_destroy,
    reflection_type_fields,
    3
};

/* Reflection (root) */
static colyseus_schema_t* reflection_create(void) {
    reflection_t* r = calloc(1, sizeof(reflection_t));
    if (r) {
        r->root_type = -1;
        r->__base.__vtable = &reflection_vtable;
    }
    return (colyseus_schema_t*)r;
}

static void reflection_destroy(colyseus_schema_t* s) {
    reflection_t* r = (reflection_t*)s;
    if (r) {
        if (r->types) {
            colyseus_array_schema_free(r->types, NULL);
        }
        free(r);
    }
}

static const colyseus_field_t reflection_fields[] = {
    {0, "types", COLYSEUS_FIELD_ARRAY, "array", offsetof(reflection_t, types), &reflection_type_vtable, NULL},
    {1, "root_type", COLYSEUS_FIELD_NUMBER, "number", offsetof(reflection_t, root_type), NULL, NULL},
};

static const colyseus_schema_vtable_t reflection_vtable = {
    "Reflection",
    sizeof(reflection_t),
    reflection_create,
    reflection_destroy,
    reflection_fields,
    2
};

/* ============================================================================
 * Type Matching Helpers
 * ============================================================================ */

/* Compare local vtable with reflection type to see if they match */
static bool compare_vtable_with_reflection(
    const colyseus_schema_vtable_t* vtable,
    reflection_type_t* ref_type,
    reflection_t* reflection) {

    if (!vtable || !ref_type || !ref_type->fields) return false;

    /* Count typed fields in vtable */
    int vtable_field_count = vtable->field_count;

    /* Count fields in reflection (including inherited) */
    int ref_field_count = ref_type->fields->count;

    /* Walk inheritance chain to get all fields */
    float extends_id = ref_type->extends_id;
    while (extends_id >= 0 && reflection && reflection->types) {
        /* Find parent type */
        colyseus_array_item_t* item = reflection->types->items;
        while (item) {
            reflection_type_t* parent = (reflection_type_t*)item->value;
            if (parent && (int)parent->id == (int)extends_id) {
                if (parent->fields) {
                    ref_field_count += parent->fields->count;
                }
                extends_id = parent->extends_id;
                break;
            }
            item = item->next;
        }
        if (!item) break;  /* Parent not found */
    }

    if (vtable_field_count != ref_field_count) {
        return false;
    }

    /* Compare each field by index, name, and type */
    for (int i = 0; i < vtable->field_count; i++) {
        const colyseus_field_t* local_field = &vtable->fields[i];

        /* Find matching field in reflection */
        bool found = false;
        colyseus_array_item_t* item = ref_type->fields->items;
        while (item) {
            reflection_field_t* ref_field = (reflection_field_t*)item->value;
            if (ref_field &&
                local_field->index == item->index &&
                strcmp(local_field->name, ref_field->name) == 0) {

                /* Check type prefix matches */
                if (strncmp(ref_field->type, local_field->type_str, strlen(local_field->type_str)) == 0) {
                    found = true;
                    break;
                }
            }
            item = item->next;
        }

        if (!found) {
            return false;
        }
    }

    return true;
}

/* ============================================================================
 * Schema Serializer Implementation
 * ============================================================================ */

colyseus_schema_serializer_t* colyseus_schema_serializer_create(const colyseus_schema_vtable_t* state_vtable) {
    colyseus_schema_serializer_t* serializer = malloc(sizeof(colyseus_schema_serializer_t));
    if (!serializer) return NULL;

    serializer->decoder = colyseus_decoder_create(state_vtable);
    serializer->it.offset = 0;

    return serializer;
}

void colyseus_schema_serializer_free(colyseus_schema_serializer_t* serializer) {
    if (!serializer) return;

    colyseus_decoder_free(serializer->decoder);
    free(serializer);
}

void colyseus_schema_serializer_set_state(colyseus_schema_serializer_t* serializer,
    const uint8_t* data, size_t length, int offset) {
    if (!serializer) return;

    serializer->it.offset = offset;
    colyseus_decoder_decode(serializer->decoder, data, length, &serializer->it);
}

void* colyseus_schema_serializer_get_state(colyseus_schema_serializer_t* serializer) {
    if (!serializer) return NULL;
    return colyseus_decoder_get_state(serializer->decoder);
}

void colyseus_schema_serializer_patch(colyseus_schema_serializer_t* serializer,
    const uint8_t* data, size_t length, int offset) {
    if (!serializer) return;

    serializer->it.offset = offset;
    colyseus_decoder_decode(serializer->decoder, data, length, &serializer->it);
}

void colyseus_schema_serializer_teardown(colyseus_schema_serializer_t* serializer) {
    if (!serializer) return;
    colyseus_decoder_teardown(serializer->decoder);
}

void colyseus_schema_serializer_handshake(colyseus_schema_serializer_t* serializer,
    const uint8_t* bytes, size_t length, int offset) {
    if (!serializer || !bytes || length == 0) return;

    /*
     * Handshake decodes the reflection data from server and matches
     * it with local schema types.
     *
     * The handshake bytes contain:
     * - Array of ReflectionType (id, extendsId, fields[])
     * - rootType id
     *
     * We decode this using our Reflection schema decoder,
     * then match server types with local vtables by comparing
     * field names and types.
     */

    /* Create decoder for reflection */
    colyseus_decoder_t* ref_decoder = colyseus_decoder_create(&reflection_vtable);
    if (!ref_decoder) return;

    /* Decode reflection data */
    colyseus_iterator_t it = { .offset = offset };
    colyseus_decoder_decode(ref_decoder, bytes, length, &it);

    reflection_t* reflection = (reflection_t*)colyseus_decoder_get_state(ref_decoder);
    if (!reflection || !reflection->types) {
        colyseus_decoder_free(ref_decoder);
        return;
    }

    /*
     * Match server types with local vtables.
     *
     * In C, we need to know what local vtables are available.
     * This is typically done by:
     * 1. User registers all schema vtables before handshake
     * 2. Or we use a static registry
     *
     * For now, we'll match the root state vtable and any child vtables
     * it references through its fields.
     */

    /* Build list of local vtables from state_vtable and its children */
    const colyseus_schema_vtable_t* state_vtable = serializer->decoder->state_vtable;

    /* Simple approach: iterate reflection types and try to match with state_vtable */
    colyseus_array_item_t* item = reflection->types->items;
    while (item) {
        reflection_type_t* ref_type = (reflection_type_t*)item->value;
        if (!ref_type) {
            item = item->next;
            continue;
        }

        /* Try to match with state vtable */
        if (compare_vtable_with_reflection(state_vtable, ref_type, reflection)) {
            colyseus_type_context_set(serializer->decoder->context, (int)ref_type->id, state_vtable);
        }

        /* Try to match with child vtables */
        for (int i = 0; i < state_vtable->field_count; i++) {
            const colyseus_field_t* field = &state_vtable->fields[i];
            if (field->child_vtable) {
                if (compare_vtable_with_reflection(field->child_vtable, ref_type, reflection)) {
                    colyseus_type_context_set(serializer->decoder->context,
                        (int)ref_type->id, field->child_vtable);
                }
            }
        }

        item = item->next;
    }

    /* Cleanup */
    colyseus_decoder_free(ref_decoder);
}

/* ============================================================================
 * Vtable Registry (for more complex schema hierarchies)
 * ============================================================================ */

typedef struct vtable_entry {
    const char* name;
    const colyseus_schema_vtable_t* vtable;
    UT_hash_handle hh;
} vtable_entry_t;

static vtable_entry_t* g_vtable_registry = NULL;

void colyseus_schema_register_vtable(const colyseus_schema_vtable_t* vtable) {
    if (!vtable || !vtable->name) return;

    vtable_entry_t* entry = NULL;
    HASH_FIND_STR(g_vtable_registry, vtable->name, entry);

    if (!entry) {
        entry = malloc(sizeof(vtable_entry_t));
        if (entry) {
            entry->name = vtable->name;
            entry->vtable = vtable;
            HASH_ADD_KEYPTR(hh, g_vtable_registry, entry->name, strlen(entry->name), entry);
        }
    }
}

const colyseus_schema_vtable_t* colyseus_schema_get_vtable(const char* name) {
    if (!name) return NULL;

    vtable_entry_t* entry = NULL;
    HASH_FIND_STR(g_vtable_registry, name, entry);

    return entry ? entry->vtable : NULL;
}

void colyseus_schema_clear_registry(void) {
    vtable_entry_t* entry;
    vtable_entry_t* tmp;
    HASH_ITER(hh, g_vtable_registry, entry, tmp) {
        HASH_DEL(g_vtable_registry, entry);
        free(entry);
    }
    g_vtable_registry = NULL;
}