#include "colyseus_gdscript_schema.h"
#include <colyseus/schema/collections.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ============================================================================
 * Helper Functions
 * ============================================================================ */

/* Helper to create a StringName from a C string */
static void create_string_name(StringName* sn, const char* str) {
    constructors.string_name_new_with_latin1_chars(sn, str, false);
}

/* Helper to call a method on a variant and return result */
static bool variant_call_method(Variant* variant, const char* method_name, 
    GDExtensionConstVariantPtr* args, int arg_count, Variant* result) {
    
    StringName method;
    create_string_name(&method, method_name);
    
    GDExtensionCallError error;
    api.variant_call(variant, &method, args, arg_count, result, &error);
    
    destructors.string_name_destructor(&method);
    
    return error.error == GDEXTENSION_CALL_OK;
}

/* Helper to convert Godot String to C string (caller must free) */
static char* godot_string_to_cstr(const String* str) {
    if (!str) return strdup("");
    
    int32_t length = api.string_to_utf8_chars(str, NULL, 0);
    if (length <= 0) return strdup("");
    
    char* buffer = (char*)malloc(length + 1);
    if (!buffer) return strdup("");
    
    api.string_to_utf8_chars(str, buffer, length);
    buffer[length] = '\0';
    
    return buffer;
}

/* Helper to create a C string from a Variant containing a String */
static char* variant_to_cstr(Variant* variant) {
    String str;
    constructors.string_from_variant_constructor(&str, variant);
    char* result = godot_string_to_cstr(&str);
    destructors.string_destructor(&str);
    return result;
}

/* Helper to get array size from variant */
static int64_t get_array_size_from_variant(Variant* arr_variant) {
    Variant return_val;
    if (!variant_call_method(arr_variant, "size", NULL, 0, &return_val)) {
        return 0;
    }
    
    int64_t size = 0;
    constructors.int_from_variant_constructor(&size, &return_val);
    destructors.variant_destroy(&return_val);
    
    return size;
}

/* Helper to get array element at index */
static bool get_array_element_at(Variant* arr_variant, int64_t index, Variant* out_element) {
    Variant index_variant;
    constructors.variant_from_int_constructor(&index_variant, &index);
    
    GDExtensionConstVariantPtr args[1] = { &index_variant };
    bool success = variant_call_method(arr_variant, "get", args, 1, out_element);
    
    destructors.variant_destroy(&index_variant);
    return success;
}

/* ============================================================================
 * Field Parsing
 * ============================================================================ */

/*
 * Parse a colyseus.Field object from a Variant.
 * The Field object has: name (String), type (String), child_type (class or null)
 */
