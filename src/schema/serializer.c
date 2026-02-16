#include "colyseus/schema.h"
#include "colyseus/schema/dynamic_schema.h"
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
    double referenced_type;
} reflection_field_t;

/* ReflectionType schema */
typedef struct {
    colyseus_schema_t __base;
    double id;
    double extends_id;
    colyseus_array_schema_t* fields;
} reflection_type_t;

/* Reflection schema (root) */
typedef struct {
    colyseus_schema_t __base;
    colyseus_array_schema_t* types;
    double root_type;
} reflection_t;

/* Forward declarations for vtables */
static const colyseus_schema_vtable_t reflection_field_vtable;
static const colyseus_schema_vtable_t reflection_type_vtable;
static const colyseus_schema_vtable_t reflection_vtable;

/* ReflectionField */
static colyseus_schema_t* reflection_field_create(void) {
    reflection_field_t* f = calloc(1, sizeof(reflection_field_t));
    if (f) {
        f->referenced_type = -1;  /* -1 = no reference */
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
    {2, "referencedType", COLYSEUS_FIELD_NUMBER, "number", offsetof(reflection_field_t, referenced_type), NULL, NULL},
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
        t->id = -1;
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
    {1, "extendsId", COLYSEUS_FIELD_NUMBER, "number", offsetof(reflection_type_t, extends_id), NULL, NULL},
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
        r->root_type = -1;  /* -1 = not set */
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
    {1, "rootType", COLYSEUS_FIELD_NUMBER, "number", offsetof(reflection_t, root_type), NULL, NULL},
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
    (void)reflection;  /* Not used for now - no inheritance support */

    if (!vtable || !ref_type || !ref_type->fields) return false;

    /* Count typed fields in vtable */
    int vtable_field_count = vtable->field_count;

    /* Count fields in reflection */
    int ref_field_count = ref_type->fields->count;

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

const colyseus_schema_vtable_t* colyseus_schema_serializer_get_vtable(colyseus_schema_serializer_t* serializer) {
    if (!serializer || !serializer->decoder) return NULL;
    return serializer->decoder->state_vtable;
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

/* ============================================================================
 * Reflection-based Dynamic Vtable Builder
 * ============================================================================ */

/* Note: reflection_field_t, reflection_type_t, and reflection_t are defined
 * earlier in this file as part of the reflection schema definitions. */

/*
 * Build a dynamic vtable from a reflection_type_t.
 * This is used for auto-detecting the schema from server reflection data.
 */
static colyseus_dynamic_vtable_t* build_vtable_from_reflection_type(
    reflection_type_t* ref_type,
    reflection_t* reflection,
    colyseus_dynamic_vtable_t** vtable_cache,
    int* vtable_cache_count) {
    
    if (!ref_type) return NULL;
    
    /* Check cache first by type_id */
    int type_id = (int)ref_type->id;
    for (int i = 0; i < *vtable_cache_count; i++) {
        if (vtable_cache[i] && vtable_cache[i]->type_id == type_id) {
            return vtable_cache[i];  /* Return cached vtable */
        }
    }
    
    /* Create new dynamic vtable */
    char name[64];
    snprintf(name, sizeof(name), "DynamicType_%d", type_id);
    
    colyseus_dynamic_vtable_t* vtable = colyseus_dynamic_vtable_create(name);
    if (!vtable) return NULL;
    
    vtable->is_reflection_generated = true;
    vtable->type_id = type_id;
    
    /* Add to cache immediately to handle recursive type references */
    if (*vtable_cache_count < 64) {
        vtable_cache[*vtable_cache_count] = vtable;
        (*vtable_cache_count)++;
    }
    
    /* Process fields */
    if (ref_type->fields) {
        colyseus_array_item_t* field_item = ref_type->fields->items;
        
        printf("[Reflection] Processing type %d with %d fields\n", type_id, ref_type->fields->count);
        fflush(stdout);
        
        while (field_item) {
            reflection_field_t* ref_field = (reflection_field_t*)field_item->value;
            printf("[Reflection]   field_item index=%d, name=%s, type=%s\n", 
                field_item->index, 
                ref_field && ref_field->name ? ref_field->name : "(null)", 
                ref_field && ref_field->type ? ref_field->type : "(null)");
            fflush(stdout);
            if (ref_field && ref_field->name && ref_field->type) {
                colyseus_field_type_t field_type = colyseus_field_type_from_string(ref_field->type);
                
                /* Use the array item's index - this is the field index in the schema */
                int field_index = field_item->index;
                
                colyseus_dynamic_field_t* dyn_field = colyseus_dynamic_field_create(
                    field_index, ref_field->name, field_type, ref_field->type);
                
                if (dyn_field) {
                    /* Handle referenced types (for ref, map, array of schema) */
                    if (ref_field->referenced_type >= 0) {
                        /* Find the referenced type in reflection */
                        colyseus_array_item_t* type_item = reflection->types->items;
                        while (type_item) {
                            reflection_type_t* child_ref_type = (reflection_type_t*)type_item->value;
                            if (child_ref_type && (int)child_ref_type->id == (int)ref_field->referenced_type) {
                                /* Recursively build child vtable */
                                colyseus_dynamic_vtable_t* child_vtable = build_vtable_from_reflection_type(
                                    child_ref_type, reflection, vtable_cache, vtable_cache_count);
                                if (child_vtable) {
                                    dyn_field->child_vtable = child_vtable;
                                }
                                break;
                            }
                            type_item = type_item->next;
                        }
                    } else if (field_type == COLYSEUS_FIELD_ARRAY || field_type == COLYSEUS_FIELD_MAP) {
                        /* Primitive child type - extract from type string if possible */
                        /* For now, assume string primitives for maps without referenced types */
                        if (strcmp(ref_field->type, "map") == 0 || strcmp(ref_field->type, "array") == 0) {
                            dyn_field->child_primitive_type = strdup("string");
                        }
                    }
                    
                    colyseus_dynamic_vtable_add_field(vtable, dyn_field);
                    printf("[Reflection]   Added field '%s' at index %d, type=%s\n", 
                        ref_field->name, field_index, ref_field->type);
                    fflush(stdout);
                }
            }
            field_item = field_item->next;
        }
    }
    
    return vtable;
}

/*
 * Build all dynamic vtables from reflection data.
 * Returns the root state vtable.
 * 
 * out_vtable_cache: optional output array for all built vtables (must be at least 64 elements)
 * out_vtable_count: optional output count of vtables
 */
static colyseus_dynamic_vtable_t* build_vtables_from_reflection(
    reflection_t* reflection,
    colyseus_dynamic_vtable_t** out_vtable_cache,
    int* out_vtable_count) {
    
    if (!reflection || !reflection->types) return NULL;
    
    /* Cache to avoid rebuilding same types */
    static colyseus_dynamic_vtable_t* vtable_cache[64] = {0};
    static int vtable_cache_count = 0;
    
    /* Reset cache for fresh build */
    vtable_cache_count = 0;
    memset(vtable_cache, 0, sizeof(vtable_cache));
    
    /* Find the root type 
     * If rootType is not set (-1) or 0, use type id 0 as the root.
     * Colyseus only sets rootType if it's > 0.
     */
    int root_type_id = (int)reflection->root_type;
    if (root_type_id < 0) {
        root_type_id = 0;  /* Default to type 0 */
    }
    
    
    reflection_type_t* root_ref_type = NULL;
    
    colyseus_array_item_t* item = reflection->types->items;
    while (item) {
        reflection_type_t* ref_type = (reflection_type_t*)item->value;
        if (ref_type && (int)ref_type->id == root_type_id) {
            root_ref_type = ref_type;
            break;
        }
        item = item->next;
    }
    
    if (!root_ref_type) {
        return NULL;
    }
    
    /* Build the root vtable (which recursively builds child vtables) */
    colyseus_dynamic_vtable_t* root = build_vtable_from_reflection_type(
        root_ref_type, reflection, vtable_cache, &vtable_cache_count);
    
    /* Copy cache to output if requested */
    if (out_vtable_cache && out_vtable_count) {
        memcpy(out_vtable_cache, vtable_cache, sizeof(vtable_cache));
        *out_vtable_count = vtable_cache_count;
    }
    
    return root;
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
     * If no state_vtable is set, auto-detect by building dynamic vtables
     * from the reflection data.
     */

    /* Build list of local vtables from state_vtable and its children */
    const colyseus_schema_vtable_t* state_vtable = serializer->decoder->state_vtable;
    
    /* Auto-detect mode: if no vtable is set, build from reflection */
    if (!state_vtable) {
        /* Build all vtables from reflection */
        colyseus_dynamic_vtable_t* vtable_cache[64] = {0};
        int vtable_count = 0;
        colyseus_dynamic_vtable_t* auto_vtable = build_vtables_from_reflection(
            reflection, vtable_cache, &vtable_count);
        
        if (auto_vtable) {
            /* Create the initial state with the auto-detected vtable */
            serializer->decoder->state_vtable = (const colyseus_schema_vtable_t*)auto_vtable;
            serializer->decoder->state = (colyseus_schema_t*)colyseus_dynamic_schema_create(auto_vtable);
            
            if (serializer->decoder->state) {
                serializer->decoder->state->__refId = 0;
                serializer->decoder->state->__vtable = (const colyseus_schema_vtable_t*)auto_vtable;
                colyseus_ref_tracker_add(serializer->decoder->refs, 0, serializer->decoder->state,
                    COLYSEUS_REF_TYPE_SCHEMA, (const colyseus_schema_vtable_t*)auto_vtable, true);
            }
            
            /* Register all vtables in the type context with their correct type IDs */
            for (int i = 0; i < vtable_count; i++) {
                if (vtable_cache[i]) {
                    colyseus_type_context_set(serializer->decoder->context, 
                        vtable_cache[i]->type_id, 
                        (const colyseus_schema_vtable_t*)vtable_cache[i]);
                }
            }
            
            /* Decode initial state if there's remaining data after reflection */
            if (it.offset < (int)length) {
                colyseus_decoder_decode(serializer->decoder, bytes, length, &it);
            }
        }
        
        colyseus_decoder_free(ref_decoder);
        return;
    }

    /* 
     * Recursively match vtables with reflection types.
     * We need to traverse the entire vtable tree (state -> children -> grandchildren)
     * to register all schema types with the decoder's type context.
     */
    #define MAX_VTABLES 64
    const colyseus_schema_vtable_t* vtable_queue[MAX_VTABLES];
    int queue_head = 0;
    int queue_tail = 0;

    /* Add state vtable to queue */
    vtable_queue[queue_tail++] = state_vtable;

    /* Process vtables in BFS order */
    while (queue_head < queue_tail) {
        const colyseus_schema_vtable_t* vt = vtable_queue[queue_head++];
        if (!vt) continue;

        /* Try to match this vtable with reflection types */
        colyseus_array_item_t* item = reflection->types->items;
        while (item) {
            reflection_type_t* ref_type = (reflection_type_t*)item->value;
            if (ref_type && compare_vtable_with_reflection(vt, ref_type, reflection)) {
                colyseus_type_context_set(serializer->decoder->context, (int)ref_type->id, vt);
            }
            item = item->next;
        }

        /* Add child vtables to queue (if not already processed) */
        for (int i = 0; i < vt->field_count; i++) {
            const colyseus_field_t* field = &vt->fields[i];
            if (field->child_vtable && queue_tail < MAX_VTABLES) {
                /* Check if already in queue */
                bool found = false;
                for (int j = 0; j < queue_tail; j++) {
                    if (vtable_queue[j] == field->child_vtable) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    vtable_queue[queue_tail++] = field->child_vtable;
                }
            }
        }
    }

    #undef MAX_VTABLES

    /* Decode initial state if there's remaining data after reflection */
    if (it.offset < (int)length) {
        colyseus_decoder_decode(serializer->decoder, bytes, length, &it);
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