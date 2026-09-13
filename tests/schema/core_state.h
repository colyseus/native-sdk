//
// Hand-written in schema-codegen's C output shape for CoreState
// (tests/schema/generate-schema-core-fixtures.ts).
//
#ifndef __SCHEMA_CODEGEN_CORESTATE_H__
#define __SCHEMA_CODEGEN_CORESTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "core_ent.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* ents;
    char* title;
    double tick;
} core_state_t;

static const colyseus_field_t core_state_fields[] = {
    {0, "ents", COLYSEUS_FIELD_MAP, "map", offsetof(core_state_t, ents), &core_ent_vtable, NULL},
    {1, "title", COLYSEUS_FIELD_STRING, "string", offsetof(core_state_t, title), NULL, NULL},
    {2, "tick", COLYSEUS_FIELD_NUMBER, "number", offsetof(core_state_t, tick), NULL, NULL}
};

static core_state_t* core_state_create(void) {
    core_state_t* instance = calloc(1, sizeof(core_state_t));
    return instance;
}

static void core_state_destroy(colyseus_schema_t* schema) {
    core_state_t* instance = (core_state_t*)schema;
    if (instance->title) free(instance->title);
    free(instance);
}

static const colyseus_schema_vtable_t core_state_vtable = {
    "CoreState",
    sizeof(core_state_t),
    (colyseus_schema_t* (*)(void))core_state_create,
    core_state_destroy,
    core_state_fields,
    3
};

#endif