static colyseus_dynamic_field_t* parse_field_from_variant(Variant* field_variant, int field_index,
    gdscript_schema_context_t** child_contexts, int* child_context_count) {
    
    /* Get field.name */
    Variant name_variant;
    if (!variant_call_method(field_variant, "get", NULL, 0, &name_variant)) {
        /* Try accessing property directly */
        StringName name_prop;
        create_string_name(&name_prop, "name");
        
        GDExtensionConstVariantPtr args[1] = { NULL };
        Variant prop_name_variant;
        constructors.variant_from_string_constructor(&prop_name_variant, &name_prop);
        args[0] = &prop_name_variant;
        
        if (!variant_call_method(field_variant, "get", args, 1, &name_variant)) {
            /* Fallback: assume it's directly accessible */
        }
        destructors.variant_destroy(&prop_name_variant);
        destructors.string_name_destructor(&name_prop);
    }
    
    /* Actually, for GDScript objects, we need to use the property access pattern */
    /* Let's use variant_call to call the getter for "name" property */
    
    /* Access 'name' property */
    String name_str_prop;
    constructors.string_new_with_utf8_chars(&name_str_prop, "name");
    Variant name_prop_variant;
    constructors.variant_from_string_constructor(&name_prop_variant, &name_str_prop);
    
    GDExtensionConstVariantPtr name_args[1] = { &name_prop_variant };
    Variant field_name_variant;
    variant_call_method(field_variant, "get", name_args, 1, &field_name_variant);
    
    char* field_name = variant_to_cstr(&field_name_variant);
    destructors.variant_destroy(&field_name_variant);
    destructors.variant_destroy(&name_prop_variant);
    destructors.string_destructor(&name_str_prop);
    
    /* Access 'type' property */
    String type_str_prop;
    constructors.string_new_with_utf8_chars(&type_str_prop, "type");
    Variant type_prop_variant;
    constructors.variant_from_string_constructor(&type_prop_variant, &type_str_prop);
    
    GDExtensionConstVariantPtr type_args[1] = { &type_prop_variant };
    Variant field_type_variant;
    variant_call_method(field_variant, "get", type_args, 1, &field_type_variant);
    
    char* field_type_str = variant_to_cstr(&field_type_variant);
    destructors.variant_destroy(&field_type_variant);
    destructors.variant_destroy(&type_prop_variant);
    destructors.string_destructor(&type_str_prop);
    
    /* Determine the field type enum */
    colyseus_field_type_t field_type = colyseus_field_type_from_string(field_type_str);
    
    printf("[GDScriptSchema] Parsed field: name='%s', type='%s' (enum=%d)\n", 
           field_name, field_type_str, field_type);
    fflush(stdout);
    
    /* Create the dynamic field */
    colyseus_dynamic_field_t* field = colyseus_dynamic_field_create(
        field_index, field_name, field_type, field_type_str);
    
    /* For collection types (map/array) or ref, check for child_type */
    if (field_type == COLYSEUS_FIELD_MAP || field_type == COLYSEUS_FIELD_ARRAY || 
        field_type == COLYSEUS_FIELD_REF) {
        
        String child_str_prop;
        constructors.string_new_with_utf8_chars(&child_str_prop, "child_type");
        Variant child_prop_variant;
        constructors.variant_from_string_constructor(&child_prop_variant, &child_str_prop);
        
        GDExtensionConstVariantPtr child_args[1] = { &child_prop_variant };
        Variant child_type_variant;
        variant_call_method(field_variant, "get", child_args, 1, &child_type_variant);
        
        GDExtensionVariantType child_variant_type = api.variant_get_type(&child_type_variant);
        
        if (child_variant_type == GDEXTENSION_VARIANT_TYPE_OBJECT) {
            /* Child type is a GDScript class - parse it recursively */
            gdscript_schema_context_t* child_ctx = gdscript_schema_context_create(&child_type_variant);
            if (child_ctx && child_ctx->vtable) {
                field->child_vtable = child_ctx->vtable;
                
                /* Store child context for cleanup */
                if (child_contexts && child_context_count) {
                    *child_contexts = realloc(*child_contexts, 
                        (*child_context_count + 1) * sizeof(gdscript_schema_context_t));
                    if (*child_contexts) {
                        (*child_contexts)[*child_context_count] = *child_ctx;
                        (*child_context_count)++;
                    }
                }
            }
        } else if (child_variant_type == GDEXTENSION_VARIANT_TYPE_STRING) {
            /* Child type is a primitive type string */
            char* child_primitive = variant_to_cstr(&child_type_variant);
            field->child_primitive_type = child_primitive;
        }
        
        destructors.variant_destroy(&child_type_variant);
        destructors.variant_destroy(&child_prop_variant);
        destructors.string_destructor(&child_str_prop);
    }
    
    free(field_name);
    free(field_type_str);
    
    return field;
}

/* ============================================================================
 * Schema Context Creation
 * ============================================================================ */

