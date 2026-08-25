// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_P0INPUT_H__
#define __SCHEMA_CODEGEN_P0INPUT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double y;
} p0_input_t;

static const colyseus_field_t p0_input_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(p0_input_t, x), NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(p0_input_t, y), NULL, NULL}
};

static p0_input_t* p0_input_create(void) {
    p0_input_t* instance = calloc(1, sizeof(p0_input_t));
    return instance;
}

static void p0_input_destroy(colyseus_schema_t* schema) {
    p0_input_t* instance = (p0_input_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t p0_input_vtable = {
    "P0Input",
    sizeof(p0_input_t),
    (colyseus_schema_t* (*)(void))p0_input_create,
    p0_input_destroy,
    p0_input_fields,
    2
};

#endif
