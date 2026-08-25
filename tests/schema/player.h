// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_PLAYER_H__
#define __SCHEMA_CODEGEN_PLAYER_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    char* name;
    double x;
    double y;
} player_t;

static const colyseus_field_t player_fields[] = {
    {0, "name", COLYSEUS_FIELD_STRING, "string", offsetof(player_t, name), NULL, NULL},
    {1, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, x), NULL, NULL},
    {2, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, y), NULL, NULL}
};

static player_t* player_create(void) {
    player_t* instance = calloc(1, sizeof(player_t));
    return instance;
}

static void player_destroy(colyseus_schema_t* schema) {
    player_t* instance = (player_t*)schema;
    if (instance->name) free(instance->name);
    free(instance);
}

static const colyseus_schema_vtable_t player_vtable = {
    "Player",
    sizeof(player_t),
    (colyseus_schema_t* (*)(void))player_create,
    player_destroy,
    player_fields,
    3
};

#endif
