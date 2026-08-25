//
// Hand-written test schema (schema-codegen shape) for the SimReconciler
// fixture — mirrors `Paddle` in colyseus-0.18
// PORTING/generate-predict-fixtures.cts scenario C.
//
#ifndef __SCHEMA_TEST_SIM_PADDLE_H__
#define __SCHEMA_TEST_SIM_PADDLE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double vx;
} sim_paddle_t;

static const colyseus_field_t sim_paddle_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(sim_paddle_t, x), NULL, NULL, NULL},
    {1, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(sim_paddle_t, vx), NULL, NULL, NULL}
};

static sim_paddle_t* sim_paddle_create(void) {
    return calloc(1, sizeof(sim_paddle_t));
}

static void sim_paddle_destroy(colyseus_schema_t* schema) {
    free((sim_paddle_t*)schema);
}

static const colyseus_schema_vtable_t sim_paddle_vtable = {
    "Paddle",
    sizeof(sim_paddle_t),
    (colyseus_schema_t* (*)(void))sim_paddle_create,
    sim_paddle_destroy,
    sim_paddle_fields,
    2
};

#endif