gdscript_schema_context_t* gdscript_schema_context_create(GDExtensionConstVariantPtr script_variant) {
    if (!script_variant) return NULL;
    
    gdscript_schema_context_t* ctx = calloc(1, sizeof(gdscript_schema_context_t));
    if (!ctx) return NULL;
    
    /* Store the script class reference */
    /* For a GDScript class passed as argument, it's typically a Script object */
    GDExtensionVariantType var_type = api.variant_get_type((GDExtensionVariantPtr)script_variant);
    
    if (var_type != GDEXTENSION_VARIANT_TYPE_OBJECT) {
        printf("[GDScriptSchema] Error: Expected Object type, got %d\n", var_type);
        fflush(stdout);
        free(ctx);
        return NULL;
    }
    
    /* Get the Object pointer from the variant */
    GDExtensionObjectPtr script_obj = NULL;
    constructors.object_from_variant_constructor(&script_obj, (GDExtensionVariantPtr)script_variant);
    ctx->script_class = script_obj;
    
    /* Call the static definition() method to get field definitions */
    /* In GDScript, static methods are called on the class/script object */
    Variant script_as_variant;
    constructors.variant_from_object_constructor(&script_as_variant, &script_obj);
    
    /* Call definition() - this should return an Array of Field objects */
    Variant definition_result;
    StringName definition_method;
    create_string_name(&definition_method, "definition");
    
    GDExtensionCallError error;
    api.variant_call(&script_as_variant, &definition_method, NULL, 0, &definition_result, &error);
    
    destructors.string_name_destructor(&definition_method);
    
    if (error.error != GDEXTENSION_CALL_OK) {
        printf("[GDScriptSchema] Failed to call definition() on class (error=%d)\n", error.error);
        fflush(stdout);
        
        /* Try calling new() first and then definition() on instance */
        Variant instance_result;
        if (variant_call_method(&script_as_variant, "new", NULL, 0, &instance_result)) {
            if (variant_call_method(&instance_result, "definition", NULL, 0, &definition_result)) {
                error.error = GDEXTENSION_CALL_OK;
            }
            destructors.variant_destroy(&instance_result);
        }
    }
    
    destructors.variant_destroy(&script_as_variant);
    
    if (error.error != GDEXTENSION_CALL_OK) {
        printf("[GDScriptSchema] Could not get definition from class\n");
        fflush(stdout);
        free(ctx);
        return NULL;
    }
    
    /* Parse the definition array */
    int64_t field_count = get_array_size_from_variant(&definition_result);
    
    printf("[GDScriptSchema] Found %lld fields in definition\n", (long long)field_count);
    fflush(stdout);
    
    /* Create dynamic vtable */
    ctx->vtable = colyseus_dynamic_vtable_create("GDScriptSchema");
    if (!ctx->vtable) {
        destructors.variant_destroy(&definition_result);
        free(ctx);
        return NULL;
    }
    
    /* Parse each field */
    gdscript_schema_context_t* child_contexts = NULL;
    int child_context_count = 0;
    
    for (int64_t i = 0; i < field_count; i++) {
        Variant field_variant;
        if (get_array_element_at(&definition_result, i, &field_variant)) {
            colyseus_dynamic_field_t* field = parse_field_from_variant(
                &field_variant, (int)i, &child_contexts, &child_context_count);
            
            if (field) {
                colyseus_dynamic_vtable_add_field(ctx->vtable, field);
            }
            
            destructors.variant_destroy(&field_variant);
        }
    }
    
    /* Store child contexts */
    ctx->children = child_contexts;
    ctx->child_count = child_context_count;
    
    /* Set up callbacks for GDScript instance creation */
    colyseus_dynamic_vtable_set_callbacks(ctx->vtable,
        gdscript_create_instance,
        gdscript_free_instance,
        gdscript_set_field,
        ctx->script_class);
    
    destructors.variant_destroy(&definition_result);
    
    printf("[GDScriptSchema] Created context with %d fields\n", ctx->vtable->dyn_field_count);
    fflush(stdout);
    
    return ctx;
}

void gdscript_schema_context_free(gdscript_schema_context_t* ctx) {
    if (!ctx) return;
    
    /* Free child contexts */
    if (ctx->children) {
        for (int i = 0; i < ctx->child_count; i++) {
            gdscript_schema_context_free(&ctx->children[i]);
        }
        free(ctx->children);
    }
    
    /* Free vtable */
    if (ctx->vtable) {
        colyseus_dynamic_vtable_free(ctx->vtable);
    }
    
    /* Free name */
    free(ctx->name);
    
    /* Note: script_class is owned by Godot, don't free it */
    
    free(ctx);
}

colyseus_dynamic_vtable_t* gdscript_schema_parse_class(GDExtensionConstVariantPtr script_variant) {
    gdscript_schema_context_t* ctx = gdscript_schema_context_create(script_variant);
    if (!ctx) return NULL;
    
    colyseus_dynamic_vtable_t* vtable = ctx->vtable;
    
    /* Transfer ownership of vtable, free context without vtable */
    ctx->vtable = NULL;
    gdscript_schema_context_free(ctx);
    
    return vtable;
}

/* ============================================================================
 * Instance Creation Callbacks
 * ============================================================================ */

