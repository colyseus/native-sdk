// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_QCHILD_H__
#define __SCHEMA_CODEGEN_QCHILD_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double v;
} q_child_t;

static const colyseus_field_t q_child_fields[] = {
    {0, "v", COLYSEUS_FIELD_NUMBER, "number", offsetof(q_child_t, v), NULL, NULL, NULL}
};

static q_child_t* q_child_create(void) {
    q_child_t* instance = calloc(1, sizeof(q_child_t));
    return instance;
}

static void q_child_destroy(colyseus_schema_t* schema) {
    q_child_t* instance = (q_child_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t q_child_vtable = {
    "QChild",
    sizeof(q_child_t),
    (colyseus_schema_t* (*)(void))q_child_create,
    q_child_destroy,
    q_child_fields,
    1
};

#endif
