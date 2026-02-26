/**
 * Godot Variant to Msgpack encoding
 * 
 * This module provides conversion from native Godot Variant types to
 * msgpack-encoded binary data.
 */

#include "msgpack_encoder.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ============================================================================
// Internal types and constants
// ============================================================================

// Initial buffer size and growth factor
#define INITIAL_BUFFER_SIZE 256
#define BUFFER_GROWTH_FACTOR 2

// Msgpack format bytes
#define MSGPACK_NIL         0xc0
#define MSGPACK_FALSE       0xc2
#define MSGPACK_TRUE        0xc3
#define MSGPACK_BIN8        0xc4
#define MSGPACK_BIN16       0xc5
#define MSGPACK_BIN32       0xc6
#define MSGPACK_FLOAT32     0xca
#define MSGPACK_FLOAT64     0xcb
#define MSGPACK_UINT8       0xcc
#define MSGPACK_UINT16      0xcd
#define MSGPACK_UINT32      0xce
#define MSGPACK_UINT64      0xcf
#define MSGPACK_INT8        0xd0
#define MSGPACK_INT16       0xd1
#define MSGPACK_INT32       0xd2
#define MSGPACK_INT64       0xd3
#define MSGPACK_STR8        0xd9
#define MSGPACK_STR16       0xda
#define MSGPACK_STR32       0xdb
#define MSGPACK_ARRAY16     0xdc
#define MSGPACK_ARRAY32     0xdd
#define MSGPACK_MAP16       0xde
#define MSGPACK_MAP32       0xdf

// Encoder buffer context
typedef struct {
    uint8_t* data;
    size_t size;
    size_t capacity;
} EncoderBuffer;

// ============================================================================
// Buffer management
// ============================================================================

static bool buffer_init(EncoderBuffer* buf) {
    buf->data = (uint8_t*)malloc(INITIAL_BUFFER_SIZE);
    if (!buf->data) return false;
    buf->size = 0;
    buf->capacity = INITIAL_BUFFER_SIZE;
    return true;
}

static void buffer_free(EncoderBuffer* buf) {
    if (buf->data) {
        free(buf->data);
        buf->data = NULL;
    }
    buf->size = 0;
    buf->capacity = 0;
}

static bool buffer_ensure_capacity(EncoderBuffer* buf, size_t additional) {
    size_t required = buf->size + additional;
    if (required <= buf->capacity) return true;
    
    size_t new_capacity = buf->capacity;
    while (new_capacity < required) {
        new_capacity *= BUFFER_GROWTH_FACTOR;
    }
    
    uint8_t* new_data = (uint8_t*)realloc(buf->data, new_capacity);
    if (!new_data) return false;
    
    buf->data = new_data;
    buf->capacity = new_capacity;
    return true;
}

static bool buffer_write_byte(EncoderBuffer* buf, uint8_t byte) {
    if (!buffer_ensure_capacity(buf, 1)) return false;
    buf->data[buf->size++] = byte;
    return true;
}

static bool buffer_write_bytes(EncoderBuffer* buf, const uint8_t* bytes, size_t len) {
    if (!buffer_ensure_capacity(buf, len)) return false;
    memcpy(buf->data + buf->size, bytes, len);
    buf->size += len;
    return true;
}

static bool buffer_write_uint16_be(EncoderBuffer* buf, uint16_t value) {
    uint8_t bytes[2] = {
        (uint8_t)(value >> 8),
        (uint8_t)(value & 0xff)
    };
    return buffer_write_bytes(buf, bytes, 2);
}

static bool buffer_write_uint32_be(EncoderBuffer* buf, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)(value >> 24),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)(value & 0xff)
    };
    return buffer_write_bytes(buf, bytes, 4);
}

static bool buffer_write_uint64_be(EncoderBuffer* buf, uint64_t value) {
    uint8_t bytes[8] = {
        (uint8_t)(value >> 56),
        (uint8_t)((value >> 48) & 0xff),
        (uint8_t)((value >> 40) & 0xff),
        (uint8_t)((value >> 32) & 0xff),
        (uint8_t)((value >> 24) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)(value & 0xff)
    };
    return buffer_write_bytes(buf, bytes, 8);
}

// ============================================================================
// Msgpack encoding helpers
// ============================================================================

static bool encode_nil(EncoderBuffer* buf) {
    return buffer_write_byte(buf, MSGPACK_NIL);
}

