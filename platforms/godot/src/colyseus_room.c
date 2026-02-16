#include "godot_colyseus.h"
#include "colyseus_state.h"
#include "colyseus_schema_registry.h"
#include "colyseus_gdscript_schema.h"
#include "msgpack_encoder.h"
#include <colyseus/room.h>
#include <colyseus/schema.h>
#include <colyseus/schema/dynamic_schema.h>
#include <stdlib.h>
#include <string.h>

// Temporary storage for the last created wrapper
// Used to pass wrapper reference from constructor to caller
static ColyseusRoomWrapper* g_last_created_room_wrapper = NULL;

// Room wrapper registry for lookup by instance ID
#define MAX_ROOM_WRAPPERS 64
static struct {
    GDObjectInstanceID instance_id;
    ColyseusRoomWrapper* wrapper;
} g_room_registry[MAX_ROOM_WRAPPERS] = {0};

static void register_room_wrapper(GDObjectInstanceID instance_id, ColyseusRoomWrapper* wrapper) {
    for (int i = 0; i < MAX_ROOM_WRAPPERS; i++) {
        if (g_room_registry[i].wrapper == NULL) {
            g_room_registry[i].instance_id = instance_id;
            g_room_registry[i].wrapper = wrapper;
            return;
        }
    }
}

static void unregister_room_wrapper(ColyseusRoomWrapper* wrapper) {
    for (int i = 0; i < MAX_ROOM_WRAPPERS; i++) {
        if (g_room_registry[i].wrapper == wrapper) {
            g_room_registry[i].instance_id = 0;
            g_room_registry[i].wrapper = NULL;
            return;
        }
    }
}

ColyseusRoomWrapper* gdext_colyseus_room_get_wrapper_by_id(GDObjectInstanceID instance_id) {
    for (int i = 0; i < MAX_ROOM_WRAPPERS; i++) {
        if (g_room_registry[i].instance_id == instance_id) {
            return g_room_registry[i].wrapper;
        }
    }
    return NULL;
}

ColyseusRoomWrapper* gdext_colyseus_room_get_last_wrapper(void) {
    ColyseusRoomWrapper* wrapper = g_last_created_room_wrapper;
    g_last_created_room_wrapper = NULL;  // Clear after retrieval
    return wrapper;
}

// Helper function to create a Godot String from a C string
static void string_from_c_str(String *p_dest, const char *p_src) {
    if (p_src == NULL) {
        constructors.string_new_with_utf8_chars(p_dest, "");
    } else {
        constructors.string_new_with_utf8_chars(p_dest, p_src);
    }
}

// Helper function to convert Godot String to C string (caller must free)
static char* string_to_c_str(const String *p_src) {
    if (!p_src) return strdup("");
    
    // Get string length
    int32_t length = api.string_to_utf8_chars(p_src, NULL, 0);
    if (length <= 0) return strdup("");
    
    // Allocate buffer (+1 for null terminator)
    char* buffer = (char*)malloc(length + 1);
    if (!buffer) return strdup("");
    
    // Extract string
    api.string_to_utf8_chars(p_src, buffer, length);
    buffer[length] = '\0';
    
    return buffer;
}

GDExtensionObjectPtr gdext_colyseus_room_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    
    // Create the Godot Object (construct parent RefCounted class)
    StringName parent_class_name;
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);
    
    GDExtensionObjectPtr object = api.classdb_construct_object(&parent_class_name);
    destructors.string_name_destructor(&parent_class_name);
    
    if (!object) return NULL;
    
    // Create our wrapper instance data
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)malloc(sizeof(ColyseusRoomWrapper));
    if (!wrapper) return NULL;
    
    wrapper->native_room = NULL;
    wrapper->godot_object = object;
    wrapper->pending_vtable = NULL;
    wrapper->gdscript_schema_ctx = NULL;
    wrapper->gdscript_state_instance = NULL;
    
    // Attach our wrapper to the Godot object
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusRoom", false);
    api.object_set_instance(object, &class_name, wrapper);
    destructors.string_name_destructor(&class_name);
    
    // Store wrapper for retrieval by caller (e.g., join_or_create)
    g_last_created_room_wrapper = wrapper;
    
    // Register in the global registry for lookup by instance ID
    GDObjectInstanceID instance_id = api.object_get_instance_id(object);
    register_room_wrapper(instance_id, wrapper);
    
    return object;
}

