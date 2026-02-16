#include "colyseus_callbacks.h"
#include "colyseus_state.h"
#include <colyseus/room.h>
#include <colyseus/schema.h>
#include <colyseus/schema/ref_tracker.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Storage for the last created wrapper (for factory method)
static ColyseusCallbacksWrapper* g_last_created_callbacks_wrapper = NULL;

// ============================================================================
// Helper functions
// ============================================================================

static char* strdup_safe(const char* str) {
    if (!str) return NULL;
    size_t len = strlen(str) + 1;
    char* dup = (char*)malloc(len);
    if (dup) memcpy(dup, str, len);
    return dup;
}

// Helper to extract C string from a Godot String variant
static char* variant_string_to_c_str(GDExtensionConstVariantPtr var) {
    // First extract String from Variant
    String str;
    constructors.string_from_variant_constructor(&str, (GDExtensionVariantPtr)var);
    
    // Then convert to C string
    int32_t length = api.string_to_utf8_chars(&str, NULL, 0);
    if (length <= 0) {
        destructors.string_destructor(&str);
        return strdup_safe("");
    }
    
    char* buffer = (char*)malloc(length + 1);
    if (!buffer) {
        destructors.string_destructor(&str);
        return strdup_safe("");
    }
    
    api.string_to_utf8_chars(&str, buffer, length);
    buffer[length] = '\0';
    
    destructors.string_destructor(&str);
    return buffer;
}

// Helper to extract int64 from a Variant
static int64_t variant_to_int64(GDExtensionConstVariantPtr var) {
    int64_t result = 0;
    constructors.int_from_variant_constructor(&result, (GDExtensionVariantPtr)var);
    return result;
}

// Find a free entry slot
static GodotCallbackEntry* find_free_entry(ColyseusCallbacksWrapper* wrapper) {
    for (int i = 0; i < COLYSEUS_MAX_CALLBACK_ENTRIES; i++) {
        if (!wrapper->entries[i].active) {
            return &wrapper->entries[i];
        }
    }
    return NULL;
}

// Find entry by handle
static GodotCallbackEntry* find_entry_by_handle(ColyseusCallbacksWrapper* wrapper, int handle) {
    for (int i = 0; i < COLYSEUS_MAX_CALLBACK_ENTRIES; i++) {
        if (wrapper->entries[i].active && wrapper->entries[i].handle == handle) {
            return &wrapper->entries[i];
        }
    }
    return NULL;
}

// ============================================================================
// Trampoline functions - Called by native SDK, invoke GDScript Callables
// ============================================================================

