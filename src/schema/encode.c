#include "colyseus/schema/encode.h"

#include <math.h>
#include <string.h>
#include <stdlib.h>

/* ── growable buffer ─────────────────────────────────────────────────── */

void colyseus_wbuf_init(colyseus_wbuf_t* buf) {
    buf->data = NULL;
    buf->length = 0;
    buf->capacity = 0;
}

void colyseus_wbuf_free(colyseus_wbuf_t* buf) {
    free(buf->data);
    buf->data = NULL;
    buf->length = 0;
    buf->capacity = 0;
}

void colyseus_wbuf_reset(colyseus_wbuf_t* buf) {
    buf->length = 0;
}

static void wbuf_reserve(colyseus_wbuf_t* buf, size_t extra) {
    if (buf->length + extra <= buf->capacity) return;
    size_t new_capacity = buf->capacity ? buf->capacity * 2 : 64;
    while (new_capacity < buf->length + extra) new_capacity *= 2;
    buf->data = realloc(buf->data, new_capacity);
    buf->capacity = new_capacity;
}

void colyseus_wbuf_push(colyseus_wbuf_t* buf, uint8_t byte) {
    wbuf_reserve(buf, 1);
    buf->data[buf->length++] = byte;
}

void colyseus_wbuf_append(colyseus_wbuf_t* buf, const uint8_t* data, size_t length) {
    if (length == 0) return;
    wbuf_reserve(buf, length);
    memcpy(buf->data + buf->length, data, length);
    buf->length += length;
}

/* ── fixed-width primitives (little-endian) ──────────────────────────── */

void colyseus_encode_int8(colyseus_wbuf_t* buf, int8_t value) {
    colyseus_wbuf_push(buf, (uint8_t)value);
}

void colyseus_encode_uint8(colyseus_wbuf_t* buf, uint8_t value) {
    colyseus_wbuf_push(buf, value);
}

void colyseus_encode_uint16(colyseus_wbuf_t* buf, uint16_t value) {
    colyseus_wbuf_push(buf, (uint8_t)(value & 0xFF));
    colyseus_wbuf_push(buf, (uint8_t)(value >> 8));
}

void colyseus_encode_int16(colyseus_wbuf_t* buf, int16_t value) {
    colyseus_encode_uint16(buf, (uint16_t)value);
}

void colyseus_encode_uint32(colyseus_wbuf_t* buf, uint32_t value) {
    colyseus_wbuf_push(buf, (uint8_t)(value & 0xFF));
    colyseus_wbuf_push(buf, (uint8_t)((value >> 8) & 0xFF));
    colyseus_wbuf_push(buf, (uint8_t)((value >> 16) & 0xFF));
    colyseus_wbuf_push(buf, (uint8_t)((value >> 24) & 0xFF));
}

void colyseus_encode_int32(colyseus_wbuf_t* buf, int32_t value) {
    colyseus_encode_uint32(buf, (uint32_t)value);
}

void colyseus_encode_uint64(colyseus_wbuf_t* buf, uint64_t value) {
    colyseus_encode_uint32(buf, (uint32_t)(value & 0xFFFFFFFFu));
    colyseus_encode_uint32(buf, (uint32_t)(value >> 32));
}

void colyseus_encode_int64(colyseus_wbuf_t* buf, int64_t value) {
    colyseus_encode_uint64(buf, (uint64_t)value);
}

void colyseus_encode_float32(colyseus_wbuf_t* buf, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    colyseus_encode_uint32(buf, bits);
}

void colyseus_encode_float64(colyseus_wbuf_t* buf, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    colyseus_encode_uint64(buf, bits);
}

void colyseus_encode_boolean(colyseus_wbuf_t* buf, bool value) {
    colyseus_wbuf_push(buf, value ? 1 : 0);
}

void colyseus_encode_string(colyseus_wbuf_t* buf, const char* value) {
    if (!value) value = "";
    size_t length = strlen(value);

    if (length < 0x20) {
        colyseus_wbuf_push(buf, (uint8_t)(length | 0xa0));
    } else if (length < 0x100) {
        colyseus_wbuf_push(buf, 0xd9);
        colyseus_wbuf_push(buf, (uint8_t)length);
    } else if (length < 0x10000) {
        colyseus_wbuf_push(buf, 0xda);
        colyseus_encode_uint16(buf, (uint16_t)length);
    } else {
        colyseus_wbuf_push(buf, 0xdb);
        colyseus_encode_uint32(buf, (uint32_t)length);
    }
    colyseus_wbuf_append(buf, (const uint8_t*)value, length);
}

/* ── the dynamic "number" codec ──────────────────────────────────────── */

#define MAX_SAFE_INTEGER 9007199254740991.0

void colyseus_encode_number(colyseus_wbuf_t* buf, double value) {
    if (isnan(value)) {
        colyseus_encode_number(buf, 0);
        return;
    }
    if (isinf(value)) {
        colyseus_encode_number(buf, value > 0 ? MAX_SAFE_INTEGER : -MAX_SAFE_INTEGER);
        return;
    }

    /* JS `value !== (value|0)`: fractional OR outside int32 range → float branch */
    bool is_int32 = value == floor(value) && value >= -2147483648.0 && value <= 2147483647.0;
    if (!is_int32) {
        if (fabs(value) <= 3.4028235e+38) {
            float as_f32 = (float)value;
            /* precision check — 1e-4 acceptable loss (mirrors the reference) */
            if (fabs(fabs((double)as_f32) - fabs(value)) < 1e-4) {
                colyseus_wbuf_push(buf, 0xca);
                colyseus_encode_float32(buf, as_f32);
                return;
            }
        }
        colyseus_wbuf_push(buf, 0xcb);
        colyseus_encode_float64(buf, value);
        return;
    }

    int32_t v = (int32_t)value;
    if (v >= 0) {
        if (v < 0x80) {
            colyseus_wbuf_push(buf, (uint8_t)v);
        } else if (v < 0x100) {
            colyseus_wbuf_push(buf, 0xcc);
            colyseus_wbuf_push(buf, (uint8_t)v);
        } else if (v < 0x10000) {
            colyseus_wbuf_push(buf, 0xcd);
            colyseus_encode_uint16(buf, (uint16_t)v);
        } else {
            colyseus_wbuf_push(buf, 0xce);
            colyseus_encode_uint32(buf, (uint32_t)v);
        }
    } else {
        if (v >= -0x20) {
            colyseus_wbuf_push(buf, (uint8_t)(0xe0 | (v + 0x20)));
        } else if (v >= -0x80) {
            colyseus_wbuf_push(buf, 0xd0);
            colyseus_encode_int8(buf, (int8_t)v);
        } else if (v >= -0x8000) {
            colyseus_wbuf_push(buf, 0xd1);
            colyseus_encode_int16(buf, (int16_t)v);
        } else {
            colyseus_wbuf_push(buf, 0xd2);
            colyseus_encode_int32(buf, v);
        }
    }
}
