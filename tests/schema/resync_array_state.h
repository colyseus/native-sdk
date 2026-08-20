// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RESYNCARRAYSTATE_H__
#define __SCHEMA_CODEGEN_RESYNCARRAYSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "unit.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_array_schema_t* arr;
} resync_array_state_t;

static const colyseus_field_t resync_array_state_fields[] = {
    {0, "arr", COLYSEUS_FIELD_ARRAY, "array", offsetof(resync_array_state_t, arr), &unit_vtable, NULL}
};

static resync_array_state_t* resync_array_state_create(void) {
    resync_array_state_t* instance = calloc(1, sizeof(resync_array_state_t));
    return instance;
}

static void resync_array_state_destroy(colyseus_schema_t* schema) {
    resync_array_state_t* instance = (resync_array_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t resync_array_state_vtable = {
    "ResyncArrayState",
    sizeof(resync_array_state_t),
    (colyseus_schema_t* (*)(void))resync_array_state_create,
    resync_array_state_destroy,
    resync_array_state_fields,
    1
};

#endif
