// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RESYNCSTATEV1_H__
#define __SCHEMA_CODEGEN_RESYNCSTATEV1_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "resync_player_v1.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
} resync_state_v1_t;

static const colyseus_field_t resync_state_v1_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(resync_state_v1_t, players), &resync_player_v1_vtable, NULL}
};

static resync_state_v1_t* resync_state_v1_create(void) {
    resync_state_v1_t* instance = calloc(1, sizeof(resync_state_v1_t));
    return instance;
}

static void resync_state_v1_destroy(colyseus_schema_t* schema) {
    resync_state_v1_t* instance = (resync_state_v1_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t resync_state_v1_vtable = {
    "ResyncStateV1",
    sizeof(resync_state_v1_t),
    (colyseus_schema_t* (*)(void))resync_state_v1_create,
    resync_state_v1_destroy,
    resync_state_v1_fields,
    1
};

#endif
