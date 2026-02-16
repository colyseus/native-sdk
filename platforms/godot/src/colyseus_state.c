#include "colyseus_state.h"
#include <colyseus/schema/collections.h>
#include <colyseus/schema/dynamic_schema.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

/* Magic marker used to identify dynamic vtables (from dynamic_schema.c) */
#define DYNAMIC_VTABLE_MAGIC_SIZE ((size_t)0xDEADBEEF)

/* Check if a vtable is a dynamic vtable */
static inline bool is_dynamic_vtable(const colyseus_schema_vtable_t* vtable) {
    return vtable && vtable->size == DYNAMIC_VTABLE_MAGIC_SIZE;
}

// Helper to create a Variant from an int64
static void variant_from_int(Variant* result, int64_t value) {
    constructors.variant_from_int_constructor(result, &value);
}

// Helper to create a Variant from a double
static void variant_from_float(Variant* result, double value) {
    constructors.variant_from_float_constructor(result, &value);
}

// Helper to create a Variant from a bool
static void variant_from_bool(Variant* result, bool value) {
    GDExtensionBool gd_bool = value ? 1 : 0;
    constructors.variant_from_bool_constructor(result, &gd_bool);
}

// Helper to create a Variant from a C string
static void variant_from_string(Variant* result, const char* str) {
    if (str == NULL) {
        // Create nil variant - use a null constructor or similar
        memset(result, 0, sizeof(Variant));
        return;
    }
    
    String gd_string;
    constructors.string_new_with_utf8_chars(&gd_string, str);
    constructors.variant_from_string_constructor(result, &gd_string);
    destructors.string_destructor(&gd_string);
}

// Helper to create a Variant from a Dictionary
static void variant_from_dictionary(Variant* result, Dictionary* dict) {
    constructors.variant_from_dictionary_constructor(result, dict);
}

// Helper to create a Variant from an Array
static void variant_from_array(Variant* result, Array* arr) {
    constructors.variant_from_array_constructor(result, arr);
}

// Helper to set a dictionary entry
static void dictionary_set(Dictionary* dict, const char* key, Variant* value) {
    // Create key string
    String key_string;
    constructors.string_new_with_utf8_chars(&key_string, key);
    
    // Create key variant
    Variant key_variant;
    constructors.variant_from_string_constructor(&key_variant, &key_string);
    
    // Get pointer to value slot and copy variant
    Variant* slot = (Variant*)api.dictionary_operator_index(dict, &key_variant);
    if (slot) {
        memcpy(slot, value, sizeof(Variant));
    }
    
    // Clean up key
    destructors.variant_destroy(&key_variant);
    destructors.string_destructor(&key_string);
}

// Helper to append to an array using push_back method
static void array_push_back(Array* arr, Variant* value) {
    // Convert Array to Variant for calling methods
    Variant arr_variant;
    constructors.variant_from_array_constructor(&arr_variant, arr);
    
    // Create method name
    StringName push_back_method;
    constructors.string_name_new_with_latin1_chars(&push_back_method, "push_back", false);
    
    // Call push_back with the value
    GDExtensionConstVariantPtr args[1] = { value };
    Variant return_value;
    GDExtensionCallError error;
    
    api.variant_call(&arr_variant, &push_back_method, args, 1, &return_value, &error);
    
    // Cleanup
    destructors.string_name_destructor(&push_back_method);
    destructors.variant_destroy(&return_value);
    destructors.variant_destroy(&arr_variant);
}

