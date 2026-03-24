#ifndef COLYSEUS_MESSAGES_H
#define COLYSEUS_MESSAGES_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Message Builder API (for creating outgoing messages)
 * ============================================================================ */

typedef struct colyseus_message colyseus_message_t;

/* Creation functions */
colyseus_message_t* colyseus_message_map_create(void);
colyseus_message_t* colyseus_message_array_create(void);
colyseus_message_t* colyseus_message_nil_create(void);
colyseus_message_t* colyseus_message_bool_create(bool value);
colyseus_message_t* colyseus_message_int_create(int64_t value);
colyseus_message_t* colyseus_message_uint_create(uint64_t value);
colyseus_message_t* colyseus_message_float_create(double value);
colyseus_message_t* colyseus_message_str_create(const char* value);

/* Map operations */
void colyseus_message_map_put_str(colyseus_message_t* map, const char* key, const char* value);
void colyseus_message_map_put_int(colyseus_message_t* map, const char* key, int64_t value);
void colyseus_message_map_put_uint(colyseus_message_t* map, const char* key, uint64_t value);
void colyseus_message_map_put_float(colyseus_message_t* map, const char* key, double value);
void colyseus_message_map_put_bool(colyseus_message_t* map, const char* key, bool value);
void colyseus_message_map_put_nil(colyseus_message_t* map, const char* key);
void colyseus_message_map_put_msg(colyseus_message_t* map, const char* key, colyseus_message_t* value);

/* Array operations */
void colyseus_message_array_push_str(colyseus_message_t* arr, const char* value);
void colyseus_message_array_push_int(colyseus_message_t* arr, int64_t value);
void colyseus_message_array_push_uint(colyseus_message_t* arr, uint64_t value);
void colyseus_message_array_push_float(colyseus_message_t* arr, double value);
void colyseus_message_array_push_bool(colyseus_message_t* arr, bool value);
void colyseus_message_array_push_nil(colyseus_message_t* arr);
void colyseus_message_array_push_msg(colyseus_message_t* arr, colyseus_message_t* value);

/* Encoding */
uint8_t* colyseus_message_encode(colyseus_message_t* message, size_t* out_len);

/* Cleanup */
void colyseus_message_free(colyseus_message_t* message);
void colyseus_message_encoded_free(uint8_t* data, size_t len);

/* ============================================================================
 * Message Reader API (for parsing incoming messages)
 * ============================================================================ */

typedef struct colyseus_message_reader colyseus_message_reader_t;

/* Message value types */
typedef enum {
    COLYSEUS_MESSAGE_TYPE_NIL = 0,
    COLYSEUS_MESSAGE_TYPE_BOOL = 1,
    COLYSEUS_MESSAGE_TYPE_INT = 2,
    COLYSEUS_MESSAGE_TYPE_UINT = 3,
    COLYSEUS_MESSAGE_TYPE_FLOAT = 4,
    COLYSEUS_MESSAGE_TYPE_STR = 5,
    COLYSEUS_MESSAGE_TYPE_BIN = 6,
    COLYSEUS_MESSAGE_TYPE_ARRAY = 7,
    COLYSEUS_MESSAGE_TYPE_MAP = 8
} colyseus_message_type_t;

/* Create reader from raw msgpack bytes (internal use - called by room.c) */
colyseus_message_reader_t* colyseus_message_reader_create(const uint8_t* data, size_t length);

/* Free reader */
void colyseus_message_reader_free(colyseus_message_reader_t* reader);

/* Get the type of the current value */
colyseus_message_type_t colyseus_message_reader_get_type(colyseus_message_reader_t* reader);

/* Check type helpers */
bool colyseus_message_reader_is_nil(colyseus_message_reader_t* reader);
bool colyseus_message_reader_is_bool(colyseus_message_reader_t* reader);
bool colyseus_message_reader_is_int(colyseus_message_reader_t* reader);
bool colyseus_message_reader_is_float(colyseus_message_reader_t* reader);
bool colyseus_message_reader_is_str(colyseus_message_reader_t* reader);
bool colyseus_message_reader_is_bin(colyseus_message_reader_t* reader);
bool colyseus_message_reader_is_array(colyseus_message_reader_t* reader);
bool colyseus_message_reader_is_map(colyseus_message_reader_t* reader);

