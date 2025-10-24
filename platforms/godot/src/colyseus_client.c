#include "godot_colyseus.h"
#include <colyseus/client.h>
#include <colyseus/settings.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

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
    
    printf("[ColyseusClient] Constructor called\n");
    fflush(stdout);
    
    // Create the Godot Object (construct parent RefCounted class)
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "RefCounted", false);
    
    GDExtensionObjectPtr object = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);
    
    if (!object) {
        printf("[ColyseusClient] ERROR: Failed to construct Godot object!\n");
        fflush(stdout);
        return NULL;
    }
    
    printf("[ColyseusClient] Godot object created: %p\n", (void*)object);
    fflush(stdout);
    
    // Create our wrapper instance data
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)malloc(sizeof(ColyseusClientWrapper));
    if (!wrapper) {
        printf("[ColyseusClient] ERROR: Failed to allocate wrapper!\n");
        fflush(stdout);
        return NULL;
    }
    
    wrapper->native_client = NULL; // Will be initialized on connect
    
    printf("[ColyseusClient] Wrapper created: %p\n", (void*)wrapper);
    fflush(stdout);
    
    // Attach our wrapper to the Godot object
    StringName class_name2;
    constructors.string_name_new_with_latin1_chars(&class_name2, "ColyseusClient", false);
    api.object_set_instance(object, &class_name2, wrapper);
    destructors.string_name_destructor(&class_name2);
    
    printf("[ColyseusClient] Wrapper attached to object\n");
    fflush(stdout);
    
    return object;
}

void gdext_colyseus_client_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    
    printf("[ColyseusClient] Destructor called for instance: %p\n", p_instance);
    fflush(stdout);
    
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
    printf("[ColyseusClient] Reference called\n");
    fflush(stdout);
}

void gdext_colyseus_client_unreference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
    // For RefCounted, Godot manages the reference count internally
    // We don't need to do anything here
    printf("[ColyseusClient] Unreference called\n");
    fflush(stdout);
}

void gdext_colyseus_client_connect_to(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)r_ret; // void return
    
    printf("[ColyseusClient] connect_to called with instance: %p\n", p_instance);
    fflush(stdout);
    
    // p_args[0] is a pointer to a String (GDExtensionStringPtr)
    const String* endpoint = (const String*)p_args[0];
    
    printf("[ColyseusClient] String pointer: %p\n", (void*)endpoint);
    fflush(stdout);
    
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper) {
        printf("[ColyseusClient] ERROR: wrapper is NULL!\n");
        fflush(stdout);
        return;
    }
    
    printf("[ColyseusClient] Wrapper valid: %p\n", (void*)wrapper);
    fflush(stdout);
    
    // Extract the endpoint string
    char* endpoint_str = string_to_c_str(endpoint);
    if (!endpoint_str) return;
    
    printf("[ColyseusClient] Connecting to: %s\n", endpoint_str);
    fflush(stdout);
    
    // Parse endpoint and create settings
    char* address = NULL;
    char* port = NULL;
    bool use_secure = false;
    
    parse_endpoint(endpoint_str, &address, &port, &use_secure);
    
    printf("[ColyseusClient] Parsed - address: %s, port: %s, secure: %d\n", address, port, use_secure);
    fflush(stdout);
    
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
    
    printf("[ColyseusClient] Native client created\n");
    fflush(stdout);
    
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

// GDExtension wrapper for the simple getter
void gdext_colyseus_client_get_endpoint_wrapper(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments
    
    const ColyseusClientWrapper* self = (const ColyseusClientWrapper*)p_instance;
    if (self && r_ret) {
        const char* endpoint = gdext_colyseus_client_get_endpoint(self);
        string_from_c_str((String*)r_ret, endpoint);
    }
}

// Helper function to emit Godot signals
static void emit_signal(GDExtensionObjectPtr object, const char* signal_name, GDExtensionConstVariantPtr* args, int arg_count) {
    if (!object) return;
    
    // Get object_emit_signal function pointer
    GDExtensionInterfaceObjectMethodBindPtrcall object_emit_signal = 
        (GDExtensionInterfaceObjectMethodBindPtrcall)api.classdb_construct_object; // placeholder
    
    // TODO: Properly implement signal emission
    // For now we'll just log it
    printf("[ColyseusRoom] Would emit signal: %s\n", signal_name);
    fflush(stdout);
}

