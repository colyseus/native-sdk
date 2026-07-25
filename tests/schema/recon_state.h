// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RECONSTATE_H__
#define __SCHEMA_CODEGEN_RECONSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double vx;
} recon_state_t;

static const colyseus_field_t recon_state_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(recon_state_t, x), NULL, NULL, NULL},
    {1, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(recon_state_t, vx), NULL, NULL, NULL}
};

static recon_state_t* recon_state_create(void) {
    recon_state_t* instance = calloc(1, sizeof(recon_state_t));
    return instance;
}

static void recon_state_destroy(colyseus_schema_t* schema) {
    recon_state_t* instance = (recon_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t recon_state_vtable = {
    "ReconState",
    sizeof(recon_state_t),
    (colyseus_schema_t* (*)(void))recon_state_create,
    recon_state_destroy,
    recon_state_fields,
    2
};

#endif