/* Value extraction (returns default value if type mismatch) */
bool colyseus_message_reader_get_bool(colyseus_message_reader_t* reader);
int64_t colyseus_message_reader_get_int(colyseus_message_reader_t* reader);
uint64_t colyseus_message_reader_get_uint(colyseus_message_reader_t* reader);
double colyseus_message_reader_get_float(colyseus_message_reader_t* reader);

/* String/binary extraction - returns pointer to internal buffer (valid until reader is freed) */
const char* colyseus_message_reader_get_str(colyseus_message_reader_t* reader, size_t* out_len);
const uint8_t* colyseus_message_reader_get_bin(colyseus_message_reader_t* reader, size_t* out_len);

/* Array operations */
size_t colyseus_message_reader_get_array_size(colyseus_message_reader_t* reader);
colyseus_message_reader_t* colyseus_message_reader_get_array_element(colyseus_message_reader_t* reader, size_t index);

/* Map operations */
size_t colyseus_message_reader_get_map_size(colyseus_message_reader_t* reader);

/* Get map value by string key - returns sub-reader (caller must free) or NULL if not found */
colyseus_message_reader_t* colyseus_message_reader_map_get(colyseus_message_reader_t* reader, const char* key);

/* Convenience functions for common map access patterns */
bool colyseus_message_reader_map_get_str(colyseus_message_reader_t* reader, const char* key, const char** out_value, size_t* out_len);
bool colyseus_message_reader_map_get_int(colyseus_message_reader_t* reader, const char* key, int64_t* out_value);
bool colyseus_message_reader_map_get_uint(colyseus_message_reader_t* reader, const char* key, uint64_t* out_value);
bool colyseus_message_reader_map_get_float(colyseus_message_reader_t* reader, const char* key, double* out_value);
bool colyseus_message_reader_map_get_bool(colyseus_message_reader_t* reader, const char* key, bool* out_value);

/* Iterator for maps - iterate over key-value pairs */
typedef struct {
    colyseus_message_reader_t* map_reader;
    size_t current_index;
    size_t total_size;
} colyseus_message_map_iterator_t;

colyseus_message_map_iterator_t colyseus_message_reader_map_iterator(colyseus_message_reader_t* reader);
bool colyseus_message_map_iterator_next(colyseus_message_map_iterator_t* iter, colyseus_message_reader_t** out_key, colyseus_message_reader_t** out_value);

#ifdef __cplusplus
}
#endif

/* ============================================================================
 * C11 _Generic convenience macros for type-auto-detected map/array operations
 * ============================================================================
 *
 * Usage:
 *   float x = 10.0f;
 *   colyseus_message_map_put(msg, "x", x);       // auto-detects float
 *   colyseus_message_map_put(msg, "name", "foo"); // auto-detects string
 *   colyseus_message_map_put(msg, "nested", sub); // auto-detects nested message
 *
 * The explicit typed variants (_put_float, _put_int, etc.) remain available.
 */
#if !defined(__cplusplus) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L

#define colyseus_message_map_put(map, key, value) _Generic((value),     \
    _Bool:               colyseus_message_map_put_bool,                 \
    char*:               colyseus_message_map_put_str,                  \
    const char*:         colyseus_message_map_put_str,                  \
    int:                 colyseus_message_map_put_int,                  \
    long:                colyseus_message_map_put_int,                  \
    long long:           colyseus_message_map_put_int,                  \
    unsigned int:        colyseus_message_map_put_uint,                 \
    unsigned long:       colyseus_message_map_put_uint,                 \
    unsigned long long:  colyseus_message_map_put_uint,                 \
    float:               colyseus_message_map_put_float,                \
    double:              colyseus_message_map_put_float,                \
    colyseus_message_t*: colyseus_message_map_put_msg                   \
)(map, key, value)

#define colyseus_message_array_push(arr, value) _Generic((value),       \
    _Bool:               colyseus_message_array_push_bool,              \
    char*:               colyseus_message_array_push_str,               \
    const char*:         colyseus_message_array_push_str,               \
    int:                 colyseus_message_array_push_int,               \
    long:                colyseus_message_array_push_int,               \
    long long:           colyseus_message_array_push_int,               \
    unsigned int:        colyseus_message_array_push_uint,              \
    unsigned long:       colyseus_message_array_push_uint,              \
    unsigned long long:  colyseus_message_array_push_uint,              \
    float:               colyseus_message_array_push_float,             \
    double:              colyseus_message_array_push_float,             \
    colyseus_message_t*: colyseus_message_array_push_msg                \
)(arr, value)

#endif /* C11 _Generic */

#endif /* COLYSEUS_MESSAGES_H */
