#ifndef MSGPACK_GODOT_H
#define MSGPACK_GODOT_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Value types (matches Godot Variant types) */
typedef enum {
    MSGPACK_VALUE_NIL = 0,
    MSGPACK_VALUE_BOOL = 1,
    MSGPACK_VALUE_INT = 2,
    MSGPACK_VALUE_FLOAT = 3,
    MSGPACK_VALUE_STRING = 4,
    MSGPACK_VALUE_ARRAY = 5,
    MSGPACK_VALUE_DICTIONARY = 6,
    MSGPACK_VALUE_BINARY = 7,
} MsgpackValueType;

/* Callback for receiving decoded values */
typedef void (*msgpack_value_callback_fn)(
    MsgpackValueType value_type,
    int64_t int_value,
    double float_value,
    bool bool_value,
    const uint8_t* data_ptr,
    size_t data_len,
    size_t container_len,
    void* userdata
);

/* Callback for starting/ending containers */
typedef void (*msgpack_container_callback_fn)(
    bool is_start,
    bool is_array,  /* true = array, false = map/dictionary */
    size_t length,
    void* userdata
);

/* Decoder context */
typedef struct {
    msgpack_value_callback_fn value_callback;
    msgpack_container_callback_fn container_callback;
    void* userdata;
} MsgpackDecoderContext;

/* Decode a msgpack payload and call the appropriate callbacks
   Returns true on success, false on error */
bool msgpack_decode_to_godot(
    const uint8_t* data,
    size_t len,
    const MsgpackDecoderContext* ctx
);

/* Get error message for the last decode operation */
const char* msgpack_get_last_error(void);

/* Free any resources allocated during decoding */
void msgpack_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* MSGPACK_GODOT_H */
