#include "godot_colyseus.h"
#include "msgpack_variant.h"
#include <colyseus/client.h>
#include <colyseus/room.h>
#include <colyseus/settings.h>
#include <colyseus/schema/types.h>
#include <stdlib.h>
#include <string.h>

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

// Helper to parse endpoint string (e.g., "ws://localhost:2567")
static void parse_endpoint(const char* endpoint, char** address, char** port, bool* use_secure) {
    if (!endpoint) return;
    
    // Check protocol
    if (strncmp(endpoint, "wss://", 6) == 0) {
        *use_secure = true;
        endpoint += 6;
    } else if (strncmp(endpoint, "ws://", 5) == 0) {
        *use_secure = false;
        endpoint += 5;
    } else if (strncmp(endpoint, "https://", 8) == 0) {
        *use_secure = true;
        endpoint += 8;
    } else if (strncmp(endpoint, "http://", 7) == 0) {
        *use_secure = false;
        endpoint += 7;
    }
    
    // Find port separator
    const char* colon = strchr(endpoint, ':');
    const char* slash = strchr(endpoint, '/');
    
    if (colon && (!slash || colon < slash)) {
        // Has port
        size_t addr_len = colon - endpoint;
        *address = (char*)malloc(addr_len + 1);
        strncpy(*address, endpoint, addr_len);
        (*address)[addr_len] = '\0';
        
        // Extract port
        const char* port_start = colon + 1;
        const char* port_end = slash ? slash : (port_start + strlen(port_start));
        size_t port_len = port_end - port_start;
        *port = (char*)malloc(port_len + 1);
        strncpy(*port, port_start, port_len);
        (*port)[port_len] = '\0';
    } else {
        // No port, just address
        const char* addr_end = slash ? slash : (endpoint + strlen(endpoint));
        size_t addr_len = addr_end - endpoint;
        *address = (char*)malloc(addr_len + 1);
        strncpy(*address, endpoint, addr_len);
        (*address)[addr_len] = '\0';
        
        *port = strdup(*use_secure ? "443" : "80");
    }
}

// Forward declaration for callbacks
static void on_join_or_create_success(colyseus_room_t* room, void* userdata);
static void on_join_or_create_error(int code, const char* message, void* userdata);

// Room event callbacks
static void on_room_join(void* userdata);
static void on_room_state_change(void* userdata);
static void on_room_error(int code, const char* message, void* userdata);
static void on_room_leave(int code, const char* reason, void* userdata);

GDExtensionObjectPtr gdext_colyseus_client_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    
    // Create the Godot Object (construct parent RefCounted class)
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "RefCounted", false);
    
    GDExtensionObjectPtr object = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);
    
    if (!object) return NULL;
    
    // Create our wrapper instance data
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)malloc(sizeof(ColyseusClientWrapper));
    if (!wrapper) return NULL;
    
    wrapper->native_client = NULL;
    
    // Attach our wrapper to the Godot object
    StringName class_name2;
    constructors.string_name_new_with_latin1_chars(&class_name2, "ColyseusClient", false);
    api.object_set_instance(object, &class_name2, wrapper);
    destructors.string_name_destructor(&class_name2);
    
    return object;
}

void gdext_colyseus_client_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (wrapper) {
        if (wrapper->native_client) {
            colyseus_client_free(wrapper->native_client);
        }
        free(wrapper);
    }
}

// Reference counting for RefCounted base class
void gdext_colyseus_client_reference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
    // For RefCounted, Godot manages the reference count internally
    // We don't need to do anything here
}

void gdext_colyseus_client_unreference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
    // For RefCounted, Godot manages the reference count internally
    // We don't need to do anything here
}

