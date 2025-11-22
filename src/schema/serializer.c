#include "colyseus/schema.h"
#include <stdlib.h>
#include <string.h>

colyseus_schema_serializer_t* colyseus_schema_serializer_create(const colyseus_schema_vtable_t* state_vtable) {
    colyseus_schema_serializer_t* serializer = malloc(sizeof(colyseus_schema_serializer_t));
    if (!serializer) return NULL;

    serializer->decoder = colyseus_decoder_create(state_vtable);
    serializer->it.offset = 0;

    return serializer;
}

void colyseus_schema_serializer_free(colyseus_schema_serializer_t* serializer) {
    if (!serializer) return;

    colyseus_decoder_free(serializer->decoder);
    free(serializer);
}

void colyseus_schema_serializer_set_state(colyseus_schema_serializer_t* serializer, 
    const uint8_t* data, size_t length, int offset) {
    if (!serializer) return;

    serializer->it.offset = offset;
    colyseus_decoder_decode(serializer->decoder, data, length, &serializer->it);
}

void* colyseus_schema_serializer_get_state(colyseus_schema_serializer_t* serializer) {
    if (!serializer) return NULL;
    return colyseus_decoder_get_state(serializer->decoder);
}

void colyseus_schema_serializer_patch(colyseus_schema_serializer_t* serializer,
    const uint8_t* data, size_t length, int offset) {
    if (!serializer) return;

    serializer->it.offset = offset;
    colyseus_decoder_decode(serializer->decoder, data, length, &serializer->it);
}

void colyseus_schema_serializer_teardown(colyseus_schema_serializer_t* serializer) {
    if (!serializer) return;
    colyseus_decoder_teardown(serializer->decoder);
}

void colyseus_schema_serializer_handshake(colyseus_schema_serializer_t* serializer,
    const uint8_t* bytes, size_t length, int offset) {
    if (!serializer) return;

    /*
     * Handshake decodes the reflection data from server and matches
     * it with local schema types.
     * 
     * For C, this is simpler than C#/JS because we use static vtables.
     * The handshake bytes contain:
     * - Array of ReflectionType (id, extendsId, fields[])
     * - rootType id
     * 
     * We decode this using a special Reflection schema decoder,
     * then match server types with our local vtables by comparing
     * field names and types.
     */

    /* TODO: Implement reflection decoding and type matching
     * 
     * For now, we assume the local schema matches the server.
     * In production, you would:
     * 1. Decode the Reflection schema from handshake bytes
     * 2. For each ReflectionType, find matching local vtable by field signature
     * 3. Call colyseus_type_context_set() to map server type IDs to local vtables
     */

    (void)bytes;
    (void)length;
    (void)offset;
}