// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_ARRAYSCHEMAINSERTOPS_H__
#define __SCHEMA_CODEGEN_ARRAYSCHEMAINSERTOPS_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "item.h"
#include "player.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_array_schema_t* numbers;
    colyseus_array_schema_t* items;
    colyseus_array_schema_t* players;
} array_schema_insert_ops_t;

static const colyseus_field_t array_schema_insert_ops_fields[] = {
    {0, "numbers", COLYSEUS_FIELD_ARRAY, "array", offsetof(array_schema_insert_ops_t, numbers), NULL, "number"},
    {1, "items", COLYSEUS_FIELD_ARRAY, "array", offsetof(array_schema_insert_ops_t, items), &item_vtable, NULL},
    {2, "players", COLYSEUS_FIELD_ARRAY, "array", offsetof(array_schema_insert_ops_t, players), &player_vtable, NULL}
};

static array_schema_insert_ops_t* array_schema_insert_ops_create(void) {
    array_schema_insert_ops_t* instance = calloc(1, sizeof(array_schema_insert_ops_t));
    return instance;
}

static void array_schema_insert_ops_destroy(colyseus_schema_t* schema) {
    array_schema_insert_ops_t* instance = (array_schema_insert_ops_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t array_schema_insert_ops_vtable = {
    "ArraySchemaInsertOps",
    sizeof(array_schema_insert_ops_t),
    (colyseus_schema_t* (*)(void))array_schema_insert_ops_create,
    array_schema_insert_ops_destroy,
    array_schema_insert_ops_fields,
    3
};

#endif

/* regenerated: primitive child types */
