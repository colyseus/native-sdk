// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_QSTATE_H__
#define __SCHEMA_CODEGEN_QSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "q_child.h"

typedef struct {
    colyseus_schema_t __base;
    double yaw;
    double pitch;
    double precise;
    colyseus_array_schema_t* nums;
    colyseus_map_schema_t* tags;
    q_child_t* child;
    colyseus_array_schema_t* items;
    char* label;
} q_state_t;

static const colyseus_quantized_descriptor_t q_state_yaw_quantized = {0, 6.283185307179586, 6.283185307179586, 65536, 16, true};
static const colyseus_quantized_descriptor_t q_state_pitch_quantized = {-1.5, 1.5, 3, 255, 8, false};
static const colyseus_quantized_descriptor_t q_state_precise_quantized = {0, 1, 1, 4294967295, 32, false};

static const colyseus_field_t q_state_fields[] = {
    {0, "yaw", COLYSEUS_FIELD_QUANTIZED, "quantized", offsetof(q_state_t, yaw), NULL, NULL, &q_state_yaw_quantized},
    {1, "pitch", COLYSEUS_FIELD_QUANTIZED, "quantized", offsetof(q_state_t, pitch), NULL, NULL, &q_state_pitch_quantized},
    {2, "precise", COLYSEUS_FIELD_QUANTIZED, "quantized", offsetof(q_state_t, precise), NULL, NULL, &q_state_precise_quantized},
    {3, "nums", COLYSEUS_FIELD_ARRAY, "array", offsetof(q_state_t, nums), NULL, "number", NULL},
    {4, "tags", COLYSEUS_FIELD_MAP, "map", offsetof(q_state_t, tags), NULL, "string", NULL},
    {5, "child", COLYSEUS_FIELD_REF, "ref", offsetof(q_state_t, child), &q_child_vtable, NULL, NULL},
    {6, "items", COLYSEUS_FIELD_ARRAY, "array", offsetof(q_state_t, items), &q_child_vtable, NULL, NULL},
    {7, "label", COLYSEUS_FIELD_STRING, "string", offsetof(q_state_t, label), NULL, NULL, NULL}
};

static q_state_t* q_state_create(void) {
    q_state_t* instance = calloc(1, sizeof(q_state_t));
    return instance;
}

static void q_state_destroy(colyseus_schema_t* schema) {
    q_state_t* instance = (q_state_t*)schema;
    if (instance->child) q_child_destroy((colyseus_schema_t*)instance->child);
    if (instance->label) free(instance->label);
    free(instance);
}

static const colyseus_schema_vtable_t q_state_vtable = {
    "QState",
    sizeof(q_state_t),
    (colyseus_schema_t* (*)(void))q_state_create,
    q_state_destroy,
    q_state_fields,
    8
};

#endif
