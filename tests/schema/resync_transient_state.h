// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RESYNCTRANSIENTSTATE_H__
#define __SCHEMA_CODEGEN_RESYNCTRANSIENTSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "unit.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* units;
    colyseus_map_schema_t* locals;
} resync_transient_state_t;

static const colyseus_field_t resync_transient_state_fields[] = {
    {0, "units", COLYSEUS_FIELD_MAP, "map", offsetof(resync_transient_state_t, units), &unit_vtable, NULL},
    {1, "locals", COLYSEUS_FIELD_MAP, "map", offsetof(resync_transient_state_t, locals), NULL, "number"}
};

static resync_transient_state_t* resync_transient_state_create(void) {
    resync_transient_state_t* instance = calloc(1, sizeof(resync_transient_state_t));
    return instance;
}

static void resync_transient_state_destroy(colyseus_schema_t* schema) {
    resync_transient_state_t* instance = (resync_transient_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t resync_transient_state_vtable = {
    "ResyncTransientState",
    sizeof(resync_transient_state_t),
    (colyseus_schema_t* (*)(void))resync_transient_state_create,
    resync_transient_state_destroy,
    resync_transient_state_fields,
    2
};

#endif
