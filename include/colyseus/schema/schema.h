#ifndef COLYSEUS_SCHEMA_H
#define COLYSEUS_SCHEMA_H

/*
 * Colyseus Schema - C Implementation
 * 
 * This is the main include for Schema serialization support.
 * 
 * Usage:
 * 1. Define your schema structures using the provided macros
 * 2. Create a decoder for your state type
 * 3. Pass incoming state bytes to the decoder
 * 
 * Example:
 * 
 * // Define schema (normally code-generated)
 * typedef struct {
 *     colyseus_schema_t __base;
 *     char* name;
 *     float x;
 *     float y;
 * } player_t;
 * 
 * static const colyseus_field_t player_fields[] = {
 *     {0, "name", COLYSEUS_FIELD_STRING, "string", offsetof(player_t, name), NULL, NULL},
 *     {1, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, x), NULL, NULL},
 *     {2, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, y), NULL, NULL},
 * };
 * 
 * static player_t* player_create(void) {
 *     player_t* p = calloc(1, sizeof(player_t));
 *     return p;
 * }
 * 
 * static void player_destroy(colyseus_schema_t* s) {
 *     player_t* p = (player_t*)s;
 *     free(p->name);
 *     free(p);
 * }
 * 
 * static const colyseus_schema_vtable_t player_vtable = {
 *     "Player",
 *     sizeof(player_t),
 *     (colyseus_schema_t* (*)(void))player_create,
 *     player_destroy,
 *     player_fields,
 *     3
 * };
 * 
 * // Use decoder
 * colyseus_decoder_t* decoder = colyseus_decoder_create(&player_vtable);
 * colyseus_decoder_decode(decoder, bytes, length, NULL);
 * player_t* state = (player_t*)colyseus_decoder_get_state(decoder);
 */

#include "schema/types.h"
#include "schema/decode.h"
#include "schema/collections.h"
#include "schema/ref_tracker.h"
#include "schema/decoder.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Helper macros for schema definition
 * ============================================================================ */

/* Define field type enum from string */
#define COLYSEUS_TYPE_FROM_STR(str) \
    (strcmp(str, "string") == 0 ? COLYSEUS_FIELD_STRING : \
     strcmp(str, "number") == 0 ? COLYSEUS_FIELD_NUMBER : \
     strcmp(str, "boolean") == 0 ? COLYSEUS_FIELD_BOOLEAN : \
     strcmp(str, "int8") == 0 ? COLYSEUS_FIELD_INT8 : \
     strcmp(str, "uint8") == 0 ? COLYSEUS_FIELD_UINT8 : \
     strcmp(str, "int16") == 0 ? COLYSEUS_FIELD_INT16 : \
     strcmp(str, "uint16") == 0 ? COLYSEUS_FIELD_UINT16 : \
     strcmp(str, "int32") == 0 ? COLYSEUS_FIELD_INT32 : \
     strcmp(str, "uint32") == 0 ? COLYSEUS_FIELD_UINT32 : \
     strcmp(str, "int64") == 0 ? COLYSEUS_FIELD_INT64 : \
     strcmp(str, "uint64") == 0 ? COLYSEUS_FIELD_UINT64 : \
     strcmp(str, "float32") == 0 ? COLYSEUS_FIELD_FLOAT32 : \
     strcmp(str, "float64") == 0 ? COLYSEUS_FIELD_FLOAT64 : \
     strcmp(str, "ref") == 0 ? COLYSEUS_FIELD_REF : \
     strcmp(str, "array") == 0 ? COLYSEUS_FIELD_ARRAY : \
     strcmp(str, "map") == 0 ? COLYSEUS_FIELD_MAP : COLYSEUS_FIELD_STRING)

/* Macro to define a primitive field */
#define COLYSEUS_FIELD_PRIMITIVE(idx, fname, ftype, struct_type) \
    {idx, fname, COLYSEUS_TYPE_FROM_STR(ftype), ftype, offsetof(struct_type, fname), NULL, NULL}

/* Macro to define a ref field */
#define COLYSEUS_FIELD_REF_TYPE(idx, fname, struct_type, child_vtable_ptr) \
    {idx, fname, COLYSEUS_FIELD_REF, "ref", offsetof(struct_type, fname), child_vtable_ptr, NULL}

/* Macro to define an array field with schema children */
#define COLYSEUS_FIELD_ARRAY_SCHEMA(idx, fname, struct_type, child_vtable_ptr) \
    {idx, fname, COLYSEUS_FIELD_ARRAY, "array", offsetof(struct_type, fname), child_vtable_ptr, NULL}

/* Macro to define an array field with primitive children */
#define COLYSEUS_FIELD_ARRAY_PRIMITIVE(idx, fname, struct_type, prim_type) \
    {idx, fname, COLYSEUS_FIELD_ARRAY, "array", offsetof(struct_type, fname), NULL, prim_type}

/* Macro to define a map field with schema children */
#define COLYSEUS_FIELD_MAP_SCHEMA(idx, fname, struct_type, child_vtable_ptr) \
    {idx, fname, COLYSEUS_FIELD_MAP, "map", offsetof(struct_type, fname), child_vtable_ptr, NULL}

/* Macro to define a map field with primitive children */
#define COLYSEUS_FIELD_MAP_PRIMITIVE(idx, fname, struct_type, prim_type) \
    {idx, fname, COLYSEUS_FIELD_MAP, "map", offsetof(struct_type, fname), NULL, prim_type}

/* ============================================================================
 * Schema Serializer interface (for Room integration)
 * ============================================================================ */

typedef struct colyseus_schema_serializer {
    colyseus_decoder_t* decoder;
    colyseus_iterator_t it;
} colyseus_schema_serializer_t;

/* Create serializer with state vtable */
colyseus_schema_serializer_t* colyseus_schema_serializer_create(const colyseus_schema_vtable_t* state_vtable);
void colyseus_schema_serializer_free(colyseus_schema_serializer_t* serializer);

/* ISerializer interface */
void colyseus_schema_serializer_set_state(colyseus_schema_serializer_t* serializer, const uint8_t* data, size_t length, int offset);
void* colyseus_schema_serializer_get_state(colyseus_schema_serializer_t* serializer);
void colyseus_schema_serializer_patch(colyseus_schema_serializer_t* serializer, const uint8_t* data, size_t length, int offset);
void colyseus_schema_serializer_teardown(colyseus_schema_serializer_t* serializer);
void colyseus_schema_serializer_handshake(colyseus_schema_serializer_t* serializer, const uint8_t* bytes, size_t length, int offset);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_H */