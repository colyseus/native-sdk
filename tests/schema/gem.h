// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_GEM_H__
#define __SCHEMA_CODEGEN_GEM_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double price;
} gem_t;

static const colyseus_field_t gem_fields[] = {
    {0, "price", COLYSEUS_FIELD_NUMBER, "number", offsetof(gem_t, price), NULL, NULL}
};

static gem_t* gem_create(void) {
    gem_t* instance = calloc(1, sizeof(gem_t));
    return instance;
}

static void gem_destroy(colyseus_schema_t* schema) {
    gem_t* instance = (gem_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t gem_vtable = {
    "Gem",
    sizeof(gem_t),
    (colyseus_schema_t* (*)(void))gem_create,
    gem_destroy,
    gem_fields,
    1
};

#endif
