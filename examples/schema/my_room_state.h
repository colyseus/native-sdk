// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 4.0.12
// 
#ifndef __SCHEMA_CODEGEN_MYROOMSTATE_H__
#define __SCHEMA_CODEGEN_MYROOMSTATE_H__ 1

#include "colyseus/schema/types.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    char* mySynchronizedProperty;
} my_room_state_t;

static const colyseus_field_t my_room_state_fields[] = {
    {0, "mySynchronizedProperty", COLYSEUS_FIELD_STRING, "string", offsetof(my_room_state_t, mySynchronizedProperty), NULL, NULL}
};

static my_room_state_t* my_room_state_create(void) {
    my_room_state_t* instance = calloc(1, sizeof(my_room_state_t));
    return instance;
}

static void my_room_state_destroy(colyseus_schema_t* schema) {
    my_room_state_t* instance = (my_room_state_t*)schema;
    if (instance->mySynchronizedProperty) free(instance->mySynchronizedProperty);
    free(instance);
}

static const colyseus_schema_vtable_t my_room_state_vtable = {
    "MyRoomState",
    sizeof(my_room_state_t),
    (colyseus_schema_t* (*)(void))my_room_state_create,
    my_room_state_destroy,
    my_room_state_fields,
    1
};

#endif
