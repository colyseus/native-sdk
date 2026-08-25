#ifndef COLYSEUS_SCHEMA_ENCODE_H
#define COLYSEUS_SCHEMA_ENCODE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Encode counterpart of decode.h for the wire primitives the room layer
 * emits (little-endian, msgpack-style). Port of @colyseus/schema
 * src/encoding/encode.ts — the dynamic "number" codec and the fixed-width
 * primitives the input layer needs.
 */

/* Growable byte buffer the encoders append to. */
typedef struct {
    uint8_t* data;
    size_t length;
    size_t capacity;
} colyseus_wbuf_t;

void colyseus_wbuf_init(colyseus_wbuf_t* buf);
void colyseus_wbuf_free(colyseus_wbuf_t* buf);
void colyseus_wbuf_reset(colyseus_wbuf_t* buf);
void colyseus_wbuf_push(colyseus_wbuf_t* buf, uint8_t byte);
void colyseus_wbuf_append(colyseus_wbuf_t* buf, const uint8_t* data, size_t length);

/*
 * The schema dynamic "number" codec (msgpack-style, both signs + floats).
 * NaN encodes as 0; ±Infinity as ±MAX_SAFE_INTEGER; fractional values as
 * float32 when the f32 round-trip stays within 1e-4, else float64.
 */
void colyseus_encode_number(colyseus_wbuf_t* buf, double value);

void colyseus_encode_int8(colyseus_wbuf_t* buf, int8_t value);
void colyseus_encode_uint8(colyseus_wbuf_t* buf, uint8_t value);
void colyseus_encode_int16(colyseus_wbuf_t* buf, int16_t value);
void colyseus_encode_uint16(colyseus_wbuf_t* buf, uint16_t value);
void colyseus_encode_int32(colyseus_wbuf_t* buf, int32_t value);
void colyseus_encode_uint32(colyseus_wbuf_t* buf, uint32_t value);
void colyseus_encode_int64(colyseus_wbuf_t* buf, int64_t value);
void colyseus_encode_uint64(colyseus_wbuf_t* buf, uint64_t value);
void colyseus_encode_float32(colyseus_wbuf_t* buf, float value);
void colyseus_encode_float64(colyseus_wbuf_t* buf, double value);
void colyseus_encode_boolean(colyseus_wbuf_t* buf, bool value);

/* fixstr / str8 / str16 / str32 with utf8 payload. NULL encodes as empty. */
void colyseus_encode_string(colyseus_wbuf_t* buf, const char* value);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_ENCODE_H */
