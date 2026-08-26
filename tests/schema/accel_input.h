// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_ACCELINPUT_H__
#define __SCHEMA_CODEGEN_ACCELINPUT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double ax;
} accel_input_t;

static const colyseus_field_t accel_input_fields[] = {
    {0, "ax", COLYSEUS_FIELD_NUMBER, "number", offsetof(accel_input_t, ax), NULL, NULL, NULL}
};

static accel_input_t* accel_input_create(void) {
    accel_input_t* instance = calloc(1, sizeof(accel_input_t));
    return instance;
}

static void accel_input_destroy(colyseus_schema_t* schema) {
    accel_input_t* instance = (accel_input_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t accel_input_vtable = {
    "AccelInput",
    sizeof(accel_input_t),
    (colyseus_schema_t* (*)(void))accel_input_create,
    accel_input_destroy,
    accel_input_fields,
    1
};

#endif