void* gdscript_create_instance(const colyseus_dynamic_vtable_t* vtable, void* context) {
    if (!context) return NULL;
    
    GDExtensionObjectPtr script_class = (GDExtensionObjectPtr)context;
    
    /* Create a variant from the script class */
    Variant script_variant;
    constructors.variant_from_object_constructor(&script_variant, &script_class);
    
    /* Call new() to create an instance */
    Variant instance_variant;
    if (!variant_call_method(&script_variant, "new", NULL, 0, &instance_variant)) {
        printf("[GDScriptSchema] Failed to call new() on script class\n");
        fflush(stdout);
        destructors.variant_destroy(&script_variant);
        return NULL;
    }
    
    destructors.variant_destroy(&script_variant);
    
    /* Get the Object pointer from the instance variant */
    GDExtensionObjectPtr instance_obj = NULL;
    constructors.object_from_variant_constructor(&instance_obj, &instance_variant);
    
    /* We need to keep the variant alive or properly ref the object */
    /* For now, return the variant as userdata (it holds the reference) */
    Variant* result = malloc(sizeof(Variant));
    if (result) {
        api.variant_new_copy(result, &instance_variant);
    }
    
    destructors.variant_destroy(&instance_variant);
    
    printf("[GDScriptSchema] Created GDScript instance: %p\n", (void*)result);
    fflush(stdout);
    
    return result;
}

void gdscript_free_instance(void* userdata) {
    if (!userdata) return;
    
    Variant* instance_variant = (Variant*)userdata;
    destructors.variant_destroy(instance_variant);
    free(instance_variant);
}

void gdscript_set_field(void* userdata, const char* name, colyseus_dynamic_value_t* value) {
    if (!userdata || !name || !value) return;
    
    Variant* instance_variant = (Variant*)userdata;
    
    /* Convert the dynamic value to a Godot Variant */
    Variant value_variant;
    gdscript_value_to_variant(value, &value_variant);
    
    /* Call _set_field(name, value) on the GDScript instance */
    String name_str;
    constructors.string_new_with_utf8_chars(&name_str, name);
    Variant name_variant;
    constructors.variant_from_string_constructor(&name_variant, &name_str);
    
    GDExtensionConstVariantPtr args[2] = { &name_variant, &value_variant };
    Variant result;
    
    variant_call_method(instance_variant, "_set_field", args, 2, &result);
    
    destructors.variant_destroy(&result);
    destructors.variant_destroy(&name_variant);
    destructors.string_destructor(&name_str);
    destructors.variant_destroy(&value_variant);
}

/* ============================================================================
 * Value Conversion
 * ============================================================================ */

/* Forward declare helper to convert a raw value to variant based on vtable */
static void raw_value_to_variant(void* raw_value, bool has_schema_child, 
    const colyseus_schema_vtable_t* child_vtable, const char* child_primitive_type,
    Variant* r_variant);

/* Callback context for map iteration */
typedef struct {
    Variant* map_instance;
} map_populate_ctx_t;

/* Callback for populating GDScript Map */
static void populate_map_callback(const char* key, void* value, void* userdata) {
    map_populate_ctx_t* ctx = (map_populate_ctx_t*)userdata;
    if (!ctx || !ctx->map_instance || !key) return;
    
    /* Get the map schema to determine child type */
    /* For now, assume schema children have userdata */
    colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)value;
    
    Variant value_variant;
    if (dyn_schema && dyn_schema->userdata) {
        /* Schema child - get the GDScript instance */
        api.variant_new_copy(&value_variant, (Variant*)dyn_schema->userdata);
    } else {
        /* Primitive or null - try to convert */
        memset(&value_variant, 0, sizeof(value_variant));
    }
    
    gdscript_map_set_item(ctx->map_instance, key, &value_variant);
    destructors.variant_destroy(&value_variant);
}

/* Callback context for array iteration */
typedef struct {
    Variant* array_instance;
} array_populate_ctx_t;

/* Callback for populating GDScript ArraySchema */
static void populate_array_callback(int index, void* value, void* userdata) {
    array_populate_ctx_t* ctx = (array_populate_ctx_t*)userdata;
    if (!ctx || !ctx->array_instance) return;
    
    /* Get the array schema to determine child type */
    colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)value;
    
    Variant value_variant;
    if (dyn_schema && dyn_schema->userdata) {
        /* Schema child - get the GDScript instance */
        api.variant_new_copy(&value_variant, (Variant*)dyn_schema->userdata);
    } else {
        /* Primitive or null - try to convert */
        memset(&value_variant, 0, sizeof(value_variant));
    }
    
    gdscript_array_set_at(ctx->array_instance, index, &value_variant);
    destructors.variant_destroy(&value_variant);
}

