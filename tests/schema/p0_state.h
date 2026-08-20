// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_P0STATE_H__
#define __SCHEMA_CODEGEN_P0STATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    char* msg;
    double n;
} p0_state_t;

static const colyseus_field_t p0_state_fields[] = {
    {0, "msg", COLYSEUS_FIELD_STRING, "string", offsetof(p0_state_t, msg), NULL, NULL},
    {1, "n", COLYSEUS_FIELD_NUMBER, "number", offsetof(p0_state_t, n), NULL, NULL}
};

static p0_state_t* p0_state_create(void) {
    p0_state_t* instance = calloc(1, sizeof(p0_state_t));
    return instance;
}

static void p0_state_destroy(colyseus_schema_t* schema) {
    p0_state_t* instance = (p0_state_t*)schema;
    if (instance->msg) free(instance->msg);
    free(instance);
}

static const colyseus_schema_vtable_t p0_state_vtable = {
    "P0State",
    sizeof(p0_state_t),
    (colyseus_schema_t* (*)(void))p0_state_create,
    p0_state_destroy,
    p0_state_fields,
    2
};

#endif