void colyseus_field_to_variant(
    const void* ptr,
    colyseus_field_type_t field_type,
    const colyseus_schema_vtable_t* child_vtable,
    Variant* result
) {
    if (ptr == NULL) {
        memset(result, 0, sizeof(Variant));
        return;
    }
    
    switch (field_type) {
        case COLYSEUS_FIELD_STRING: {
            const char* str = *(const char**)ptr;
            variant_from_string(result, str);
            break;
        }
        
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT32:
        case COLYSEUS_FIELD_FLOAT64: {
            // Numbers are stored as float in the schema
            float value = *(const float*)ptr;
            variant_from_float(result, (double)value);
            break;
        }
        
        case COLYSEUS_FIELD_BOOLEAN: {
            bool value = *(const bool*)ptr;
            variant_from_bool(result, value);
            break;
        }
        
        case COLYSEUS_FIELD_INT8: {
            int8_t value = *(const int8_t*)ptr;
            variant_from_int(result, (int64_t)value);
            break;
        }
        
        case COLYSEUS_FIELD_UINT8: {
            uint8_t value = *(const uint8_t*)ptr;
            variant_from_int(result, (int64_t)value);
            break;
        }
        
        case COLYSEUS_FIELD_INT16: {
            int16_t value = *(const int16_t*)ptr;
            variant_from_int(result, (int64_t)value);
            break;
        }
        
        case COLYSEUS_FIELD_UINT16: {
            uint16_t value = *(const uint16_t*)ptr;
            variant_from_int(result, (int64_t)value);
            break;
        }
        
        case COLYSEUS_FIELD_INT32: {
            int32_t value = *(const int32_t*)ptr;
            variant_from_int(result, (int64_t)value);
            break;
        }
        
        case COLYSEUS_FIELD_UINT32: {
            uint32_t value = *(const uint32_t*)ptr;
            variant_from_int(result, (int64_t)value);
            break;
        }
        
        case COLYSEUS_FIELD_INT64: {
            int64_t value = *(const int64_t*)ptr;
            variant_from_int(result, value);
            break;
        }
        
        case COLYSEUS_FIELD_UINT64: {
            uint64_t value = *(const uint64_t*)ptr;
            variant_from_int(result, (int64_t)value);
            break;
        }
        
        case COLYSEUS_FIELD_REF: {
            const colyseus_schema_t* child = *(const colyseus_schema_t**)ptr;
            if (child && child_vtable) {
                Dictionary child_dict;
                constructors.dictionary_constructor(&child_dict, NULL);
                // Check if it's a dynamic vtable (from reflection auto-detection)
                if (is_dynamic_vtable(child_vtable)) {
                    colyseus_dynamic_schema_to_dictionary((colyseus_dynamic_schema_t*)child, &child_dict);
                } else {
                    colyseus_schema_to_dictionary(child, child_vtable, &child_dict);
                }
                variant_from_dictionary(result, &child_dict);
                // Note: Don't destruct child_dict - it's now owned by the variant
            } else {
                memset(result, 0, sizeof(Variant));
            }
            break;
        }
        
        case COLYSEUS_FIELD_ARRAY: {
            const colyseus_array_schema_t* arr = *(const colyseus_array_schema_t**)ptr;
            if (arr) {
                Array gd_array;
                constructors.array_constructor(&gd_array, NULL);
                colyseus_array_to_godot_array(arr, &gd_array);
                variant_from_array(result, &gd_array);
            } else {
                memset(result, 0, sizeof(Variant));
            }
            break;
        }
        
        case COLYSEUS_FIELD_MAP: {
            const colyseus_map_schema_t* map = *(const colyseus_map_schema_t**)ptr;
            if (map) {
                Dictionary gd_dict;
                constructors.dictionary_constructor(&gd_dict, NULL);
                colyseus_map_to_dictionary(map, &gd_dict);
                variant_from_dictionary(result, &gd_dict);
            } else {
                memset(result, 0, sizeof(Variant));
            }
            break;
        }
        
        default:
            memset(result, 0, sizeof(Variant));
            break;
    }
}

/* Forward declaration */
static void colyseus_dynamic_value_to_variant(
    const colyseus_dynamic_value_t* value,
    Variant* result
);

/* Internal function to convert dynamic schema with explicit vtable */
static void colyseus_dynamic_schema_to_dictionary_with_vtable(
    const colyseus_dynamic_schema_t* schema,
    const colyseus_dynamic_vtable_t* dyn_vtable,
    Dictionary* result
) {
    if (!schema || !result) return;
    
    // Add __ref_id field for nested callback support
    Variant ref_id_variant;
    variant_from_int(&ref_id_variant, (int64_t)schema->__refId);
    dictionary_set(result, "__ref_id", &ref_id_variant);
    
    // Use provided vtable or fall back to schema's vtable
    if (!dyn_vtable) {
        dyn_vtable = schema->__dyn_vtable;
    }
    
    if (!dyn_vtable) {
        // No vtable available - can't iterate fields
        return;
    }
    
    // Iterate over all fields defined in the vtable
    for (int i = 0; i < dyn_vtable->dyn_field_count; i++) {
        const colyseus_dynamic_field_t* field = dyn_vtable->dyn_fields[i];
        if (!field || !field->name) continue;
        
        // Look up the value by field index
        colyseus_dynamic_value_t* value = colyseus_dynamic_schema_get(
            (colyseus_dynamic_schema_t*)schema, field->index);
        
        if (!value) continue;  // Field not set yet
        
        Variant field_variant;
        colyseus_dynamic_value_to_variant(value, &field_variant);
        dictionary_set(result, field->name, &field_variant);
    }
}

