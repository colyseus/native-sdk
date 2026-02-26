/**
 * Msgpack to Godot Variant conversion
 * 
 * This module provides direct conversion from msgpack-encoded data to
 * native Godot Variant types (Dictionary, Array, String, int, float, etc.)
 * without intermediate representations.
 */

#include "msgpack_variant.h"
#include "msgpack_godot.h"
#include <stdlib.h>
#include <string.h>

// ============================================================================
// Internal types and constants
// ============================================================================

#define MSGPACK_STACK_MAX_DEPTH 64

typedef enum {
    STACK_TYPE_NONE = 0,
    STACK_TYPE_ARRAY,
    STACK_TYPE_DICTIONARY,
} StackItemType;

typedef struct {
    StackItemType type;
    Variant variant;         // The Array or Dictionary variant
    size_t expected_count;   // Expected number of elements
    size_t current_count;    // Current number of elements added
    bool awaiting_key;       // For dictionaries: true if next value is a key
    Variant pending_key;     // For dictionaries: the key waiting for its value
} StackItem;

typedef struct {
    StackItem stack[MSGPACK_STACK_MAX_DEPTH];
    int stack_depth;
    Variant* result;         // Pointer to store the final result
    bool success;
} MsgpackBuilderContext;

// ============================================================================
// Forward declarations
// ============================================================================

static void msgpack_value_cb(
    MsgpackValueType value_type,
    int64_t int_value,
    double float_value,
    bool bool_value,
    const uint8_t* data_ptr,
    size_t data_len,
    size_t container_len,
    void* userdata
);

static void msgpack_container_cb(
    bool is_start,
    bool is_array,
    size_t length,
    void* userdata
);

// ============================================================================
// Helper functions
// ============================================================================

// Helper to create a nil Variant
static void variant_new_nil(Variant* v) {
    memset(v, 0, sizeof(Variant));
    // Variant type 0 is NIL in Godot
}

// Helper to resize an array using variant_call
static void array_variant_resize(Variant* arr_variant, int64_t new_size) {
    StringName resize_method;
    constructors.string_name_new_with_latin1_chars(&resize_method, "resize", false);
    
    Variant size_variant;
    constructors.variant_from_int_constructor(&size_variant, &new_size);
    
    GDExtensionConstVariantPtr args[1] = { &size_variant };
    Variant return_val;
    GDExtensionCallError error;
    api.variant_call(arr_variant, &resize_method, args, 1, &return_val, &error);
    
    destructors.string_name_destructor(&resize_method);
    destructors.variant_destroy(&size_variant);
    destructors.variant_destroy(&return_val);
}

// Helper to add a variant to the current container or set as result
static void builder_add_value(MsgpackBuilderContext* ctx, Variant* value) {
    if (ctx->stack_depth == 0) {
        // No container on stack, this is the root value
        *ctx->result = *value;
        return;
    }
    
    StackItem* current = &ctx->stack[ctx->stack_depth - 1];
    
    if (current->type == STACK_TYPE_ARRAY) {
        // Get the array from the variant
        Array arr;
        constructors.array_from_variant_constructor(&arr, &current->variant);
        
        // Resize array to accommodate new element
        int64_t new_size = (int64_t)(current->current_count + 1);
        array_variant_resize(&current->variant, new_size);
        
        // Get pointer to the slot and copy the variant there
        Variant* slot = api.array_operator_index(&arr, (GDExtensionInt)current->current_count);
        if (slot) {
            *slot = *value;
        }
        
        current->current_count++;
    } else if (current->type == STACK_TYPE_DICTIONARY) {
        if (current->awaiting_key) {
            // This value is a key, store it for later
            current->pending_key = *value;
            current->awaiting_key = false;
        } else {
            // This value is the value for the pending key
            Dictionary dict;
            constructors.dictionary_from_variant_constructor(&dict, &current->variant);
            
            // Get pointer for this key and set the value
            Variant* slot = api.dictionary_operator_index(&dict, &current->pending_key);
            if (slot) {
                *slot = *value;
            }
            
            // Clean up the key variant
            destructors.variant_destroy(&current->pending_key);
            
            current->current_count++;
            current->awaiting_key = true;  // Next value will be a key again
        }
    }
}

// ============================================================================
// Msgpack decoder callbacks
// ============================================================================

