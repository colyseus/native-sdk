// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_PASSIVEENT_H__
#define __SCHEMA_CODEGEN_PASSIVEENT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double a;
    double b;
    double c;
    double d;
    double yaw;
} passive_ent_t;

static const colyseus_field_t passive_ent_fields[] = {
    {0, "a", COLYSEUS_FIELD_NUMBER, "number", offsetof(passive_ent_t, a), NULL, NULL, NULL},
    {1, "b", COLYSEUS_FIELD_NUMBER, "number", offsetof(passive_ent_t, b), NULL, NULL, NULL},
    {2, "c", COLYSEUS_FIELD_NUMBER, "number", offsetof(passive_ent_t, c), NULL, NULL, NULL},
    {3, "d", COLYSEUS_FIELD_NUMBER, "number", offsetof(passive_ent_t, d), NULL, NULL, NULL},
    {4, "yaw", COLYSEUS_FIELD_NUMBER, "number", offsetof(passive_ent_t, yaw), NULL, NULL, NULL}
};

static passive_ent_t* passive_ent_create(void) {
    passive_ent_t* instance = calloc(1, sizeof(passive_ent_t));
    return instance;
}

static void passive_ent_destroy(colyseus_schema_t* schema) {
    passive_ent_t* instance = (passive_ent_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t passive_ent_vtable = {
    "PassiveEnt",
    sizeof(passive_ent_t),
    (colyseus_schema_t* (*)(void))passive_ent_create,
    passive_ent_destroy,
    passive_ent_fields,
    5
};

#endif
