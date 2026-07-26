// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RESYNCPLAYERV1_H__
#define __SCHEMA_CODEGEN_RESYNCPLAYERV1_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
} resync_player_v1_t;

static const colyseus_field_t resync_player_v1_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(resync_player_v1_t, x), NULL, NULL}
};

static resync_player_v1_t* resync_player_v1_create(void) {
    resync_player_v1_t* instance = calloc(1, sizeof(resync_player_v1_t));
    return instance;
}

static void resync_player_v1_destroy(colyseus_schema_t* schema) {
    resync_player_v1_t* instance = (resync_player_v1_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t resync_player_v1_vtable = {
    "ResyncPlayerV1",
    sizeof(resync_player_v1_t),
    (colyseus_schema_t* (*)(void))resync_player_v1_create,
    resync_player_v1_destroy,
    resync_player_v1_fields,
    1
};

#endif
