// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_ITEM_H__
#define __SCHEMA_CODEGEN_ITEM_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double value;
} item_t;

static const colyseus_field_t item_fields[] = {
    {0, "value", COLYSEUS_FIELD_NUMBER, "number", offsetof(item_t, value), NULL, NULL}
};

static item_t* item_create(void) {
    item_t* instance = calloc(1, sizeof(item_t));
    return instance;
}

static void item_destroy(colyseus_schema_t* schema) {
    item_t* instance = (item_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t item_vtable = {
    "Item",
    sizeof(item_t),
    (colyseus_schema_t* (*)(void))item_create,
    item_destroy,
    item_fields,
    1
};

#endif