// Helper to convert a native value to Variant based on field type
static void native_value_to_variant(void* value, int field_type, const colyseus_schema_vtable_t* item_vtable, Variant* out_variant) {
    if (!value) {
        memset(out_variant, 0, sizeof(Variant));
        return;
    }
    
    switch (field_type) {
        case COLYSEUS_FIELD_STRING: {
            // value is char* directly
            const char* str = (const char*)value;
            if (str) {
                String godot_str;
                constructors.string_new_with_utf8_chars(&godot_str, str);
                constructors.variant_from_string_constructor(out_variant, &godot_str);
                destructors.string_destructor(&godot_str);
            } else {
                memset(out_variant, 0, sizeof(Variant));
            }
            break;
        }
        case COLYSEUS_FIELD_INT8:
        case COLYSEUS_FIELD_INT16:
        case COLYSEUS_FIELD_INT32:
        case COLYSEUS_FIELD_INT64: {
            // value points to the integer
            int64_t int_val = 0;
            switch (field_type) {
                case COLYSEUS_FIELD_INT8:  int_val = *(int8_t*)value; break;
                case COLYSEUS_FIELD_INT16: int_val = *(int16_t*)value; break;
                case COLYSEUS_FIELD_INT32: int_val = *(int32_t*)value; break;
                case COLYSEUS_FIELD_INT64: int_val = *(int64_t*)value; break;
            }
            constructors.variant_from_int_constructor(out_variant, &int_val);
            break;
        }
        case COLYSEUS_FIELD_UINT8:
        case COLYSEUS_FIELD_UINT16:
        case COLYSEUS_FIELD_UINT32:
        case COLYSEUS_FIELD_UINT64: {
            int64_t int_val = 0;
            switch (field_type) {
                case COLYSEUS_FIELD_UINT8:  int_val = *(uint8_t*)value; break;
                case COLYSEUS_FIELD_UINT16: int_val = *(uint16_t*)value; break;
                case COLYSEUS_FIELD_UINT32: int_val = *(uint32_t*)value; break;
                case COLYSEUS_FIELD_UINT64: int_val = (int64_t)*(uint64_t*)value; break;
            }
            constructors.variant_from_int_constructor(out_variant, &int_val);
            break;
        }
        case COLYSEUS_FIELD_FLOAT32: {
            double float_val = *(float*)value;
            constructors.variant_from_float_constructor(out_variant, &float_val);
            break;
        }
        case COLYSEUS_FIELD_FLOAT64: {
            double float_val = *(double*)value;
            constructors.variant_from_float_constructor(out_variant, &float_val);
            break;
        }
        case COLYSEUS_FIELD_BOOLEAN: {
            int64_t bool_val = *(bool*)value ? 1 : 0;
            constructors.variant_from_bool_constructor(out_variant, (GDExtensionBool*)&bool_val);
            break;
        }
        case COLYSEUS_FIELD_REF: {
            // value is schema pointer
            colyseus_schema_t* schema = (colyseus_schema_t*)value;
            const colyseus_schema_vtable_t* vtable = item_vtable ? item_vtable : schema->__vtable;
            if (schema && vtable) {
                Dictionary dict;
                constructors.dictionary_constructor(&dict, NULL);
                colyseus_schema_to_dictionary(schema, vtable, &dict);
                constructors.variant_from_dictionary_constructor(out_variant, &dict);
            } else {
                memset(out_variant, 0, sizeof(Variant));
            }
            break;
        }
        default:
            memset(out_variant, 0, sizeof(Variant));
            break;
    }
}

static void property_change_trampoline(void* value, void* previous_value, void* userdata) {
    GodotCallbackEntry* entry = (GodotCallbackEntry*)userdata;
    if (!entry || !entry->active) return;
    
    printf("[ColyseusCallbacks] Property change: %s (value=%p, prev=%p, type=%d)\n", 
           entry->property ? entry->property : "(unknown)", value, previous_value, entry->field_type);
    fflush(stdout);
    
    // Create Variant arguments for the callable
    Variant current_variant;
    Variant previous_variant;
    
    native_value_to_variant(value, entry->field_type, entry->item_vtable, &current_variant);
    native_value_to_variant(previous_value, entry->field_type, entry->item_vtable, &previous_variant);
    
    // Call the "call" method on the Callable variant
    StringName call_method;
    constructors.string_name_new_with_latin1_chars(&call_method, "call", false);
    
    GDExtensionConstVariantPtr arg_ptrs[2] = { &current_variant, &previous_variant };
    Variant return_value;
    GDExtensionCallError error;
    
    api.variant_call((GDExtensionVariantPtr)&entry->callable, &call_method, arg_ptrs, 2, &return_value, &error);
    
    destructors.string_name_destructor(&call_method);
    
    if (error.error != GDEXTENSION_CALL_OK) {
        printf("[ColyseusCallbacks] Error calling property callback: %d (arg_expected=%d)\n", 
               error.error, error.expected);
        fflush(stdout);
    } else {
        printf("[ColyseusCallbacks] Property callback invoked successfully\n");
        fflush(stdout);
    }
    
    destructors.variant_destroy(&return_value);
    destructors.variant_destroy(&current_variant);
    destructors.variant_destroy(&previous_variant);
}

