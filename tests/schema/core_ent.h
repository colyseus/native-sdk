//
// Hand-written in schema-codegen's C output shape for CoreEnt
// (tests/schema/generate-schema-core-fixtures.ts).
//
#ifndef __SCHEMA_CODEGEN_COREENT_H__
#define __SCHEMA_CODEGEN_COREENT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double z;
    char* label;
} core_ent_t;

static const colyseus_field_t core_ent_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(core_ent_t, x), NULL, NULL},
    {1, "z", COLYSEUS_FIELD_NUMBER, "number", offsetof(core_ent_t, z), NULL, NULL},
    {2, "label", COLYSEUS_FIELD_STRING, "string", offsetof(core_ent_t, label), NULL, NULL}
};

static core_ent_t* core_ent_create(void) {
    core_ent_t* instance = calloc(1, sizeof(core_ent_t));
    return instance;
}

static void core_ent_destroy(colyseus_schema_t* schema) {
    core_ent_t* instance = (core_ent_t*)schema;
    if (instance->label) free(instance->label);
    free(instance);
}

static const colyseus_schema_vtable_t core_ent_vtable = {
    "CoreEnt",
    sizeof(core_ent_t),
    (colyseus_schema_t* (*)(void))core_ent_create,
    core_ent_destroy,
    core_ent_fields,
    3
};

#endif
