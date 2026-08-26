// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_UNIT_H__
#define __SCHEMA_CODEGEN_UNIT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "gem.h"

typedef struct {
    colyseus_schema_t __base;
    char* name;
    double hp;
    colyseus_array_schema_t* gems;
} unit_t;

static const colyseus_field_t unit_fields[] = {
    {0, "name", COLYSEUS_FIELD_STRING, "string", offsetof(unit_t, name), NULL, NULL},
    {1, "hp", COLYSEUS_FIELD_NUMBER, "number", offsetof(unit_t, hp), NULL, NULL},
    {2, "gems", COLYSEUS_FIELD_ARRAY, "array", offsetof(unit_t, gems), &gem_vtable, NULL}
};

static unit_t* unit_create(void) {
    unit_t* instance = calloc(1, sizeof(unit_t));
    return instance;
}

static void unit_destroy(colyseus_schema_t* schema) {
    unit_t* instance = (unit_t*)schema;
    if (instance->name) free(instance->name);
    free(instance);
}

static const colyseus_schema_vtable_t unit_vtable = {
    "Unit",
    sizeof(unit_t),
    (colyseus_schema_t* (*)(void))unit_create,
    unit_destroy,
    unit_fields,
    3
};

#endif