static void msgpack_value_cb(
    MsgpackValueType value_type,
    int64_t int_value,
    double float_value,
    bool bool_value,
    const uint8_t* data_ptr,
    size_t data_len,
    size_t container_len,
    void* userdata
) {
    (void)container_len;
    MsgpackBuilderContext* ctx = (MsgpackBuilderContext*)userdata;
    if (!ctx->success) return;
    
    Variant value;
    
    switch (value_type) {
        case MSGPACK_VALUE_NIL:
            variant_new_nil(&value);
            break;
            
        case MSGPACK_VALUE_BOOL: {
            GDExtensionBool b = bool_value ? 1 : 0;
            constructors.variant_from_bool_constructor(&value, &b);
            break;
        }
        
        case MSGPACK_VALUE_INT:
            constructors.variant_from_int_constructor(&value, &int_value);
            break;
            
        case MSGPACK_VALUE_FLOAT:
            constructors.variant_from_float_constructor(&value, &float_value);
            break;
            
        case MSGPACK_VALUE_STRING: {
            String str;
            if (data_ptr && data_len > 0) {
                constructors.string_new_with_utf8_chars_and_len(&str, (const char*)data_ptr, (GDExtensionInt)data_len);
            } else {
                constructors.string_new_with_utf8_chars(&str, "");
            }
            constructors.variant_from_string_constructor(&value, &str);
            destructors.string_destructor(&str);
            break;
        }
        
        case MSGPACK_VALUE_BINARY: {
            // Create PackedByteArray for binary data
            PackedByteArray byte_array;
            constructors.packed_byte_array_constructor(&byte_array, NULL);
            
            if (data_ptr && data_len > 0) {
                // Convert to variant for method calls
                Variant ba_variant;
                constructors.variant_from_packed_byte_array_constructor(&ba_variant, &byte_array);
                
                // Resize
                StringName resize_method;
                constructors.string_name_new_with_latin1_chars(&resize_method, "resize", false);
                int64_t size_val = (int64_t)data_len;
                Variant size_variant;
                constructors.variant_from_int_constructor(&size_variant, &size_val);
                GDExtensionConstVariantPtr resize_args[1] = { &size_variant };
                Variant resize_return;
                GDExtensionCallError error;
                api.variant_call(&ba_variant, &resize_method, resize_args, 1, &resize_return, &error);
                destructors.string_name_destructor(&resize_method);
                destructors.variant_destroy(&size_variant);
                destructors.variant_destroy(&resize_return);
                
                // Copy data
                for (size_t i = 0; i < data_len; i++) {
                    uint8_t* ptr = api.packed_byte_array_operator_index(&byte_array, (GDExtensionInt)i);
                    if (ptr) {
                        *ptr = data_ptr[i];
                    }
                }
                
                value = ba_variant;
            } else {
                constructors.variant_from_packed_byte_array_constructor(&value, &byte_array);
            }
            break;
        }
        
        case MSGPACK_VALUE_ARRAY:
        case MSGPACK_VALUE_DICTIONARY:
            // These are handled by container_callback
            return;
            
        default:
            variant_new_nil(&value);
            break;
    }
    
    builder_add_value(ctx, &value);
}

static void msgpack_container_cb(
    bool is_start,
    bool is_array,
    size_t length,
    void* userdata
) {
    MsgpackBuilderContext* ctx = (MsgpackBuilderContext*)userdata;
    if (!ctx->success) return;
    
    if (is_start) {
        // Starting a new container
        if (ctx->stack_depth >= MSGPACK_STACK_MAX_DEPTH) {
            ctx->success = false;
            return;
        }
        
        StackItem* item = &ctx->stack[ctx->stack_depth];
        item->expected_count = length;
        item->current_count = 0;
        
        if (is_array) {
            item->type = STACK_TYPE_ARRAY;
            item->awaiting_key = false;
            
            // Create empty Array
            Array arr;
            constructors.array_constructor(&arr, NULL);
            constructors.variant_from_array_constructor(&item->variant, &arr);
        } else {
            item->type = STACK_TYPE_DICTIONARY;
            item->awaiting_key = true;  // First value in a map is a key
            
            // Create empty Dictionary
            Dictionary dict;
            constructors.dictionary_constructor(&dict, NULL);
            constructors.variant_from_dictionary_constructor(&item->variant, &dict);
        }
        
        ctx->stack_depth++;
    } else {
        // Ending a container
        if (ctx->stack_depth <= 0) {
            ctx->success = false;
            return;
        }
        
        ctx->stack_depth--;
        StackItem* finished = &ctx->stack[ctx->stack_depth];
        
        // Add the finished container to its parent (or set as result)
        builder_add_value(ctx, &finished->variant);
        
        // Reset the stack item
        finished->type = STACK_TYPE_NONE;
    }
}

// ============================================================================
// Public API
// ============================================================================

bool msgpack_to_godot_variant(const uint8_t* data, size_t length, Variant* out_variant) {
    if (!data || length == 0 || !out_variant) {
        if (out_variant) {
            variant_new_nil(out_variant);
        }
        return length == 0;  // Empty data is valid, returns nil
    }
    
    MsgpackBuilderContext ctx = {0};
    ctx.result = out_variant;
    ctx.success = true;
    ctx.stack_depth = 0;
    
    // Initialize result to nil
    variant_new_nil(out_variant);
    
    MsgpackDecoderContext decoder_ctx = {
        .value_callback = msgpack_value_cb,
        .container_callback = msgpack_container_cb,
        .userdata = &ctx
    };
    
    bool decode_success = msgpack_decode_to_godot(data, length, &decoder_ctx);
    
    return decode_success && ctx.success;
}