static void item_add_trampoline(void* value, void* key, void* userdata) {
    GodotCallbackEntry* entry = (GodotCallbackEntry*)userdata;
    if (!entry || !entry->active) return;
    
    printf("[ColyseusCallbacks] Item add: %s (value=%p, key=%p, field_type=%d)\n",
           entry->property ? entry->property : "(unknown)", value, key, entry->field_type);
    fflush(stdout);
    
    // Create Variant arguments
    Variant value_variant;
    Variant key_variant;
    
    // Convert value (schema) to Dictionary
    if (value) {
        colyseus_schema_t* schema = (colyseus_schema_t*)value;
        const colyseus_schema_vtable_t* vtable = entry->item_vtable ? entry->item_vtable : schema->__vtable;
        if (vtable) {
            // Create Dictionary and convert schema
            Dictionary dict;
            constructors.dictionary_constructor(&dict, NULL);
            colyseus_schema_to_dictionary(schema, vtable, &dict);
            constructors.variant_from_dictionary_constructor(&value_variant, &dict);
        } else {
            // No vtable, create nil variant
            memset(&value_variant, 0, sizeof(Variant));
        }
    } else {
        memset(&value_variant, 0, sizeof(Variant));
    }
    
    // Convert key based on collection type
    if (key) {
        if (entry->field_type == COLYSEUS_FIELD_ARRAY) {
            // For arrays, key is int* (pointer to index)
            int64_t index = *(int*)key;
            constructors.variant_from_int_constructor(&key_variant, &index);
        } else {
            // For maps, key is char* string
            const char* key_str = (const char*)key;
            String godot_key;
            constructors.string_new_with_utf8_chars(&godot_key, key_str);
            constructors.variant_from_string_constructor(&key_variant, &godot_key);
            destructors.string_destructor(&godot_key);
        }
    } else {
        memset(&key_variant, 0, sizeof(Variant));
    }
    
    // Call the "call" method on the Callable variant
    StringName call_method;
    constructors.string_name_new_with_latin1_chars(&call_method, "call", false);
    
    GDExtensionConstVariantPtr arg_ptrs[2] = { &value_variant, &key_variant };
    Variant return_value;
    GDExtensionCallError error;
    
    api.variant_call((GDExtensionVariantPtr)&entry->callable, &call_method, arg_ptrs, 2, &return_value, &error);
    
    destructors.string_name_destructor(&call_method);
    
    if (error.error != GDEXTENSION_CALL_OK) {
        printf("[ColyseusCallbacks] Error calling on_add callback: %d\n", error.error);
        fflush(stdout);
    } else {
        printf("[ColyseusCallbacks] on_add callback invoked successfully\n");
        fflush(stdout);
    }
    
    destructors.variant_destroy(&return_value);
    destructors.variant_destroy(&value_variant);
    destructors.variant_destroy(&key_variant);
}

static void item_remove_trampoline(void* value, void* key, void* userdata) {
    GodotCallbackEntry* entry = (GodotCallbackEntry*)userdata;
    if (!entry || !entry->active) return;
    
    printf("[ColyseusCallbacks] Item remove: %s (value=%p, key=%p, field_type=%d)\n",
           entry->property ? entry->property : "(unknown)", value, key, entry->field_type);
    fflush(stdout);
    
    // Create Variant arguments
    Variant value_variant;
    Variant key_variant;
    
    // Convert value (schema) to Dictionary
    if (value) {
        colyseus_schema_t* schema = (colyseus_schema_t*)value;
        const colyseus_schema_vtable_t* vtable = entry->item_vtable ? entry->item_vtable : schema->__vtable;
        if (vtable) {
            Dictionary dict;
            constructors.dictionary_constructor(&dict, NULL);
            colyseus_schema_to_dictionary(schema, vtable, &dict);
            constructors.variant_from_dictionary_constructor(&value_variant, &dict);
        } else {
            memset(&value_variant, 0, sizeof(Variant));
        }
    } else {
        memset(&value_variant, 0, sizeof(Variant));
    }
    
    // Convert key based on collection type
    if (key) {
        if (entry->field_type == COLYSEUS_FIELD_ARRAY) {
            // For arrays, key is int* (pointer to index)
            int64_t index = *(int*)key;
            constructors.variant_from_int_constructor(&key_variant, &index);
        } else {
            // For maps, key is char* string
            const char* key_str = (const char*)key;
            String godot_key;
            constructors.string_new_with_utf8_chars(&godot_key, key_str);
            constructors.variant_from_string_constructor(&key_variant, &godot_key);
            destructors.string_destructor(&godot_key);
        }
    } else {
        memset(&key_variant, 0, sizeof(Variant));
    }
    
    // Call the "call" method on the Callable variant
    StringName call_method;
    constructors.string_name_new_with_latin1_chars(&call_method, "call", false);
    
    GDExtensionConstVariantPtr arg_ptrs[2] = { &value_variant, &key_variant };
    Variant return_value;
    GDExtensionCallError error;
    
    api.variant_call((GDExtensionVariantPtr)&entry->callable, &call_method, arg_ptrs, 2, &return_value, &error);
    
    destructors.string_name_destructor(&call_method);
    
    if (error.error != GDEXTENSION_CALL_OK) {
        printf("[ColyseusCallbacks] Error calling on_remove callback: %d\n", error.error);
        fflush(stdout);
    } else {
        printf("[ColyseusCallbacks] on_remove callback invoked successfully\n");
        fflush(stdout);
    }
    
    destructors.variant_destroy(&return_value);
    destructors.variant_destroy(&value_variant);
    destructors.variant_destroy(&key_variant);
}