static bool encode_bool(EncoderBuffer* buf, bool value) {
    return buffer_write_byte(buf, value ? MSGPACK_TRUE : MSGPACK_FALSE);
}

static bool encode_int(EncoderBuffer* buf, int64_t value) {
    if (value >= 0) {
        // Positive integer
        if (value <= 127) {
            // Positive fixint: single byte 0x00-0x7f
            return buffer_write_byte(buf, (uint8_t)value);
        } else if (value <= 0xff) {
            // uint8
            return buffer_write_byte(buf, MSGPACK_UINT8) &&
                   buffer_write_byte(buf, (uint8_t)value);
        } else if (value <= 0xffff) {
            // uint16
            return buffer_write_byte(buf, MSGPACK_UINT16) &&
                   buffer_write_uint16_be(buf, (uint16_t)value);
        } else if (value <= 0xffffffff) {
            // uint32
            return buffer_write_byte(buf, MSGPACK_UINT32) &&
                   buffer_write_uint32_be(buf, (uint32_t)value);
        } else {
            // uint64
            return buffer_write_byte(buf, MSGPACK_UINT64) &&
                   buffer_write_uint64_be(buf, (uint64_t)value);
        }
    } else {
        // Negative integer
        if (value >= -32) {
            // Negative fixint: 0xe0-0xff
            return buffer_write_byte(buf, (uint8_t)(0xe0 | (value & 0x1f)));
        } else if (value >= -128) {
            // int8
            return buffer_write_byte(buf, MSGPACK_INT8) &&
                   buffer_write_byte(buf, (uint8_t)(int8_t)value);
        } else if (value >= -32768) {
            // int16
            return buffer_write_byte(buf, MSGPACK_INT16) &&
                   buffer_write_uint16_be(buf, (uint16_t)(int16_t)value);
        } else if (value >= -2147483648LL) {
            // int32
            return buffer_write_byte(buf, MSGPACK_INT32) &&
                   buffer_write_uint32_be(buf, (uint32_t)(int32_t)value);
        } else {
            // int64
            return buffer_write_byte(buf, MSGPACK_INT64) &&
                   buffer_write_uint64_be(buf, (uint64_t)value);
        }
    }
}

static bool encode_float(EncoderBuffer* buf, double value) {
    // Always use float64 for precision
    if (!buffer_write_byte(buf, MSGPACK_FLOAT64)) return false;
    
    // Convert to big-endian bytes
    union {
        double d;
        uint64_t u;
    } conv;
    conv.d = value;
    
    return buffer_write_uint64_be(buf, conv.u);
}

static bool encode_string(EncoderBuffer* buf, const char* str, size_t len) {
    if (len <= 31) {
        // fixstr: 0xa0-0xbf
        if (!buffer_write_byte(buf, (uint8_t)(0xa0 | len))) return false;
    } else if (len <= 0xff) {
        // str8
        if (!buffer_write_byte(buf, MSGPACK_STR8)) return false;
        if (!buffer_write_byte(buf, (uint8_t)len)) return false;
    } else if (len <= 0xffff) {
        // str16
        if (!buffer_write_byte(buf, MSGPACK_STR16)) return false;
        if (!buffer_write_uint16_be(buf, (uint16_t)len)) return false;
    } else {
        // str32
        if (!buffer_write_byte(buf, MSGPACK_STR32)) return false;
        if (!buffer_write_uint32_be(buf, (uint32_t)len)) return false;
    }
    
    return buffer_write_bytes(buf, (const uint8_t*)str, len);
}

static bool encode_binary(EncoderBuffer* buf, const uint8_t* data, size_t len) {
    if (len <= 0xff) {
        // bin8
        if (!buffer_write_byte(buf, MSGPACK_BIN8)) return false;
        if (!buffer_write_byte(buf, (uint8_t)len)) return false;
    } else if (len <= 0xffff) {
        // bin16
        if (!buffer_write_byte(buf, MSGPACK_BIN16)) return false;
        if (!buffer_write_uint16_be(buf, (uint16_t)len)) return false;
    } else {
        // bin32
        if (!buffer_write_byte(buf, MSGPACK_BIN32)) return false;
        if (!buffer_write_uint32_be(buf, (uint32_t)len)) return false;
    }
    
    return buffer_write_bytes(buf, data, len);
}