void gdscript_value_to_variant(colyseus_dynamic_value_t* value, Variant* r_variant) {
    if (!value || !r_variant) return;
    
    switch (value->type) {
        case COLYSEUS_FIELD_STRING: {
            String str;
            constructors.string_new_with_utf8_chars(&str, value->data.str ? value->data.str : "");
            constructors.variant_from_string_constructor(r_variant, &str);
            destructors.string_destructor(&str);
            break;
        }
        
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT64: {
            constructors.variant_from_float_constructor(r_variant, &value->data.num);
            break;
        }
        
        case COLYSEUS_FIELD_FLOAT32: {
            double d = (double)value->data.f32;
            constructors.variant_from_float_constructor(r_variant, &d);
            break;
        }
        
        case COLYSEUS_FIELD_BOOLEAN: {
            GDExtensionBool b = value->data.boolean ? 1 : 0;
            constructors.variant_from_bool_constructor(r_variant, &b);
            break;
        }
        
        case COLYSEUS_FIELD_INT8:
        case COLYSEUS_FIELD_INT16:
        case COLYSEUS_FIELD_INT32: {
            int64_t i = value->data.i32;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        
        case COLYSEUS_FIELD_INT64: {
            constructors.variant_from_int_constructor(r_variant, &value->data.i64);
            break;
        }
        
        case COLYSEUS_FIELD_UINT8:
        case COLYSEUS_FIELD_UINT16:
        case COLYSEUS_FIELD_UINT32: {
            int64_t i = value->data.u32;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        
        case COLYSEUS_FIELD_UINT64: {
            int64_t i = (int64_t)value->data.u64;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        
        case COLYSEUS_FIELD_REF: {
            /* For ref types, the value is a dynamic schema with a GDScript userdata */
            if (value->data.ref && value->data.ref->userdata) {
                Variant* instance_variant = (Variant*)value->data.ref->userdata;
                api.variant_new_copy(r_variant, instance_variant);
            } else {
                /* Null ref */
                memset(r_variant, 0, sizeof(Variant));
            }
            break;
        }
        
        case COLYSEUS_FIELD_MAP: {
            /* Create a GDScript Map and populate it */
            colyseus_map_schema_t* map = value->data.map;
            if (!map) {
                memset(r_variant, 0, sizeof(Variant));
                break;
            }
            
            Variant* map_instance = gdscript_create_map_instance(NULL);
            if (!map_instance) {
                memset(r_variant, 0, sizeof(Variant));
                break;
            }
            
            /* Populate the map with items */
            map_populate_ctx_t ctx = { .map_instance = map_instance };
            colyseus_map_schema_foreach(map, populate_map_callback, &ctx);
            
            /* Return the map instance */
            api.variant_new_copy(r_variant, map_instance);
            
            /* Free the temporary map instance holder */
            destructors.variant_destroy(map_instance);
            free(map_instance);
            break;
        }
        
        case COLYSEUS_FIELD_ARRAY: {
            /* Create a GDScript ArraySchema and populate it */
            colyseus_array_schema_t* arr = value->data.array;
            if (!arr) {
                memset(r_variant, 0, sizeof(Variant));
                break;
            }
            
            Variant* array_instance = gdscript_create_array_instance(NULL);
            if (!array_instance) {
                memset(r_variant, 0, sizeof(Variant));
                break;
            }
            
            /* Populate the array with items */
            array_populate_ctx_t ctx = { .array_instance = array_instance };
            colyseus_array_schema_foreach(arr, populate_array_callback, &ctx);
            
            /* Return the array instance */
            api.variant_new_copy(r_variant, array_instance);
            
            /* Free the temporary array instance holder */
            destructors.variant_destroy(array_instance);
            free(array_instance);
            break;
        }
        
        default: {
            /* Unknown type - return nil */
            memset(r_variant, 0, sizeof(Variant));
            break;
        }
    }
}

/* ============================================================================
 * Collection Helpers
 * 
 * For collections (Map and ArraySchema), we use native Godot Dictionary and Array
 * instead of trying to instantiate GDScript classes from C. This gives good 
 * interoperability while avoiding the complexity of loading GDScript modules
 * from C code.
 * ============================================================================ */

Variant* gdscript_create_map_instance(GDExtensionObjectPtr child_class) {
    (void)child_class;  /* Reserved for future typed map support */
    
    /* Create a Godot Dictionary to hold map items */
    Dictionary dict;
    constructors.dictionary_constructor(&dict, NULL);
    
    /* Wrap in a Variant and return */
    Variant* result = malloc(sizeof(Variant));
    if (result) {
        constructors.variant_from_dictionary_constructor(result, &dict);
    }
    destructors.dictionary_destructor(&dict);
    
    return result;
}

Variant* gdscript_create_array_instance(GDExtensionObjectPtr child_class) {
    (void)child_class;  /* Reserved for future typed array support */
    
    /* Create a Godot Array to hold array items */
    Array arr;
    constructors.array_constructor(&arr, NULL);
    
    /* Wrap in a Variant and return */
    Variant* result = malloc(sizeof(Variant));
    if (result) {
        constructors.variant_from_array_constructor(result, &arr);
    }
    destructors.array_destructor(&arr);
    
    return result;
}

void gdscript_map_set_item(Variant* map_variant, const char* key, Variant* value_variant) {
    if (!map_variant || !key || !value_variant) return;
    
    /* Get Dictionary from variant */
    Dictionary dict;
    constructors.dictionary_from_variant_constructor(&dict, map_variant);
    
    /* Create key variant */
    String key_str;
    constructors.string_new_with_utf8_chars(&key_str, key);
    Variant key_var;
    constructors.variant_from_string_constructor(&key_var, &key_str);
    
    /* Set item using dictionary_operator_index */
    Variant* slot = api.dictionary_operator_index(&dict, &key_var);
    if (slot) {
        api.variant_new_copy(slot, value_variant);
    }
    
    /* Update the original variant with the modified dictionary */
    constructors.variant_from_dictionary_constructor(map_variant, &dict);
    
    destructors.variant_destroy(&key_var);
    destructors.string_destructor(&key_str);
    destructors.dictionary_destructor(&dict);
}

void gdscript_map_remove_item(Variant* map_variant, const char* key) {
    if (!map_variant || !key) return;
    
    /* Get Dictionary from variant and call erase */
    String key_str;
    constructors.string_new_with_utf8_chars(&key_str, key);
    Variant key_var;
    constructors.variant_from_string_constructor(&key_var, &key_str);
    
    GDExtensionConstVariantPtr args[1] = { &key_var };
    Variant result;
    
    variant_call_method(map_variant, "erase", args, 1, &result);
    
    destructors.variant_destroy(&result);
    destructors.variant_destroy(&key_var);
    destructors.string_destructor(&key_str);
}

void gdscript_array_set_at(Variant* array_variant, int index, Variant* value_variant) {
    if (!array_variant || !value_variant) return;
    
    /* Get Array from variant */
    Array arr;
    constructors.array_from_variant_constructor(&arr, array_variant);
    
    /* Resize array if needed and set the value */
    /* First, get current size */
    Variant size_result;
    variant_call_method(array_variant, "size", NULL, 0, &size_result);
    int64_t current_size = 0;
    constructors.int_from_variant_constructor(&current_size, &size_result);
    destructors.variant_destroy(&size_result);
    
    /* Resize if index is beyond current size */
    if (index >= current_size) {
        int64_t new_size = index + 1;
        Variant new_size_var;
        constructors.variant_from_int_constructor(&new_size_var, &new_size);
        GDExtensionConstVariantPtr resize_args[1] = { &new_size_var };
        Variant resize_result;
        variant_call_method(array_variant, "resize", resize_args, 1, &resize_result);
        destructors.variant_destroy(&resize_result);
        destructors.variant_destroy(&new_size_var);
    }
    
    /* Set the value at index using operator[] */
    int64_t idx = index;
    Variant* slot = api.array_operator_index(&arr, idx);
    if (slot) {
        api.variant_new_copy(slot, value_variant);
    }
    
    /* Update the original variant */
    constructors.variant_from_array_constructor(array_variant, &arr);
    
    destructors.array_destructor(&arr);
}

void gdscript_array_push(Variant* array_variant, Variant* value_variant) {
    if (!array_variant || !value_variant) return;
    
    /* Call push_back on the array */
    GDExtensionConstVariantPtr args[1] = { value_variant };
    Variant result;
    
    variant_call_method(array_variant, "push_back", args, 1, &result);
    
    destructors.variant_destroy(&result);
}