// ============================================================================
// Constructor/Destructor
// ============================================================================

GDExtensionObjectPtr gdext_colyseus_callbacks_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    
    // Create the Godot Object (construct parent RefCounted class)
    StringName parent_class_name;
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);
    
    GDExtensionObjectPtr object = api.classdb_construct_object(&parent_class_name);
    destructors.string_name_destructor(&parent_class_name);
    
    if (!object) return NULL;
    
    // Create our wrapper instance data
    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)calloc(1, sizeof(ColyseusCallbacksWrapper));
    if (!wrapper) return NULL;
    
    wrapper->native_callbacks = NULL;
    wrapper->room_wrapper = NULL;
    wrapper->godot_object = object;
    wrapper->entry_count = 0;
    
    // Initialize all entries as inactive
    for (int i = 0; i < COLYSEUS_MAX_CALLBACK_ENTRIES; i++) {
        wrapper->entries[i].active = false;
        wrapper->entries[i].property = NULL;
    }
    
    // Attach our wrapper to the Godot object
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusCallbacks", false);
    api.object_set_instance(object, &class_name, wrapper);
    destructors.string_name_destructor(&class_name);
    
    // Store for retrieval by factory method
    g_last_created_callbacks_wrapper = wrapper;
    
    printf("[ColyseusCallbacks] Constructor called, wrapper=%p\n", (void*)wrapper);
    fflush(stdout);
    
    return object;
}

void gdext_colyseus_callbacks_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    
    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance;
    if (!wrapper) return;
    
    printf("[ColyseusCallbacks] Destructor called, wrapper=%p\n", (void*)wrapper);
    fflush(stdout);
    
    // Free all callback entries
    for (int i = 0; i < COLYSEUS_MAX_CALLBACK_ENTRIES; i++) {
        if (wrapper->entries[i].active) {
            if (wrapper->entries[i].property) {
                free(wrapper->entries[i].property);
            }
            // Destroy the callable variant
            destructors.variant_destroy(&wrapper->entries[i].callable);
        }
    }
    
    // Free native callbacks (must be done before room is freed)
    if (wrapper->native_callbacks) {
        colyseus_callbacks_free(wrapper->native_callbacks);
    }
    
    free(wrapper);
}

ColyseusCallbacksWrapper* gdext_colyseus_callbacks_get_last_wrapper(void) {
    ColyseusCallbacksWrapper* wrapper = g_last_created_callbacks_wrapper;
    g_last_created_callbacks_wrapper = NULL;
    return wrapper;
}