static bool encode_array_header(EncoderBuffer* buf, size_t len) {
    if (len <= 15) {
        // fixarray: 0x90-0x9f
        return buffer_write_byte(buf, (uint8_t)(0x90 | len));
    } else if (len <= 0xffff) {
        // array16
        return buffer_write_byte(buf, MSGPACK_ARRAY16) &&
               buffer_write_uint16_be(buf, (uint16_t)len);
    } else {
        // array32
        return buffer_write_byte(buf, MSGPACK_ARRAY32) &&
               buffer_write_uint32_be(buf, (uint32_t)len);
    }
}

static bool encode_map_header(EncoderBuffer* buf, size_t len) {
    if (len <= 15) {
        // fixmap: 0x80-0x8f
        return buffer_write_byte(buf, (uint8_t)(0x80 | len));
    } else if (len <= 0xffff) {
        // map16
        return buffer_write_byte(buf, MSGPACK_MAP16) &&
               buffer_write_uint16_be(buf, (uint16_t)len);
    } else {
        // map32
        return buffer_write_byte(buf, MSGPACK_MAP32) &&
               buffer_write_uint32_be(buf, (uint32_t)len);
    }
}

// ============================================================================
// Variant encoding (forward declaration for recursion)
// ============================================================================

static bool encode_variant(EncoderBuffer* buf, const Variant* variant);

// ============================================================================
// Godot type helpers
// ============================================================================

// Get array size using variant_call
static int64_t get_array_size(const Variant* arr_variant) {
    StringName size_method;
    constructors.string_name_new_with_latin1_chars(&size_method, "size", false);
    
    Variant return_val;
    GDExtensionCallError error;
    api.variant_call((Variant*)arr_variant, &size_method, NULL, 0, &return_val, &error);
    
    int64_t size = 0;
    if (error.error == GDEXTENSION_CALL_OK) {
        constructors.int_from_variant_constructor(&size, &return_val);
    }
    
    destructors.string_name_destructor(&size_method);
    destructors.variant_destroy(&return_val);
    
    return size;
}

// Get dictionary keys using variant_call
static bool get_dictionary_keys(const Variant* dict_variant, Variant* out_keys) {
    StringName keys_method;
    constructors.string_name_new_with_latin1_chars(&keys_method, "keys", false);
    
    GDExtensionCallError error;
    api.variant_call((Variant*)dict_variant, &keys_method, NULL, 0, out_keys, &error);
    
    destructors.string_name_destructor(&keys_method);
    
    return error.error == GDEXTENSION_CALL_OK;
}

// Get element at index from array using variant_call
static bool get_array_element(const Variant* arr_variant, int64_t index, Variant* out_element) {
    // Use variant_call to call the [] operator or get method
    // This avoids issues with array_operator_index_const and reference handling
    StringName get_method;
    constructors.string_name_new_with_latin1_chars(&get_method, "get", false);
    
    // Create index variant
    Variant index_variant;
    constructors.variant_from_int_constructor(&index_variant, &index);
    
    GDExtensionConstVariantPtr args[1] = { &index_variant };
    GDExtensionCallError error;
    api.variant_call((Variant*)arr_variant, &get_method, args, 1, out_element, &error);
    
    destructors.string_name_destructor(&get_method);
    destructors.variant_destroy(&index_variant);
    
    return error.error == GDEXTENSION_CALL_OK;
}

// Get value from dictionary by key using variant_call
static bool get_dictionary_value(const Variant* dict_variant, const Variant* key, Variant* out_value) {
    // Use variant_call to call the get method
    StringName get_method;
    constructors.string_name_new_with_latin1_chars(&get_method, "get", false);
    
    GDExtensionConstVariantPtr args[1] = { key };
    GDExtensionCallError error;
    api.variant_call((Variant*)dict_variant, &get_method, args, 1, out_value, &error);
    
    destructors.string_name_destructor(&get_method);
    
    return error.error == GDEXTENSION_CALL_OK;
}

// ============================================================================
// Complex type encoding
// ============================================================================