void colyseus_schema_to_dictionary(
    const colyseus_schema_t* schema,
    const colyseus_schema_vtable_t* vtable,
    Dictionary* result
) {
    if (!schema || !vtable || !result) return;
    
    // Check if this is a dynamic vtable - if so, forward to dynamic handler
    if (is_dynamic_vtable(vtable)) {
        const colyseus_dynamic_vtable_t* dyn_vtable = (const colyseus_dynamic_vtable_t*)vtable;
        colyseus_dynamic_schema_to_dictionary_with_vtable(
            (const colyseus_dynamic_schema_t*)schema, dyn_vtable, result);
        return;
    }
    
    // Add __ref_id field for nested callback support
    Variant ref_id_variant;
    variant_from_int(&ref_id_variant, (int64_t)schema->__refId);
    dictionary_set(result, "__ref_id", &ref_id_variant);
    
    // Convert each field (static vtable)
    for (int i = 0; i < vtable->field_count; i++) {
        const colyseus_field_t* field = &vtable->fields[i];
        const void* field_ptr = (const char*)schema + field->offset;
        
        Variant field_variant;
        colyseus_field_to_variant(field_ptr, field->type, field->child_vtable, &field_variant);
        dictionary_set(result, field->name, &field_variant);
    }
}

/* Convert a dynamic value to a Godot Variant */
static void colyseus_dynamic_value_to_variant(
    const colyseus_dynamic_value_t* value,
    Variant* result
) {
    if (!value || !result) {
        memset(result, 0, sizeof(Variant));
        return;
    }
    
    switch (value->type) {
        case COLYSEUS_FIELD_STRING:
            variant_from_string(result, value->data.str);
            break;
            
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT64:
            variant_from_float(result, value->data.num);
            break;
            
        case COLYSEUS_FIELD_FLOAT32:
            variant_from_float(result, (double)value->data.f32);
            break;
            
        case COLYSEUS_FIELD_BOOLEAN:
            variant_from_bool(result, value->data.boolean);
            break;
            
        case COLYSEUS_FIELD_INT8:
            variant_from_int(result, (int64_t)value->data.i8);
            break;
            
        case COLYSEUS_FIELD_UINT8:
            variant_from_int(result, (int64_t)value->data.u8);
            break;
            
        case COLYSEUS_FIELD_INT16:
            variant_from_int(result, (int64_t)value->data.i16);
            break;
            
        case COLYSEUS_FIELD_UINT16:
            variant_from_int(result, (int64_t)value->data.u16);
            break;
            
        case COLYSEUS_FIELD_INT32:
            variant_from_int(result, (int64_t)value->data.i32);
            break;
            
        case COLYSEUS_FIELD_UINT32:
            variant_from_int(result, (int64_t)value->data.u32);
            break;
            
        case COLYSEUS_FIELD_INT64:
            variant_from_int(result, value->data.i64);
            break;
            
        case COLYSEUS_FIELD_UINT64:
            variant_from_int(result, (int64_t)value->data.u64);
            break;
            
        case COLYSEUS_FIELD_REF:
            if (value->data.ref) {
                Dictionary child_dict;
                constructors.dictionary_constructor(&child_dict, NULL);
                colyseus_dynamic_schema_to_dictionary(value->data.ref, &child_dict);
                variant_from_dictionary(result, &child_dict);
            } else {
                memset(result, 0, sizeof(Variant));
            }
            break;
            
        case COLYSEUS_FIELD_ARRAY:
            if (value->data.array) {
                Array gd_array;
                constructors.array_constructor(&gd_array, NULL);
                colyseus_array_to_godot_array(value->data.array, &gd_array);
                variant_from_array(result, &gd_array);
            } else {
                memset(result, 0, sizeof(Variant));
            }
            break;
            
        case COLYSEUS_FIELD_MAP:
            if (value->data.map) {
                Dictionary gd_dict;
                constructors.dictionary_constructor(&gd_dict, NULL);
                colyseus_map_to_dictionary(value->data.map, &gd_dict);
                variant_from_dictionary(result, &gd_dict);
            } else {
                memset(result, 0, sizeof(Variant));
            }
            break;
            
        default:
            memset(result, 0, sizeof(Variant));
            break;
    }
}

void colyseus_dynamic_schema_to_dictionary(
    const colyseus_dynamic_schema_t* schema,
    Dictionary* result
) {
    colyseus_dynamic_schema_to_dictionary_with_vtable(schema, NULL, result);
}

// Callback context for array iteration
typedef struct {
    Array* result;
    const colyseus_schema_vtable_t* child_vtable;
    bool has_schema_child;
} ArrayConvertContext;