void gdext_colyseus_callbacks_init_with_room(
    ColyseusCallbacksWrapper* wrapper,
    ColyseusRoomWrapper* room_wrapper
) {
    if (!wrapper || !room_wrapper) return;
    
    wrapper->room_wrapper = room_wrapper;
    
    printf("[ColyseusCallbacks] init_with_room: room_wrapper=%p, native_room=%p\n",
           (void*)room_wrapper, (void*)(room_wrapper ? room_wrapper->native_room : NULL));
    fflush(stdout);
    
    // Get the decoder from the room's serializer
    if (room_wrapper->native_room) {
        printf("[ColyseusCallbacks]   serializer=%p\n", 
               (void*)room_wrapper->native_room->serializer);
        fflush(stdout);
        
        if (room_wrapper->native_room->serializer) {
            printf("[ColyseusCallbacks]   decoder=%p\n", 
                   (void*)room_wrapper->native_room->serializer->decoder);
            fflush(stdout);
            
            if (room_wrapper->native_room->serializer->decoder) {
                wrapper->native_callbacks = colyseus_callbacks_create(
                    room_wrapper->native_room->serializer->decoder
                );
                
                printf("[ColyseusCallbacks] Initialized with room, native_callbacks=%p\n", 
                       (void*)wrapper->native_callbacks);
                fflush(stdout);
                return;
            }
        }
    }
    
    printf("[ColyseusCallbacks] Warning: Room has no serializer/decoder yet\n");
    fflush(stdout);
}

// ============================================================================
// Static factory method: ColyseusCallbacks.get(room)
// ============================================================================

void gdext_colyseus_callbacks_get(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
) {
    (void)p_method_userdata;
    (void)p_instance;  // NULL for static methods
    
    printf("[ColyseusCallbacks] get() called with %lld args\n", (long long)p_argument_count);
    fflush(stdout);
    
    if (p_argument_count < 1) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        return;
    }
    
    // Extract the room object from the variant
    GDExtensionObjectPtr room_obj = NULL;
    constructors.object_from_variant_constructor(&room_obj, (GDExtensionVariantPtr)p_args[0]);
    
    if (!room_obj) {
        printf("[ColyseusCallbacks] get() - room object is null\n");
        fflush(stdout);
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        return;
    }
    
    // Get the room's instance ID and look up the wrapper from our registry
    GDObjectInstanceID room_instance_id = api.object_get_instance_id(room_obj);
    printf("[ColyseusCallbacks] Room instance ID: %llu\n", (unsigned long long)room_instance_id);
    fflush(stdout);
    
    // Look up the room wrapper from our global registry
    ColyseusRoomWrapper* room_wrapper = gdext_colyseus_room_get_wrapper_by_id(room_instance_id);
    
    printf("[ColyseusCallbacks] Room wrapper from registry: %p\n", (void*)room_wrapper);
    fflush(stdout);
    
    // Create a new ColyseusCallbacks instance
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusCallbacks", false);
    GDExtensionObjectPtr callbacks_obj = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);
    
    if (!callbacks_obj) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INVALID_METHOD;
        return;
    }
    
    // Get the wrapper that was just created
    ColyseusCallbacksWrapper* wrapper = gdext_colyseus_callbacks_get_last_wrapper();
    
    // Initialize with the room - try to get room_wrapper from the object directly
    // Since object_get_instance_binding may not work for our custom instance data,
    // we need a different approach. Let's store a global mapping or use a different method.
    
    // For now, let's try to initialize if we have room info
    if (wrapper && room_wrapper) {
        gdext_colyseus_callbacks_init_with_room(wrapper, room_wrapper);
    } else if (wrapper) {
        printf("[ColyseusCallbacks] Could not get room wrapper, callbacks will not work properly\n");
        fflush(stdout);
    }
    
    // Return the callbacks object as a variant
    if (r_return) {
        constructors.variant_from_object_constructor(r_return, &callbacks_obj);
    }
}

// ============================================================================
// Instance methods
// ============================================================================