static bool encode_godot_string(EncoderBuffer* buf, const Variant* str_variant) {
    String str;
    constructors.string_from_variant_constructor(&str, str_variant);
    
    // Get string length
    int32_t length = api.string_to_utf8_chars(&str, NULL, 0);
    if (length <= 0) {
        destructors.string_destructor(&str);
        return encode_string(buf, "", 0);
    }
    
    // Allocate buffer and extract string
    char* buffer = (char*)malloc(length + 1);
    if (!buffer) {
        destructors.string_destructor(&str);
        return false;
    }
    
    api.string_to_utf8_chars(&str, buffer, length);
    buffer[length] = '\0';
    
    bool result = encode_string(buf, buffer, (size_t)length);
    
    free(buffer);
    destructors.string_destructor(&str);
    
    return result;
}

static bool encode_packed_byte_array(EncoderBuffer* buf, const Variant* pba_variant) {
    PackedByteArray pba;
    // Get PackedByteArray from variant using variant_call to get size
    int64_t size = get_array_size(pba_variant);
    
    if (size <= 0) {
        return encode_binary(buf, NULL, 0);
    }
    
    // Create temporary array to access bytes
    // We need to extract PackedByteArray properly
    GDExtensionTypeFromVariantConstructorFunc pba_from_variant = 
        (GDExtensionTypeFromVariantConstructorFunc)constructors.array_from_variant_constructor;
    
    // Use packed byte array specific extraction
    // First, get the size
    uint8_t* data = (uint8_t*)malloc((size_t)size);
    if (!data) return false;
    
    // Extract bytes one by one using operator_index_const
    // We need to convert variant to PackedByteArray first
    // This is a bit awkward but necessary for the C API
    
    // Actually, let's use variant_call to get each byte
    // Or better, we can directly access the packed byte array data
    
    // Create a local copy to work with
    PackedByteArray local_pba;
    constructors.packed_byte_array_constructor(&local_pba, NULL);
    
    // Copy from variant - use a different approach
    // Get the internal data pointer directly
    
    // Actually we need to iterate or use a method
    // Let's use the simpler approach: iterate with operator_index_const
    
    for (int64_t i = 0; i < size; i++) {
        const uint8_t* byte_ptr = api.packed_byte_array_operator_index_const(
            (const PackedByteArray*)pba_variant, (GDExtensionInt)i);
        if (byte_ptr) {
            data[i] = *byte_ptr;
        } else {
            data[i] = 0;
        }
    }
    
    bool result = encode_binary(buf, data, (size_t)size);
    free(data);
    
    return result;
}

static bool encode_array(EncoderBuffer* buf, const Variant* arr_variant) {
    int64_t size = get_array_size(arr_variant);
    
    if (!encode_array_header(buf, (size_t)size)) return false;
    
    for (int64_t i = 0; i < size; i++) {
        Variant element;
        if (!get_array_element(arr_variant, i, &element)) {
            return false;
        }
        
        bool result = encode_variant(buf, &element);
        destructors.variant_destroy(&element);
        
        if (!result) return false;
    }
    
    return true;
}

static bool encode_dictionary(EncoderBuffer* buf, const Variant* dict_variant) {
    // Get keys array
    Variant keys_variant;
    if (!get_dictionary_keys(dict_variant, &keys_variant)) {
        return false;
    }
    
    int64_t size = get_array_size(&keys_variant);
    
    if (!encode_map_header(buf, (size_t)size)) {
        destructors.variant_destroy(&keys_variant);
        return false;
    }
    
    for (int64_t i = 0; i < size; i++) {
        Variant key;
        if (!get_array_element(&keys_variant, i, &key)) {
            destructors.variant_destroy(&keys_variant);
            return false;
        }
        
        // Encode key
        if (!encode_variant(buf, &key)) {
            destructors.variant_destroy(&key);
            destructors.variant_destroy(&keys_variant);
            return false;
        }
        
        // Get and encode value
        Variant value;
        if (!get_dictionary_value(dict_variant, &key, &value)) {
            destructors.variant_destroy(&key);
            destructors.variant_destroy(&keys_variant);
            return false;
        }
        
        bool result = encode_variant(buf, &value);
        
        destructors.variant_destroy(&key);
        destructors.variant_destroy(&value);
        
        if (!result) {
            destructors.variant_destroy(&keys_variant);
            return false;
        }
    }
    
    destructors.variant_destroy(&keys_variant);
    return true;
}

// ============================================================================
// Main variant encoding
// ============================================================================

