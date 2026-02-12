#include "colyseus/schema/decode.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

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

/* Decode variable-length number (msgpack format) */
float colyseus_decode_number(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint8_t prefix = bytes[it->offset++];

    /* positive fixint (0x00 - 0x7f) */
    if (prefix < 0x80) {
        return (float)prefix;
    }

    /* float 32 */
    if (prefix == 0xca) {
        return colyseus_decode_float32(bytes, it);
    }

    /* float 64 */
    if (prefix == 0xcb) {
        return (float)colyseus_decode_float64(bytes, it);
    }

    /* uint 8 */
    if (prefix == 0xcc) {
        return (float)colyseus_decode_uint8(bytes, it);
    }

    /* uint 16 */
    if (prefix == 0xcd) {
        return (float)colyseus_decode_uint16(bytes, it);
    }

    /* uint 32 */
    if (prefix == 0xce) {
        return (float)colyseus_decode_uint32(bytes, it);
    }

    /* uint 64 */
    if (prefix == 0xcf) {
        return (float)colyseus_decode_uint64(bytes, it);
    }

    /* int 8 */
    if (prefix == 0xd0) {
        return (float)colyseus_decode_int8(bytes, it);
    }

    /* int 16 */
    if (prefix == 0xd1) {
        return (float)colyseus_decode_int16(bytes, it);
    }

    /* int 32 */
    if (prefix == 0xd2) {
        return (float)colyseus_decode_int32(bytes, it);
    }

    /* int 64 */
    if (prefix == 0xd3) {
        return (float)colyseus_decode_int64(bytes, it);
    }

    /* negative fixint (0xe0 - 0xff) */
    if (prefix > 0xdf) {
        return (float)((int)(0xff - prefix + 1) * -1);
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

char* colyseus_decode_string(const uint8_t* bytes, colyseus_iterator_t* it) {
    uint8_t prefix = bytes[it->offset++];
    size_t length;

    if (prefix < 0xc0) {
        /* fixstr (0xa0 - 0xbf) */
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
    } else {
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
        float* v = malloc(sizeof(float));
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