void gdext_colyseus_callbacks_listen(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
) {
    (void)p_method_userdata;
    
    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance;
    if (!wrapper) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL;
        return;
    }
    
    printf("[ColyseusCallbacks] listen() called with %lld args\n", (long long)p_argument_count);
    fflush(stdout);
    
    if (p_argument_count < 2) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        return;
    }
    
    // Determine argument pattern based on first arg type
    GDExtensionVariantType first_arg_type = api.variant_get_type(p_args[0]);
    
    void* instance = NULL;
    char* property_name = NULL;
    GDExtensionConstVariantPtr callable_arg = NULL;
    
    if (first_arg_type == GDEXTENSION_VARIANT_TYPE_STRING) {
        // listen("property", callback) - root state
        property_name = variant_string_to_c_str(p_args[0]);
        callable_arg = p_args[1];
        
        // Get root state
        if (wrapper->room_wrapper && wrapper->room_wrapper->native_room) {
            instance = colyseus_room_get_state(wrapper->room_wrapper->native_room);
        }
        
        printf("[ColyseusCallbacks] listen() on root state property: %s, instance=%p\n", 
               property_name, instance);
        fflush(stdout);
        
    } else if (first_arg_type == GDEXTENSION_VARIANT_TYPE_DICTIONARY) {
        // listen(schema_dict, "property", callback) - nested schema
        if (p_argument_count < 3) {
            if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
            return;
        }
        
        // Extract ref_id from dictionary
        int ref_id = colyseus_extract_ref_id(p_args[0]);
        property_name = variant_string_to_c_str(p_args[1]);
        callable_arg = p_args[2];
        
        // Look up instance by ref_id
        if (wrapper->room_wrapper && wrapper->room_wrapper->native_room &&
            wrapper->room_wrapper->native_room->serializer &&
            wrapper->room_wrapper->native_room->serializer->decoder) {
            
            colyseus_ref_tracker_t* refs = 
                wrapper->room_wrapper->native_room->serializer->decoder->refs;
            if (refs) {
                instance = colyseus_ref_tracker_get(refs, ref_id);
            }
        }
        
        printf("[ColyseusCallbacks] listen() on nested schema ref_id=%d, property: %s, instance=%p\n", 
               ref_id, property_name, instance);
        fflush(stdout);
        
    } else {
        printf("[ColyseusCallbacks] listen() - invalid first argument type: %d\n", first_arg_type);
        fflush(stdout);
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        return;
    }
    
    // Find a free entry
    GodotCallbackEntry* entry = find_free_entry(wrapper);
    if (!entry) {
        printf("[ColyseusCallbacks] Error: No free callback entries\n");
        fflush(stdout);
        if (property_name) free(property_name);
        int64_t result = -1;
        if (r_return) constructors.variant_from_int_constructor(r_return, &result);
        return;
    }
    
    // Set up entry
    entry->active = true;
    entry->type = COLYSEUS_GDCB_LISTEN;
    entry->property = property_name;
    entry->ref_id = (first_arg_type == GDEXTENSION_VARIANT_TYPE_DICTIONARY) ? 
                    colyseus_extract_ref_id(p_args[0]) : 0;
    entry->field_type = COLYSEUS_FIELD_STRING;  // Default
    entry->item_vtable = NULL;
    
    // Look up field type from instance's vtable
    if (instance && property_name) {
        colyseus_schema_t* schema = (colyseus_schema_t*)instance;
        if (schema->__vtable) {
            for (int i = 0; i < schema->__vtable->field_count; i++) {
                if (strcmp(schema->__vtable->fields[i].name, property_name) == 0) {
                    entry->field_type = schema->__vtable->fields[i].type;
                    entry->item_vtable = schema->__vtable->fields[i].child_vtable;
                    printf("[ColyseusCallbacks] Found field '%s' with type %d\n", 
                           property_name, entry->field_type);
                    fflush(stdout);
                    break;
                }
            }
        }
    }
    
    // Copy the callable variant (properly increments reference count)
    api.variant_new_copy(&entry->callable, callable_arg);
    
    // Register with native callbacks if available
    if (wrapper->native_callbacks && instance && property_name) {
        entry->handle = colyseus_callbacks_listen(
            wrapper->native_callbacks,
            instance,
            property_name,
            property_change_trampoline,
            entry,  // userdata
            true    // immediate
        );
        
        printf("[ColyseusCallbacks] Registered native listen callback, handle=%d\n", entry->handle);
        fflush(stdout);
    } else {
        entry->handle = wrapper->entry_count;
        printf("[ColyseusCallbacks] Native callbacks not available, using local handle=%d\n", entry->handle);
        fflush(stdout);
    }
    
    wrapper->entry_count++;
    
    // Return handle
    int64_t handle = entry->handle;
    if (r_return) constructors.variant_from_int_constructor(r_return, &handle);
}