void gdext_colyseus_client_set_endpoint(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)r_ret;
    
    const String* endpoint = (const String*)p_args[0];
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper) return;
    
    char* endpoint_str = string_to_c_str(endpoint);
    if (!endpoint_str) return;
    
    // Parse endpoint and create settings
    char* address = NULL;
    char* port = NULL;
    bool use_secure = false;
    parse_endpoint(endpoint_str, &address, &port, &use_secure);
    
    // Create settings
    colyseus_settings_t* settings = colyseus_settings_create();
    colyseus_settings_set_address(settings, address);
    colyseus_settings_set_port(settings, port);
    colyseus_settings_set_secure(settings, use_secure);
    
    // Create native client
    if (wrapper->native_client) {
        colyseus_client_free(wrapper->native_client);
    }
    wrapper->native_client = colyseus_client_create(settings);
    
    // Cleanup
    free(endpoint_str);
    free(address);
    free(port);
}

// Simple getter - reference implementation style
const char* gdext_colyseus_client_get_endpoint(const ColyseusClientWrapper* self) {
    if (self && self->native_client && self->native_client->settings) {
        // Note: This returns a pointer to the settings structure data
        // The string is managed by the settings object and should not be freed by the caller
        return self->native_client->settings->server_address;
    }
    return "";
}

// GDExtension ptrcall wrapper for get_endpoint (raw type return)
void gdext_colyseus_client_get_endpoint_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args;
    
    const ColyseusClientWrapper* self = (const ColyseusClientWrapper*)p_instance;
    if (self && r_ret) {
        const char* endpoint = gdext_colyseus_client_get_endpoint(self);
        string_from_c_str((String*)r_ret, endpoint);
    }
}

// GDExtension call wrapper for get_endpoint (Variant return)
void gdext_colyseus_client_get_endpoint_call(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    (void)p_args;
    (void)p_argument_count;
    (void)r_error;
    
    const ColyseusClientWrapper* self = (const ColyseusClientWrapper*)p_instance;
    if (self && r_return) {
        const char* endpoint = gdext_colyseus_client_get_endpoint(self);
        String result_string;
        string_from_c_str(&result_string, endpoint);
        constructors.variant_from_string_constructor(r_return, &result_string);
        destructors.string_destructor(&result_string);
    }
}

// Helper function to emit Godot signals via call_deferred
// This ensures signals are emitted on the main thread, avoiding thread safety issues
static void emit_signal(GDExtensionObjectPtr object, const char* signal_name, GDExtensionConstVariantPtr* args, int arg_count) {
    if (!object) return;
    
    Variant object_variant;
    constructors.variant_from_object_constructor(&object_variant, &object);
    
    // Use call_deferred to ensure signal emission happens on main thread
    StringName call_deferred_method;
    constructors.string_name_new_with_latin1_chars(&call_deferred_method, "call_deferred", false);
    
    // First arg to call_deferred is the method name "emit_signal"
    String emit_signal_str;
    constructors.string_new_with_utf8_chars(&emit_signal_str, "emit_signal");
    Variant emit_signal_variant;
    constructors.variant_from_string_constructor(&emit_signal_variant, &emit_signal_str);
    
    // Second arg to call_deferred is the signal name
    String signal_string;
    constructors.string_new_with_utf8_chars(&signal_string, signal_name);
    Variant signal_name_variant;
    constructors.variant_from_string_constructor(&signal_name_variant, &signal_string);
    
    // Build args array: ["emit_signal", signal_name, ...args]
    GDExtensionConstVariantPtr call_args[16];
    call_args[0] = &emit_signal_variant;
    call_args[1] = &signal_name_variant;
    for (int i = 0; i < arg_count && i < 14; i++) {
        call_args[i + 2] = args[i];
    }
    
    Variant return_value;
    GDExtensionCallError error;
    api.variant_call(&object_variant, &call_deferred_method, call_args, arg_count + 2, &return_value, &error);
    
    destructors.string_name_destructor(&call_deferred_method);
    destructors.string_destructor(&emit_signal_str);
    destructors.variant_destroy(&emit_signal_variant);
    destructors.string_destructor(&signal_string);
    destructors.variant_destroy(&signal_name_variant);
    destructors.variant_destroy(&return_value);
    destructors.variant_destroy(&object_variant);
}

