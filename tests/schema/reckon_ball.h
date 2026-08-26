// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RECKONBALL_H__
#define __SCHEMA_CODEGEN_RECKONBALL_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double vx;
} reckon_ball_t;

static const colyseus_field_t reckon_ball_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(reckon_ball_t, x), NULL, NULL, NULL},
    {1, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(reckon_ball_t, vx), NULL, NULL, NULL}
};

static reckon_ball_t* reckon_ball_create(void) {
    reckon_ball_t* instance = calloc(1, sizeof(reckon_ball_t));
    return instance;
}

static void reckon_ball_destroy(colyseus_schema_t* schema) {
    reckon_ball_t* instance = (reckon_ball_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t reckon_ball_vtable = {
    "ReckonBall",
    sizeof(reckon_ball_t),
    (colyseus_schema_t* (*)(void))reckon_ball_create,
    reckon_ball_destroy,
    reckon_ball_fields,
    2
};

#endif