// Room event callbacks
static void on_room_join(void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    
    printf("[ColyseusRoom] Joined room!\n");
    fflush(stdout);
    
    // Emit "joined" signal
    emit_signal(room_wrapper->godot_object, "joined", NULL, 0);
}

static void on_room_state_change(void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    
    printf("[ColyseusRoom] State changed\n");
    fflush(stdout);
    
    // Emit "state_changed" signal
    emit_signal(room_wrapper->godot_object, "state_changed", NULL, 0);
}

static void on_room_error(int code, const char* message, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    
    printf("[ColyseusRoom] Error [%d]: %s\n", code, message);
    fflush(stdout);
    
    // TODO: Emit "error" signal with code and message
}

static void on_room_leave(int code, const char* reason, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    
    printf("[ColyseusRoom] Left room [%d]: %s\n", code, reason);
    fflush(stdout);
    
    // TODO: Emit "left" signal with code and reason
}

// Matchmaking success callback
static void on_join_or_create_success(colyseus_room_t* room, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper) return;
    
    printf("[ColyseusClient] Join/Create success! Room: %p\n", (void*)room);
    fflush(stdout);
    
    // Store the native room
    room_wrapper->native_room = room;
    
    // Register room event callbacks
    colyseus_room_on_join(room, on_room_join, room_wrapper);
    colyseus_room_on_state_change(room, on_room_state_change, room_wrapper);
    colyseus_room_on_error(room, on_room_error, room_wrapper);
    colyseus_room_on_leave(room, on_room_leave, room_wrapper);
    
    printf("[ColyseusClient] Room callbacks registered\n");
    fflush(stdout);
}

// Matchmaking error callback
static void on_join_or_create_error(int code, const char* message, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    
    printf("[ColyseusClient] Join/Create error [%d]: %s\n", code, message);
    fflush(stdout);
    
    // Emit error on the room object
    if (room_wrapper) {
        on_room_error(code, message, room_wrapper);
    }
}

// join_or_create implementation (ptrcall version)
void gdext_colyseus_client_join_or_create_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    
    printf("[ColyseusClient] join_or_create called\n");
    fflush(stdout);
    
    ColyseusClientWrapper* client_wrapper = (ColyseusClientWrapper*)p_instance;
    if (!client_wrapper || !client_wrapper->native_client) {
        printf("[ColyseusClient] ERROR: Client not connected!\n");
        fflush(stdout);
        // Return null object
        if (r_ret) {
            GDExtensionObjectPtr null_obj = NULL;
            constructors.variant_from_object_constructor(r_ret, &null_obj);
        }
        return;
    }
    
    // p_args[0] is a pointer to a String (room name)
    const String* room_name_string = (const String*)p_args[0];
    char* room_name = string_to_c_str(room_name_string);
    
    printf("[ColyseusClient] Room name: %s\n", room_name);
    fflush(stdout);
    
    // Create a ColyseusRoom Godot object
    // This will call our constructor (gdext_colyseus_room_constructor) automatically
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusRoom", false);
    
    GDExtensionObjectPtr room_object = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);
    
    if (!room_object) {
        printf("[ColyseusClient] ERROR: Failed to construct ColyseusRoom object!\n");
        fflush(stdout);
        free(room_name);
        // Return null object
        if (r_ret) {
            GDExtensionObjectPtr null_obj = NULL;
            constructors.variant_from_object_constructor(r_ret, &null_obj);
        }
        return;
    }
    
    printf("[ColyseusClient] ColyseusRoom object created: %p\n", (void*)room_object);
    fflush(stdout);
    
    // Get the wrapper instance that was created by our constructor
    // The wrapper is the instance pointer associated with the object
    // Since we just created it, the wrapper is the object itself for now (we need to get the binding)
    // For extension classes, the instance IS the wrapper we returned from constructor
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)room_object;
    
    // Store the Godot object reference
    room_wrapper->godot_object = room_object;
    
    printf("[ColyseusClient] Room wrapper: %p\n", (void*)room_wrapper);
    fflush(stdout);
    
    // Call native join_or_create (async)
    colyseus_client_join_or_create(
        client_wrapper->native_client,
        room_name,
        "{}",  // Empty options for now
        on_join_or_create_success,
        on_join_or_create_error,
        room_wrapper
    );
    
    printf("[ColyseusClient] Native join_or_create called\n");
    fflush(stdout);
    
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
    constructors.string_from_variant_constructor(&room_name_string, p_args[0]);
    
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