// Message callback - receives messages with type info and emits signal
// Decodes msgpack payload to native Godot types (Dictionary, Array, etc.)
static void on_room_message_with_type(const char* type, const uint8_t* data, size_t length, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;
    
    // Create type Variant (as String)
    String type_string;
    constructors.string_new_with_utf8_chars(&type_string, type);
    Variant type_variant;
    constructors.variant_from_string_constructor(&type_variant, &type_string);
    
    // Decode msgpack payload to Godot Variant
    Variant data_variant;
    bool decode_success = msgpack_to_godot_variant(data, length, &data_variant);
    
    if (!decode_success) {
        // Fallback: if decoding fails, return raw bytes as PackedByteArray
        PackedByteArray byte_array;
        constructors.packed_byte_array_constructor(&byte_array, NULL);
        constructors.variant_from_packed_byte_array_constructor(&data_variant, &byte_array);
        
        if (length > 0) {
            // Resize and copy
            StringName resize_method;
            constructors.string_name_new_with_latin1_chars(&resize_method, "resize", false);
            int64_t size_val = (int64_t)length;
            Variant size_variant;
            constructors.variant_from_int_constructor(&size_variant, &size_val);
            GDExtensionConstVariantPtr resize_args[1] = { &size_variant };
            Variant resize_return;
            GDExtensionCallError error;
            api.variant_call(&data_variant, &resize_method, resize_args, 1, &resize_return, &error);
            destructors.string_name_destructor(&resize_method);
            destructors.variant_destroy(&size_variant);
            destructors.variant_destroy(&resize_return);
            
            if (error.error == GDEXTENSION_CALL_OK) {
                for (size_t i = 0; i < length; i++) {
                    uint8_t* ptr = api.packed_byte_array_operator_index(&byte_array, (GDExtensionInt)i);
                    if (ptr) *ptr = data[i];
                }
            }
        }
    }
    
    // Emit signal: message_received(type, data)
    GDExtensionConstVariantPtr args[2] = { &type_variant, &data_variant };
    emit_signal(room_wrapper->godot_object, "message_received", args, 2);
    
    // Cleanup
    destructors.string_destructor(&type_string);
    destructors.variant_destroy(&type_variant);
    destructors.variant_destroy(&data_variant);
}

// Room event callbacks
static void on_room_join(void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    emit_signal(room_wrapper->godot_object, "joined", NULL, 0);
}

static void on_room_state_change(void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    emit_signal(room_wrapper->godot_object, "state_changed", NULL, 0);
}

static void on_room_error(int code, const char* message, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;
    
    // Create code Variant (int)
    int64_t code_value = code;
    Variant code_variant;
    constructors.variant_from_int_constructor(&code_variant, &code_value);
    
    // Create message Variant (String)
    String message_string;
    constructors.string_new_with_utf8_chars(&message_string, message ? message : "");
    Variant message_variant;
    constructors.variant_from_string_constructor(&message_variant, &message_string);
    
    // Emit signal: error(code, message)
    GDExtensionConstVariantPtr args[2] = { &code_variant, &message_variant };
    emit_signal(room_wrapper->godot_object, "error", args, 2);
    
    // Cleanup
    destructors.variant_destroy(&code_variant);
    destructors.string_destructor(&message_string);
    destructors.variant_destroy(&message_variant);
}

static void on_room_leave(int code, const char* reason, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;
    
    // Create code Variant (int)
    int64_t code_value = code;
    Variant code_variant;
    constructors.variant_from_int_constructor(&code_variant, &code_value);
    
    // Create reason Variant (String)
    String reason_string;
    constructors.string_new_with_utf8_chars(&reason_string, reason ? reason : "");
    Variant reason_variant;
    constructors.variant_from_string_constructor(&reason_variant, &reason_string);
    
    // Emit signal: left(code, reason)
    GDExtensionConstVariantPtr args[2] = { &code_variant, &reason_variant };
    emit_signal(room_wrapper->godot_object, "left", args, 2);
    
    // Cleanup
    destructors.variant_destroy(&code_variant);
    destructors.string_destructor(&reason_string);
    destructors.variant_destroy(&reason_variant);
}

