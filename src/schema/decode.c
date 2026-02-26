#include "colyseus/schema/decode.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <limits.h>

/* Helper: read little-endian values */
static inline uint16_t read_le16(const uint8_t* bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static inline uint32_t read_le32(const uint8_t* bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static inline uint64_t read_le64(const uint8_t* bytes) {
    return (uint64_t)bytes[0] | ((uint64_t)bytes[1] << 8) |
           ((uint64_t)bytes[2] << 16) | ((uint64_t)bytes[3] << 24) |
           ((uint64_t)bytes[4] << 32) | ((uint64_t)bytes[5] << 40) |
           ((uint64_t)bytes[6] << 48) | ((uint64_t)bytes[7] << 56);
}

/* Decode variable-length number (msgpack format) - returns double for full precision */
double colyseus_decode_number(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint8_t prefix = bytes[it->offset++];

    /* positive fixint (0x00 - 0x7f) */
    if (prefix < 0x80) {
        return (double)prefix;
    }

    /* float 32 */
    if (prefix == 0xca) {
        return (double)colyseus_decode_float32(bytes, it);
    }

    /* float 64 */
    if (prefix == 0xcb) {
        return colyseus_decode_float64(bytes, it);
    }

    /* uint 8 */
    if (prefix == 0xcc) {
        return (double)colyseus_decode_uint8(bytes, it);
    }

    /* uint 16 */
    if (prefix == 0xcd) {
        return (double)colyseus_decode_uint16(bytes, it);
    }

    /* uint 32 */
    if (prefix == 0xce) {
        return (double)colyseus_decode_uint32(bytes, it);
    }

    /* uint 64 */
    if (prefix == 0xcf) {
        return (double)colyseus_decode_uint64(bytes, it);
    }

    /* int 8 */
    if (prefix == 0xd0) {
        return (double)colyseus_decode_int8(bytes, it);
    }

    /* int 16 */
    if (prefix == 0xd1) {
        return (double)colyseus_decode_int16(bytes, it);
    }

    /* int 32 */
    if (prefix == 0xd2) {
        return (double)colyseus_decode_int32(bytes, it);
    }

    /* int 64 */
    if (prefix == 0xd3) {
        return (double)colyseus_decode_int64(bytes, it);
    }

    /* negative fixint (0xe0 - 0xff) */
    if (prefix > 0xdf) {
        return (double)((int)(0xff - prefix + 1) * -1);
    }

    return NAN;
}

int8_t colyseus_decode_int8(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint8_t val = colyseus_decode_uint8(bytes, it);
    return (int8_t)val;
}

uint8_t colyseus_decode_uint8(const uint8_t* bytes, colyseus_iterator_t* it) {
    return bytes[it->offset++];
}

int16_t colyseus_decode_int16(const uint8_t* bytes, colyseus_iterator_t* it) {
    int16_t value = (int16_t)read_le16(bytes + it->offset);
    it->offset += 2;
    return value;
}

uint16_t colyseus_decode_uint16(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint16_t value = read_le16(bytes + it->offset);
    it->offset += 2;
    return value;
}

int32_t colyseus_decode_int32(const uint8_t* bytes, colyseus_iterator_t* it) {
    int32_t value = (int32_t)read_le32(bytes + it->offset);
    it->offset += 4;
    return value;
}

uint32_t colyseus_decode_uint32(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint32_t value = read_le32(bytes + it->offset);
    it->offset += 4;
    return value;
}

int64_t colyseus_decode_int64(const uint8_t* bytes, colyseus_iterator_t* it) {
    int64_t value = (int64_t)read_le64(bytes + it->offset);
    it->offset += 8;
    return value;
}

uint64_t colyseus_decode_uint64(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint64_t value = read_le64(bytes + it->offset);
    it->offset += 8;
    return value;
}

float colyseus_decode_float32(const uint8_t* bytes, colyseus_iterator_t* it) {
    union { uint32_t i; float f; } u;
    u.i = read_le32(bytes + it->offset);
    it->offset += 4;
    return u.f;
}

double colyseus_decode_float64(const uint8_t* bytes, colyseus_iterator_t* it) {
    union { uint64_t i; double d; } u;
    u.i = read_le64(bytes + it->offset);
    it->offset += 8;
    return u.d;
}

bool colyseus_decode_boolean(const uint8_t* bytes, colyseus_iterator_t* it) {
    return colyseus_decode_uint8(bytes, it) > 0;
}

// TODO: check against original JavaScript implementation.
char* colyseus_decode_string(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint8_t prefix = bytes[it->offset++];
    size_t length;

    if (prefix >= 0xa0 && prefix <= 0xbf) {
        /* fixstr (0xa0 - 0xbf): length is bottom 5 bits */
        length = prefix & 0x1f;
    } else if (prefix == 0xd9) {
        /* str 8 */
        length = colyseus_decode_uint8(bytes, it);
    } else if (prefix == 0xda) {
        /* str 16 */
        length = colyseus_decode_uint16(bytes, it);
    } else if (prefix == 0xdb) {
        /* str 32 */
        length = colyseus_decode_uint32(bytes, it);
    } else if (prefix < 0x80) {
        /* Positive fixint used as length (common in Colyseus) */
        length = prefix;
    } else if (prefix == 0xcc) {
        /* uint8 length */
        length = colyseus_decode_uint8(bytes, it);
    } else if (prefix == 0xcd) {
        /* uint16 length */
        length = colyseus_decode_uint16(bytes, it);
    } else {
        /* Unknown prefix - return empty string */
        length = 0;
    }

    char* str = malloc(length + 1);
    if (str && length > 0) {
        memcpy(str, bytes + it->offset, length);
    }
    if (str) {
        str[length] = '\0';
    }
    it->offset += length;

    return str;
}

void* colyseus_decode_primitive(const char* type, const uint8_t* bytes, colyseus_iterator_t* it) {
    if (strcmp(type, "string") == 0) {
        return colyseus_decode_string(bytes, it);
    }

    /* Allocate space for primitive value */
    void* value = NULL;

    if (strcmp(type, "number") == 0) {
        double* v = malloc(sizeof(double));
        *v = colyseus_decode_number(bytes, it);
        value = v;
    } else if (strcmp(type, "int8") == 0) {
        int8_t* v = malloc(sizeof(int8_t));
        *v = colyseus_decode_int8(bytes, it);
        value = v;
    } else if (strcmp(type, "uint8") == 0) {
        uint8_t* v = malloc(sizeof(uint8_t));
        *v = colyseus_decode_uint8(bytes, it);
        value = v;
    } else if (strcmp(type, "int16") == 0) {
        int16_t* v = malloc(sizeof(int16_t));
        *v = colyseus_decode_int16(bytes, it);
        value = v;
    } else if (strcmp(type, "uint16") == 0) {
        uint16_t* v = malloc(sizeof(uint16_t));
        *v = colyseus_decode_uint16(bytes, it);
        value = v;
    } else if (strcmp(type, "int32") == 0) {
        int32_t* v = malloc(sizeof(int32_t));
        *v = colyseus_decode_int32(bytes, it);
        value = v;
    } else if (strcmp(type, "uint32") == 0) {
        uint32_t* v = malloc(sizeof(uint32_t));
        *v = colyseus_decode_uint32(bytes, it);
        value = v;
    } else if (strcmp(type, "int64") == 0) {
        int64_t* v = malloc(sizeof(int64_t));
        *v = colyseus_decode_int64(bytes, it);
        value = v;
    } else if (strcmp(type, "uint64") == 0) {
        uint64_t* v = malloc(sizeof(uint64_t));
        *v = colyseus_decode_uint64(bytes, it);
        value = v;
    } else if (strcmp(type, "float32") == 0) {
        float* v = malloc(sizeof(float));
        *v = colyseus_decode_float32(bytes, it);
        value = v;
    } else if (strcmp(type, "float64") == 0) {
        double* v = malloc(sizeof(double));
        *v = colyseus_decode_float64(bytes, it);
        value = v;
    } else if (strcmp(type, "boolean") == 0) {
        bool* v = malloc(sizeof(bool));
        *v = colyseus_decode_boolean(bytes, it);
        value = v;
    }

    return value;
}

bool colyseus_decode_switch_check(const uint8_t* bytes, colyseus_iterator_t* it) {
    return bytes[it->offset] == (uint8_t)COLYSEUS_SPEC_SWITCH_TO_STRUCTURE;
}

bool colyseus_decode_number_check(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint8_t prefix = bytes[it->offset];
    return prefix < 0x80 || (prefix >= 0xca && prefix <= 0xd3);
}

/* Safe float to int conversion (avoids undefined behavior for out-of-range values) */
static inline int float_to_int_safe(float f) {
    if (isnan(f) || isinf(f)) return 0;
    if (f > (float)INT_MAX) return INT_MAX;
    if (f < (float)INT_MIN) return INT_MIN;
    return (int)f;
}

int colyseus_decode_varint(const uint8_t* bytes, colyseus_iterator_t* it) {
    double d = colyseus_decode_number(bytes, it);
    /* Safe conversion from double to int */
    if (d != d) return 0;  /* NaN check */
    if (d > (double)INT_MAX) return INT_MAX;
    if (d < (double)INT_MIN) return INT_MIN;
    return (int)d;
}