void gdext_colyseus_room_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper) {
        // Unregister from global registry
        unregister_room_wrapper(wrapper);
        
        if (wrapper->native_room) {
            colyseus_room_free(wrapper->native_room);
        }
        
        // Free GDScript schema context if present
        if (wrapper->gdscript_schema_ctx) {
            gdscript_schema_context_free(wrapper->gdscript_schema_ctx);
        }
        
        // Free GDScript state instance if present
        if (wrapper->gdscript_state_instance) {
            destructors.variant_destroy(wrapper->gdscript_state_instance);
            free(wrapper->gdscript_state_instance);
        }
        
        free(wrapper);
    }
}

// Reference counting callbacks (unused, let Godot handle RefCounted)
void gdext_colyseus_room_reference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
}

void gdext_colyseus_room_unreference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
}

void gdext_colyseus_room_send_message(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    (void)r_return; // void return
    
    // Vararg call: p_args[0] is type (String), p_args[1] is data (any Variant)
    
    if (p_argument_count < 2) {
        if (r_error) {
            r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
            r_error->argument = 2;
        }
        return;
    }
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (!wrapper || !wrapper->native_room) {
        return;
    }
    
    // Extract message type string from p_args[0] (Variant containing String)
    String type_str;
    constructors.string_from_variant_constructor(&type_str, p_args[0]);
    
    int32_t type_len = api.string_to_utf8_chars(&type_str, NULL, 0);
    if (type_len <= 0) {
        destructors.string_destructor(&type_str);
        return;
    }
    
    char* type_cstr = (char*)malloc(type_len + 1);
    if (!type_cstr) {
        destructors.string_destructor(&type_str);
        return;
    }
    api.string_to_utf8_chars(&type_str, type_cstr, type_len);
    type_cstr[type_len] = '\0';
    destructors.string_destructor(&type_str);
    
    // Encode the data variant to msgpack (p_args[1] is already a Variant pointer)
    const Variant* data_variant = (const Variant*)p_args[1];
    size_t msgpack_len = 0;
    uint8_t* msgpack_data = godot_variant_to_msgpack(data_variant, &msgpack_len);
    
    // Send the message
    colyseus_room_send_str(wrapper->native_room, type_cstr, msgpack_data, msgpack_len);
    
    // Cleanup
    free(type_cstr);
    if (msgpack_data) {
        free(msgpack_data);
    }
    
    if (r_error) {
        r_error->error = GDEXTENSION_CALL_OK;
    }
}

void gdext_colyseus_room_send_message_int(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    (void)r_return; // void return
    
    // Vararg call: p_args[0] is type (int), p_args[1] is data (any Variant)
    
    if (p_argument_count < 2) {
        if (r_error) {
            r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
            r_error->argument = 2;
        }
        return;
    }
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (!wrapper || !wrapper->native_room) {
        return;
    }
    
    // Extract message type int from p_args[0] (Variant containing int)
    int64_t type_int = 0;
    constructors.int_from_variant_constructor(&type_int, p_args[0]);
    
    // Encode the data variant to msgpack (p_args[1] is already a Variant pointer)
    const Variant* data_variant = (const Variant*)p_args[1];
    size_t msgpack_len = 0;
    uint8_t* msgpack_data = godot_variant_to_msgpack(data_variant, &msgpack_len);
    
    // Send the message
    colyseus_room_send_int(wrapper->native_room, (int)type_int, msgpack_data, msgpack_len);
    
    // Cleanup
    if (msgpack_data) {
        free(msgpack_data);
    }
    
    if (r_error) {
        r_error->error = GDEXTENSION_CALL_OK;
    }
}

void gdext_colyseus_room_leave(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments
    (void)r_ret; // void return
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room) {
        colyseus_room_leave(wrapper->native_room, false);
    }
}

void gdext_colyseus_room_get_id(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room && r_ret) {
        const char* id = colyseus_room_get_id(wrapper->native_room);
        string_from_c_str((String*)r_ret, id);
    }
}