// Matchmaking success callback
static void on_join_or_create_success(colyseus_room_t* room, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    
    // Apply pending vtable BEFORE assigning native room (so it's set before join message processing)
    if (room_wrapper->pending_vtable) {
        colyseus_room_set_state_type(room, room_wrapper->pending_vtable);
        room_wrapper->pending_vtable = NULL;  // Clear after applying
    }
    
    room_wrapper->native_room = room;
    
    // Register room event callbacks
    colyseus_room_on_join(room, on_room_join, room_wrapper);
    colyseus_room_on_state_change(room, on_room_state_change, room_wrapper);
    colyseus_room_on_error(room, on_room_error, room_wrapper);
    colyseus_room_on_leave(room, on_room_leave, room_wrapper);
    colyseus_room_on_message_any_with_type(room, on_room_message_with_type, room_wrapper);
}

// Matchmaking error callback
static void on_join_or_create_error(int code, const char* message, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (room_wrapper) {
        on_room_error(code, message, room_wrapper);
    }
}

// join_or_create implementation (ptrcall version)
void gdext_colyseus_client_join_or_create_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    
    ColyseusClientWrapper* client_wrapper = (ColyseusClientWrapper*)p_instance;
    if (!client_wrapper || !client_wrapper->native_client) {
        if (r_ret) {
            GDExtensionObjectPtr null_obj = NULL;
            constructors.variant_from_object_constructor(r_ret, &null_obj);
        }
        return;
    }
    
    // p_args[0] is a pointer to a String (room name)
    const String* room_name_string = (const String*)p_args[0];
    char* room_name = string_to_c_str(room_name_string);
    
    // Create a ColyseusRoom Godot object
    // This will call gdext_colyseus_room_constructor which creates the wrapper
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusRoom", false);
    
    GDExtensionObjectPtr room_object = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);
    
    if (!room_object) {
        free(room_name);
        if (r_ret) {
            GDExtensionObjectPtr null_obj = NULL;
            constructors.variant_from_object_constructor(r_ret, &null_obj);
        }
        return;
    }
    
    // Get the wrapper that was created by the constructor
    ColyseusRoomWrapper* room_wrapper = gdext_colyseus_room_get_last_wrapper();
    if (!room_wrapper) {
        free(room_name);
        return;
    }
    
    // Call native join_or_create (async)
    colyseus_client_join_or_create(
        client_wrapper->native_client,
        room_name,
        "{}",  // Empty options for now
        on_join_or_create_success,
        on_join_or_create_error,
        room_wrapper
    );
    
    // For RefCounted objects, call reference() to keep the object alive when returning
    {
        StringName ref_method;
        constructors.string_name_new_with_latin1_chars(&ref_method, "reference", false);
        
        Variant room_variant;
        constructors.variant_from_object_constructor(&room_variant, &room_object);
        
        Variant return_val;
        GDExtensionCallError call_error;
        api.variant_call(&room_variant, &ref_method, NULL, 0, &return_val, &call_error);
        
        destructors.string_name_destructor(&ref_method);
        destructors.variant_destroy(&return_val);
        destructors.variant_destroy(&room_variant);
    }
    
    // Return the room object (ptrcall - write object pointer directly)
    if (r_ret) {
        *(GDExtensionObjectPtr*)r_ret = room_object;
    }
    
    free(room_name);
}

// join_or_create implementation (call version - with Variants)
void gdext_colyseus_client_join_or_create(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    (void)p_argument_count;
    (void)r_error;
    
    // Extract the string argument from variant
    String room_name_string;
    constructors.string_from_variant_constructor(&room_name_string, (GDExtensionVariantPtr)p_args[0]);
    
    // Call the ptrcall version with converted arguments
    GDExtensionObjectPtr result = NULL;
    gdext_colyseus_client_join_or_create_ptrcall(p_method_userdata, p_instance, (const GDExtensionConstTypePtr*)&room_name_string, &result);
    
    // Convert result to variant
    if (r_return) {
        constructors.variant_from_object_constructor(r_return, &result);
    }
    
    // Cleanup
    destructors.string_destructor(&room_name_string);
}
