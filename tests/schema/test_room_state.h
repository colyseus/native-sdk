// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 4.0.12
// 
#ifndef __SCHEMA_CODEGEN_TEST_ROOM_STATE_H__
#define __SCHEMA_CODEGEN_TEST_ROOM_STATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    char* name;
    float value;
} item_t;

static const colyseus_field_t item_fields[] = {
    {0, "name", COLYSEUS_FIELD_STRING, "string", offsetof(item_t, name), NULL, NULL},
    {1, "value", COLYSEUS_FIELD_NUMBER, "number", offsetof(item_t, value), NULL, NULL}
};

static item_t* item_create(void) {
    item_t* instance = calloc(1, sizeof(item_t));
    return instance;
}

static void item_destroy(colyseus_schema_t* schema) {
    item_t* instance = (item_t*)schema;
    if (instance->name) free(instance->name);
    free(instance);
}

static const colyseus_schema_vtable_t item_vtable = {
    "Item",
    sizeof(item_t),
    (colyseus_schema_t* (*)(void))item_create,
    item_destroy,
    item_fields,
    2
};

typedef struct {
    colyseus_schema_t __base;
    float x;
    float y;
    bool isBot;
    bool disconnected;
    colyseus_array_schema_t* items;
} player_t;

static const colyseus_field_t player_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, x), NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, y), NULL, NULL},
    {2, "isBot", COLYSEUS_FIELD_BOOLEAN, "boolean", offsetof(player_t, isBot), NULL, NULL},
    {3, "disconnected", COLYSEUS_FIELD_BOOLEAN, "boolean", offsetof(player_t, disconnected), NULL, NULL},
    {4, "items", COLYSEUS_FIELD_ARRAY, "array", offsetof(player_t, items), &item_vtable, NULL}
};

static player_t* player_create(void) {
    player_t* instance = calloc(1, sizeof(player_t));
    return instance;
}

static void player_destroy(colyseus_schema_t* schema) {
    player_t* instance = (player_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t player_vtable = {
    "Player",
    sizeof(player_t),
    (colyseus_schema_t* (*)(void))player_create,
    player_destroy,
    player_fields,
    5
};

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
    player_t* host;
    char* currentTurn;
} test_room_state_t;

static const colyseus_field_t test_room_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(test_room_state_t, players), &player_vtable, NULL},
    {1, "host", COLYSEUS_FIELD_REF, "ref", offsetof(test_room_state_t, host), &player_vtable, NULL},
    {2, "currentTurn", COLYSEUS_FIELD_STRING, "string", offsetof(test_room_state_t, currentTurn), NULL, NULL}
};

static test_room_state_t* test_room_state_create(void) {
    test_room_state_t* instance = calloc(1, sizeof(test_room_state_t));
    return instance;
}

static void test_room_state_destroy(colyseus_schema_t* schema) {
    test_room_state_t* instance = (test_room_state_t*)schema;
    if (instance->host) player_destroy((colyseus_schema_t*)instance->host);
    if (instance->currentTurn) free(instance->currentTurn);
    free(instance);
}

static const colyseus_schema_vtable_t test_room_state_vtable = {
    "TestRoomState",
    sizeof(test_room_state_t),
    (colyseus_schema_t* (*)(void))test_room_state_create,
    test_room_state_destroy,
    test_room_state_fields,
    3
};

#endif