void gdext_colyseus_callbacks_on_add(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
) {
    (void)p_method_userdata;
    
    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance;
    if (!wrapper) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL;
        return;
    }
    
    printf("[ColyseusCallbacks] on_add() called with %lld args\n", (long long)p_argument_count);
    fflush(stdout);
    
    if (p_argument_count < 2) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        return;
    }
    
    // Similar logic to listen()
    GDExtensionVariantType first_arg_type = api.variant_get_type(p_args[0]);
    
    void* instance = NULL;
    char* property_name = NULL;
    GDExtensionConstVariantPtr callable_arg = NULL;
    
    if (first_arg_type == GDEXTENSION_VARIANT_TYPE_STRING) {
        property_name = variant_string_to_c_str(p_args[0]);
        callable_arg = p_args[1];
        
        if (wrapper->room_wrapper && wrapper->room_wrapper->native_room) {
            instance = colyseus_room_get_state(wrapper->room_wrapper->native_room);
        }
        
    } else if (first_arg_type == GDEXTENSION_VARIANT_TYPE_DICTIONARY) {
        if (p_argument_count < 3) {
            if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
            return;
        }
        
        int ref_id = colyseus_extract_ref_id(p_args[0]);
        property_name = variant_string_to_c_str(p_args[1]);
        callable_arg = p_args[2];
        
        if (wrapper->room_wrapper && wrapper->room_wrapper->native_room &&
            wrapper->room_wrapper->native_room->serializer &&
            wrapper->room_wrapper->native_room->serializer->decoder) {
            
            colyseus_ref_tracker_t* refs = 
                wrapper->room_wrapper->native_room->serializer->decoder->refs;
            if (refs) {
                instance = colyseus_ref_tracker_get(refs, ref_id);
            }
        }
    } else {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        return;
    }
    
    GodotCallbackEntry* entry = find_free_entry(wrapper);
    if (!entry) {
        if (property_name) free(property_name);
        int64_t result = -1;
        if (r_return) constructors.variant_from_int_constructor(r_return, &result);
        return;
    }
    
    entry->active = true;
    entry->type = COLYSEUS_GDCB_ON_ADD;
    entry->property = property_name;
    entry->ref_id = (first_arg_type == GDEXTENSION_VARIANT_TYPE_DICTIONARY) ?
                    colyseus_extract_ref_id(p_args[0]) : 0;
    entry->field_type = COLYSEUS_FIELD_MAP;  // Default for collections
    entry->item_vtable = NULL;
    
    // Look up field info from instance's vtable
    if (instance && property_name) {
        colyseus_schema_t* schema = (colyseus_schema_t*)instance;
        if (schema->__vtable) {
            for (int i = 0; i < schema->__vtable->field_count; i++) {
                if (strcmp(schema->__vtable->fields[i].name, property_name) == 0) {
                    entry->field_type = schema->__vtable->fields[i].type;
                    entry->item_vtable = schema->__vtable->fields[i].child_vtable;
                    printf("[ColyseusCallbacks] on_add field '%s': type=%d, item_vtable=%p\n", 
                           property_name, entry->field_type, (void*)entry->item_vtable);
                    fflush(stdout);
                    break;
                }
            }
        }
    }
    
    api.variant_new_copy(&entry->callable, callable_arg);
    
    if (wrapper->native_callbacks && instance && property_name) {
        entry->handle = colyseus_callbacks_on_add(
            wrapper->native_callbacks,
            instance,
            property_name,
            item_add_trampoline,
            entry,
            true  // immediate
        );
        printf("[ColyseusCallbacks] Registered native on_add callback, handle=%d\n", entry->handle);
        fflush(stdout);
    } else {
        entry->handle = wrapper->entry_count;
    }
    
    wrapper->entry_count++;
    
    int64_t handle = entry->handle;
    if (r_return) constructors.variant_from_int_constructor(r_return, &handle);
}

