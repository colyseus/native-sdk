//
// Hand-written test schema (schema-codegen shape) for the SimReconciler
// fixture — mirrors `Puck` in colyseus-0.18
// PORTING/generate-predict-fixtures.cts scenario C.
//
#ifndef __SCHEMA_TEST_SIM_PUCK_H__
#define __SCHEMA_TEST_SIM_PUCK_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double px;
} sim_puck_t;

static const colyseus_field_t sim_puck_fields[] = {
    {0, "px", COLYSEUS_FIELD_NUMBER, "number", offsetof(sim_puck_t, px), NULL, NULL, NULL}
};

static sim_puck_t* sim_puck_create(void) {
    return calloc(1, sizeof(sim_puck_t));
}

static void sim_puck_destroy(colyseus_schema_t* schema) {
    free((sim_puck_t*)schema);
}

static const colyseus_schema_vtable_t sim_puck_vtable = {
    "Puck",
    sizeof(sim_puck_t),
    (colyseus_schema_t* (*)(void))sim_puck_create,
    sim_puck_destroy,
    sim_puck_fields,
    1
};

#endif