static void array_item_to_godot(int index, void* value, void* userdata) {
    (void)index;
    ArrayConvertContext* ctx = (ArrayConvertContext*)userdata;
    
    Variant item_variant;
    
    if (ctx->has_schema_child && ctx->child_vtable && value) {
        // Convert schema child to dictionary
        Dictionary child_dict;
        constructors.dictionary_constructor(&child_dict, NULL);
        
        // Check if it's a dynamic vtable (from reflection auto-detection)
        if (is_dynamic_vtable(ctx->child_vtable)) {
            colyseus_dynamic_schema_to_dictionary((colyseus_dynamic_schema_t*)value, &child_dict);
        } else {
            colyseus_schema_to_dictionary((colyseus_schema_t*)value, ctx->child_vtable, &child_dict);
        }
        variant_from_dictionary(&item_variant, &child_dict);
    } else if (value) {
        // For primitive arrays, value is the actual value
        // TODO: Handle primitive types properly based on child_primitive_type
        memset(&item_variant, 0, sizeof(Variant));
    } else {
        memset(&item_variant, 0, sizeof(Variant));
    }
    
    array_push_back(ctx->result, &item_variant);
    destructors.variant_destroy(&item_variant);
}

void colyseus_array_to_godot_array(
    const colyseus_array_schema_t* array,
    Array* result
) {
    if (!array || !result) return;
    
    ArrayConvertContext ctx = {
        .result = result,
        .child_vtable = array->child_vtable,
        .has_schema_child = array->has_schema_child
    };
    
    // Iterate through array items
    colyseus_array_schema_foreach((colyseus_array_schema_t*)array, array_item_to_godot, &ctx);
}

// Callback context for map iteration
typedef struct {
    Dictionary* result;
    const colyseus_schema_vtable_t* child_vtable;
    bool has_schema_child;
} MapConvertContext;

static void map_item_to_godot(const char* key, void* value, void* userdata) {
    MapConvertContext* ctx = (MapConvertContext*)userdata;
    
    Variant item_variant;
    
    if (ctx->has_schema_child && ctx->child_vtable && value) {
        // Convert schema child to dictionary
        Dictionary child_dict;
        constructors.dictionary_constructor(&child_dict, NULL);
        
        // Check if it's a dynamic vtable (from reflection auto-detection)
        if (is_dynamic_vtable(ctx->child_vtable)) {
            colyseus_dynamic_schema_to_dictionary((colyseus_dynamic_schema_t*)value, &child_dict);
        } else {
            colyseus_schema_to_dictionary((colyseus_schema_t*)value, ctx->child_vtable, &child_dict);
        }
        variant_from_dictionary(&item_variant, &child_dict);
    } else if (value) {
        // For primitive maps, value is the actual value
        // TODO: Handle primitive types properly based on child_primitive_type
        memset(&item_variant, 0, sizeof(Variant));
    } else {
        memset(&item_variant, 0, sizeof(Variant));
    }
    
    dictionary_set(ctx->result, key, &item_variant);
}

void colyseus_map_to_dictionary(
    const colyseus_map_schema_t* map,
    Dictionary* result
) {
    if (!map || !result) return;
    
    MapConvertContext ctx = {
        .result = result,
        .child_vtable = map->child_vtable,
        .has_schema_child = map->has_schema_child
    };
    
    // Iterate through map items
    colyseus_map_schema_foreach((colyseus_map_schema_t*)map, map_item_to_godot, &ctx);
}

int colyseus_extract_ref_id(const Variant* dict_variant) {
    if (!dict_variant) return -1;
    
    // Convert variant to dictionary
    Dictionary dict;
    constructors.dictionary_from_variant_constructor(&dict, (GDExtensionVariantPtr)dict_variant);
    
    // Create key for __ref_id
    String key_string;
    constructors.string_new_with_utf8_chars(&key_string, "__ref_id");
    
    Variant key_variant;
    constructors.variant_from_string_constructor(&key_variant, &key_string);
    
    // Get the __ref_id value
    Variant* ref_id_variant = (Variant*)api.dictionary_operator_index(&dict, &key_variant);
    
    int result = -1;
    if (ref_id_variant) {
        // Properly extract int from variant using the type constructor
        int64_t value = 0;
        constructors.int_from_variant_constructor(&value, ref_id_variant);
        result = (int)value;
    }
    
    // Clean up
    destructors.variant_destroy(&key_variant);
    destructors.string_destructor(&key_string);
    destructors.dictionary_destructor(&dict);
    
    return result;
}
