// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_MOVEINPUT_H__
#define __SCHEMA_CODEGEN_MOVEINPUT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double vx;
    double vy;
    bool jump;
    uint8_t action;
} move_input_t;

static const colyseus_field_t move_input_fields[] = {
    {0, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(move_input_t, vx), NULL, NULL, NULL},
    {1, "vy", COLYSEUS_FIELD_NUMBER, "number", offsetof(move_input_t, vy), NULL, NULL, NULL},
    {2, "jump", COLYSEUS_FIELD_BOOLEAN, "boolean", offsetof(move_input_t, jump), NULL, NULL, NULL},
    {3, "action", COLYSEUS_FIELD_UINT8, "uint8", offsetof(move_input_t, action), NULL, NULL, NULL}
};

static move_input_t* move_input_create(void) {
    move_input_t* instance = calloc(1, sizeof(move_input_t));
    return instance;
}

static void move_input_destroy(colyseus_schema_t* schema) {
    move_input_t* instance = (move_input_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t move_input_vtable = {
    "MoveInput",
    sizeof(move_input_t),
    (colyseus_schema_t* (*)(void))move_input_create,
    move_input_destroy,
    move_input_fields,
    4
};

#endif
