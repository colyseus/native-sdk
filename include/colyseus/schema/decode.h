#ifndef COLYSEUS_SCHEMA_DECODE_H
#define COLYSEUS_SCHEMA_DECODE_H

#include "types.h"
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

    /*
     * Decoding utilities for Colyseus Schema binary protocol
     * All multi-byte values are little-endian
     */

    /* Decode a variable-length number (msgpack format) */
    double colyseus_decode_number(const uint8_t* bytes, colyseus_iterator_t* it);

    /* Decode primitive types */
    int8_t colyseus_decode_int8(const uint8_t* bytes, colyseus_iterator_t* it);
    uint8_t colyseus_decode_uint8(const uint8_t* bytes, colyseus_iterator_t* it);
    int16_t colyseus_decode_int16(const uint8_t* bytes, colyseus_iterator_t* it);
    uint16_t colyseus_decode_uint16(const uint8_t* bytes, colyseus_iterator_t* it);
    int32_t colyseus_decode_int32(const uint8_t* bytes, colyseus_iterator_t* it);
    uint32_t colyseus_decode_uint32(const uint8_t* bytes, colyseus_iterator_t* it);
    int64_t colyseus_decode_int64(const uint8_t* bytes, colyseus_iterator_t* it);
    uint64_t colyseus_decode_uint64(const uint8_t* bytes, colyseus_iterator_t* it);
    float colyseus_decode_float32(const uint8_t* bytes, colyseus_iterator_t* it);
    double colyseus_decode_float64(const uint8_t* bytes, colyseus_iterator_t* it);
    bool colyseus_decode_boolean(const uint8_t* bytes, colyseus_iterator_t* it);

    /* Decode string (returns newly allocated string, caller must free) */
    char* colyseus_decode_string(const uint8_t* bytes, colyseus_iterator_t* it);

    /* Decode primitive by type string */
    void* colyseus_decode_primitive(const char* type, const uint8_t* bytes, colyseus_iterator_t* it);

    /* Check if current byte is SWITCH_TO_STRUCTURE */
    bool colyseus_decode_switch_check(const uint8_t* bytes, colyseus_iterator_t* it);

    /* Check if current byte represents a number */
    bool colyseus_decode_number_check(const uint8_t* bytes, colyseus_iterator_t* it);

    /* Decode a varint as int (safe bounds checking) */
    int colyseus_decode_varint(const uint8_t* bytes, colyseus_iterator_t* it);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_DECODE_H */