void gdext_colyseus_room_get_session_id(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room && r_ret) {
        const char* session_id = colyseus_room_get_session_id(wrapper->native_room);
        string_from_c_str((String*)r_ret, session_id);
    }
}

void gdext_colyseus_room_get_name(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room && r_ret) {
        const char* name = colyseus_room_get_name(wrapper->native_room);
        string_from_c_str((String*)r_ret, name);
    }
}

void gdext_colyseus_room_has_joined(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room && r_ret) {
        bool has_joined = colyseus_room_has_joined(wrapper->native_room);
        // For bool, we cast the result directly to the pointer location
        *(GDExtensionBool*)r_ret = has_joined ? 1 : 0;
    }
}

// ptrcall version - returns Dictionary directly
void gdext_colyseus_room_get_state_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args;
    
    Dictionary* result = (Dictionary*)r_ret;
    if (!result) return;
    
    // Initialize result dictionary
    constructors.dictionary_constructor(result, NULL);
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (!wrapper || !wrapper->native_room) {
        return;
    }
    
    // Get the state from the room
    void* state = colyseus_room_get_state(wrapper->native_room);
    const colyseus_schema_vtable_t* vtable = wrapper->native_room->state_vtable;
    
    if (state && vtable) {
        // Check if this is a dynamic schema
        if (colyseus_vtable_is_dynamic(vtable)) {
            colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)state;
            colyseus_dynamic_schema_to_dictionary(dyn_schema, result);
        } else {
            // Static schema - convert to dictionary
            colyseus_schema_to_dictionary((colyseus_schema_t*)state, vtable, result);
        }
    }
}

/*
 * set_state_type() - Vararg version that accepts either:
 *   - String: Legacy mode, looks up vtable by name in registry
 *   - Object (GDScript class): New mode, parses class definition() method
 */
void gdext_colyseus_room_set_state_type(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    (void)r_return;
    
    if (p_argument_count < 1) {
        if (r_error) {
            r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
            r_error->argument = 1;
        }
        return;
    }
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (!wrapper) {
        return;
    }
    
    // Check the type of the first argument
    GDExtensionVariantType arg_type = api.variant_get_type((GDExtensionVariantPtr)p_args[0]);
    
    if (arg_type == GDEXTENSION_VARIANT_TYPE_STRING) {
        // Legacy mode: String argument - look up in registry
        String type_str;
        constructors.string_from_variant_constructor(&type_str, p_args[0]);
        
        char* name = string_to_c_str(&type_str);
        destructors.string_destructor(&type_str);
        
        if (!name || name[0] == '\0') {
            if (name) free(name);
            return;
        }
        
        // Look up vtable in registry
        const colyseus_schema_vtable_t* vtable = colyseus_schema_lookup(name);
        if (!vtable) {
            free(name);
            return;
        }
        
        if (wrapper->native_room) {
            colyseus_room_set_state_type(wrapper->native_room, vtable);
        } else {
            wrapper->pending_vtable = vtable;
        }
        
        free(name);
        
    } else if (arg_type == GDEXTENSION_VARIANT_TYPE_OBJECT) {
        // New mode: GDScript class - parse definition() method
        
        // Free any existing GDScript schema context
        if (wrapper->gdscript_schema_ctx) {
            gdscript_schema_context_free(wrapper->gdscript_schema_ctx);
            wrapper->gdscript_schema_ctx = NULL;
        }
        
        // Parse the GDScript class
        gdscript_schema_context_t* ctx = gdscript_schema_context_create(p_args[0]);
        if (!ctx || !ctx->vtable) {
            if (ctx) gdscript_schema_context_free(ctx);
            return;
        }
        
        wrapper->gdscript_schema_ctx = ctx;
        
        // Cast dynamic vtable to base vtable for the room
        const colyseus_schema_vtable_t* vtable = (const colyseus_schema_vtable_t*)ctx->vtable;
        
        if (wrapper->native_room) {
            colyseus_room_set_state_type(wrapper->native_room, vtable);
        } else {
            wrapper->pending_vtable = vtable;
        }
    }
    
    if (r_error) {
        r_error->error = GDEXTENSION_CALL_OK;
    }
}