void gdext_colyseus_callbacks_on_remove(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
) {
    (void)p_method_userdata;
    
    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance;
    if (!wrapper) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL;
        return;
    }
    
    printf("[ColyseusCallbacks] on_remove() called with %lld args\n", (long long)p_argument_count);
    fflush(stdout);
    
    if (p_argument_count < 2) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        return;
    }
    
    GDExtensionVariantType first_arg_type = api.variant_get_type(p_args[0]);
    
    void* instance = NULL;
    char* property_name = NULL;
    GDExtensionConstVariantPtr callable_arg = NULL;
    
    if (first_arg_type == GDEXTENSION_VARIANT_TYPE_STRING) {
        property_name = variant_string_to_c_str(p_args[0]);
        callable_arg = p_args[1];
        
        if (wrapper->room_wrapper && wrapper->room_wrapper->native_room) {
            instance = colyseus_room_get_state(wrapper->room_wrapper->native_room);
        }
        
    } else if (first_arg_type == GDEXTENSION_VARIANT_TYPE_DICTIONARY) {
        if (p_argument_count < 3) {
            if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
            return;
        }
        
        int ref_id = colyseus_extract_ref_id(p_args[0]);
        property_name = variant_string_to_c_str(p_args[1]);
        callable_arg = p_args[2];
        
        if (wrapper->room_wrapper && wrapper->room_wrapper->native_room &&
            wrapper->room_wrapper->native_room->serializer &&
            wrapper->room_wrapper->native_room->serializer->decoder) {
            
            colyseus_ref_tracker_t* refs = 
                wrapper->room_wrapper->native_room->serializer->decoder->refs;
            if (refs) {
                instance = colyseus_ref_tracker_get(refs, ref_id);
            }
        }
    } else {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        return;
    }
    
    GodotCallbackEntry* entry = find_free_entry(wrapper);
    if (!entry) {
        if (property_name) free(property_name);
        int64_t result = -1;
        if (r_return) constructors.variant_from_int_constructor(r_return, &result);
        return;
    }
    
    entry->active = true;
    entry->type = COLYSEUS_GDCB_ON_REMOVE;
    entry->property = property_name;
    entry->ref_id = (first_arg_type == GDEXTENSION_VARIANT_TYPE_DICTIONARY) ?
                    colyseus_extract_ref_id(p_args[0]) : 0;
    entry->field_type = COLYSEUS_FIELD_MAP;  // Default for collections
    entry->item_vtable = NULL;
    
    // Look up field info from instance's vtable
    if (instance && property_name) {
        colyseus_schema_t* schema = (colyseus_schema_t*)instance;
        if (schema->__vtable) {
            for (int i = 0; i < schema->__vtable->field_count; i++) {
                if (strcmp(schema->__vtable->fields[i].name, property_name) == 0) {
                    entry->field_type = schema->__vtable->fields[i].type;
                    entry->item_vtable = schema->__vtable->fields[i].child_vtable;
                    break;
                }
            }
        }
    }
    
    api.variant_new_copy(&entry->callable, callable_arg);
    
    if (wrapper->native_callbacks && instance && property_name) {
        entry->handle = colyseus_callbacks_on_remove(
            wrapper->native_callbacks,
            instance,
            property_name,
            item_remove_trampoline,
            entry
        );
        printf("[ColyseusCallbacks] Registered native on_remove callback, handle=%d\n", entry->handle);
        fflush(stdout);
    } else {
        entry->handle = wrapper->entry_count;
    }
    
    wrapper->entry_count++;
    
    int64_t handle = entry->handle;
    if (r_return) constructors.variant_from_int_constructor(r_return, &handle);
}

void gdext_colyseus_callbacks_remove(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
) {
    (void)p_method_userdata;
    (void)r_return;
    
    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance;
    if (!wrapper) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL;
        return;
    }
    
    if (p_argument_count < 1) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        return;
    }
    
    int64_t handle = variant_to_int64(p_args[0]);
    
    GodotCallbackEntry* entry = find_entry_by_handle(wrapper, (int)handle);
    if (entry) {
        // Remove from native callbacks
        if (wrapper->native_callbacks) {
            colyseus_callbacks_remove(wrapper->native_callbacks, entry->handle);
        }
        
        // Clean up entry
        if (entry->property) {
            free(entry->property);
            entry->property = NULL;
        }
        destructors.variant_destroy(&entry->callable);
        entry->active = false;
        
        printf("[ColyseusCallbacks] Removed callback handle %lld\n", (long long)handle);
        fflush(stdout);
    }
}