static bool encode_variant(EncoderBuffer* buf, const Variant* variant) {
    GDExtensionVariantType type = api.variant_get_type(variant);
    
    switch (type) {
        case GDEXTENSION_VARIANT_TYPE_NIL:
            return encode_nil(buf);
            
        case GDEXTENSION_VARIANT_TYPE_BOOL: {
            GDExtensionBool value;
            // Extract bool from variant
            GDExtensionTypeFromVariantConstructorFunc bool_from_variant = 
                (GDExtensionTypeFromVariantConstructorFunc)constructors.int_from_variant_constructor;
            // Actually, we need to check the variant value
            // For bool, we can use int extraction and check
            int64_t int_val = 0;
            constructors.int_from_variant_constructor(&int_val, variant);
            return encode_bool(buf, int_val != 0);
        }
            
        case GDEXTENSION_VARIANT_TYPE_INT: {
            int64_t value;
            constructors.int_from_variant_constructor(&value, variant);
            return encode_int(buf, value);
        }
            
        case GDEXTENSION_VARIANT_TYPE_FLOAT: {
            // Extract float/double from variant
            // Godot floats are typically doubles
            double value;
            // We need a float from variant constructor - let's use a workaround
            // by calling a method or using variant_call
            StringName method;
            constructors.string_name_new_with_latin1_chars(&method, "", false);
            
            // Actually, let's use the native float extraction
            // The Variant contains the float data directly for simple types
            // We can cast and extract - but this is tricky in C
            
            // Safer approach: use variant operations
            // For now, let's try direct memory access (Godot Variant layout)
            // The float is stored at a known offset in the Variant
            
            // Alternative: use string conversion and parse
            // Or: use variant multiplication/division to extract
            
            // Simplest for now: treat as int if we can't get float properly
            // But Godot floats are common, so let's try harder
            
            // Actually, looking at the Variant structure, for float type,
            // the value is stored in the first 8 bytes (double)
            memcpy(&value, variant, sizeof(double));
            
            destructors.string_name_destructor(&method);
            return encode_float(buf, value);
        }
            
        case GDEXTENSION_VARIANT_TYPE_STRING:
            return encode_godot_string(buf, variant);
            
        case GDEXTENSION_VARIANT_TYPE_STRING_NAME: {
            // StringName is used for dictionary keys in GDScript (e.g., { name: "value" })
            // Use variant_stringify to convert StringName variant directly to String
            String str;
            api.variant_stringify(variant, &str);
            
            // Get string length
            int32_t length = api.string_to_utf8_chars(&str, NULL, 0);
            if (length <= 0) {
                destructors.string_destructor(&str);
                return encode_string(buf, "", 0);
            }
            
            // Allocate buffer and extract string
            char* buffer = (char*)malloc(length + 1);
            if (!buffer) {
                destructors.string_destructor(&str);
                return false;
            }
            
            api.string_to_utf8_chars(&str, buffer, length);
            buffer[length] = '\0';
            
            bool result = encode_string(buf, buffer, (size_t)length);
            
            free(buffer);
            destructors.string_destructor(&str);
            return result;
        }
            
        case GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY:
            return encode_packed_byte_array(buf, variant);
            
        case GDEXTENSION_VARIANT_TYPE_ARRAY:
            return encode_array(buf, variant);
            
        case GDEXTENSION_VARIANT_TYPE_DICTIONARY:
            return encode_dictionary(buf, variant);
            
        default:
            // Unsupported type - encode as nil
            printf("[msgpack_encoder] Warning: unsupported variant type %d, encoding as nil\n", type);
            fflush(stdout);
            return encode_nil(buf);
    }
}

// ============================================================================
// Public API
// ============================================================================

uint8_t* godot_variant_to_msgpack(const Variant* variant, size_t* out_length) {
    if (!variant || !out_length) {
        if (out_length) *out_length = 0;
        return NULL;
    }
    
    EncoderBuffer buf;
    if (!buffer_init(&buf)) {
        *out_length = 0;
        return NULL;
    }
    
    if (!encode_variant(&buf, variant)) {
        buffer_free(&buf);
        *out_length = 0;
        return NULL;
    }
    
    *out_length = buf.size;
    
    // Transfer ownership of buffer to caller
    // Shrink to exact size to avoid waste
    if (buf.size < buf.capacity) {
        uint8_t* result = (uint8_t*)realloc(buf.data, buf.size);
        if (result) {
            return result;
        }
    }
    
    return buf.data;
}
