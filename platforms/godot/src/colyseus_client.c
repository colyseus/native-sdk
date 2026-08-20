#include "godot_colyseus.h"
#include "msgpack_variant.h"
#include "tls_certificates.h"
#include <colyseus/client.h>
#include <colyseus/http.h>
#include <colyseus/auth/auth.h>
#include "cJSON.h"
#include <colyseus/room.h>
#include <colyseus/settings.h>
#include <colyseus/schema/types.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifndef _WIN32
#include <unistd.h>
#endif

#ifndef __EMSCRIPTEN__
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif
#endif

// HTTP event queue type (needed by destructor, full definition below)
typedef struct gdext_http_event {
    int is_error;
    int64_t request_id;
    int status_or_code;
    char* body_or_message;
    GDExtensionObjectPtr client_object;
    struct gdext_http_event* next;
} gdext_http_event_t;
static gdext_http_event_t* http_event_pop(void);

// Room event queue — thread-safe, processed in poll()
typedef enum {
    ROOM_EVENT_JOIN = 0,
    ROOM_EVENT_STATE_CHANGE,
    ROOM_EVENT_ERROR,
    ROOM_EVENT_LEAVE,
    ROOM_EVENT_MESSAGE,
    ROOM_EVENT_DROP,
    ROOM_EVENT_RECONNECT,
} gdext_room_event_type_t;

typedef struct gdext_room_event {
    gdext_room_event_type_t type;
    GDExtensionObjectPtr room_object;
    int code;               // for error/leave
    char* str_data;         // message (error/leave reason), or message type
    uint8_t* binary_data;   // message payload (msgpack)
    size_t binary_len;
    struct gdext_room_event* next;
} gdext_room_event_t;

static void room_event_push(gdext_room_event_t* event);
static gdext_room_event_t* room_event_pop(void);

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
static void on_matchmaking_success(colyseus_room_t* room, void* userdata);
static void on_matchmaking_error(int code, const char* message, void* userdata);

// Room event callbacks
static void on_room_join(void* userdata);
static void on_room_state_change(void* userdata);
static void on_room_error(int code, const char* message, void* userdata);
static void on_room_leave(int code, const char* reason, void* userdata);

GDExtensionObjectPtr gdext_colyseus_client_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    
    // Create the Godot Object (construct parent class)
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "RefCounted", false);
    
    GDExtensionObjectPtr object = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);
    
    if (!object) return NULL;
    
    // Create our wrapper instance data
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)malloc(sizeof(ColyseusClientWrapper));
    if (!wrapper) return NULL;
    
    wrapper->native_client = NULL;
    wrapper->godot_object = object;

    // Attach our wrapper to the Godot object
    StringName class_name2;
    constructors.string_name_new_with_latin1_chars(&class_name2, "_ColyseusClient", false);
    api.object_set_instance(object, &class_name2, wrapper);
    destructors.string_name_destructor(&class_name2);
    
    return object;
}

void gdext_colyseus_client_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;

    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (wrapper) {
        // Wait for in-flight HTTP requests to complete
        int wait_ms = 0;
        while (wrapper->pending_http_requests > 0 && wait_ms < 2000) {
            #ifdef _WIN32
            Sleep(10);
            #else
            usleep(10000);
            #endif
            wait_ms += 10;
        }

        // Drain any queued events for this client (discard — object is being freed)
        gdext_http_event_t* event;
        while ((event = http_event_pop()) != NULL) {
            free(event->body_or_message);
            free(event);
        }

        // Invalidate godot_object
        wrapper->godot_object = NULL;

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
    
    // Set CA certificates for TLS verification (auto-loaded at init time)
    const unsigned char* ca_data = gdext_tls_get_ca_certificates();
    size_t ca_len = gdext_tls_get_ca_certificates_len();
    if (ca_data && ca_len > 0) {
        colyseus_settings_set_ca_certificates(settings, ca_data, ca_len);
    }
    
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

    // Use call_deferred because WebSocket callbacks fire from a background thread.
    // Godot APIs are not thread-safe, so we must defer to the main thread.
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

// =============================================================================
// Room event trampolines — push to queue (processed in poll on main thread)
// =============================================================================

static void on_room_message_with_type(const char* type, const uint8_t* data, size_t length, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;

    gdext_room_event_t* event = (gdext_room_event_t*)calloc(1, sizeof(gdext_room_event_t));
    if (!event) return;
    event->type = ROOM_EVENT_MESSAGE;
    event->room_object = room_wrapper->godot_object;
    event->str_data = type ? strdup(type) : strdup("");
    if (data && length > 0) {
        event->binary_data = (uint8_t*)malloc(length);
        if (event->binary_data) {
            memcpy(event->binary_data, data, length);
            event->binary_len = length;
        }
    }
    room_event_push(event);
}

static void on_room_join(void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;

    gdext_room_event_t* event = (gdext_room_event_t*)calloc(1, sizeof(gdext_room_event_t));
    if (!event) return;
    event->type = ROOM_EVENT_JOIN;
    event->room_object = room_wrapper->godot_object;
    room_event_push(event);
}

static void on_room_state_change(void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;

    gdext_room_event_t* event = (gdext_room_event_t*)calloc(1, sizeof(gdext_room_event_t));
    if (!event) return;
    event->type = ROOM_EVENT_STATE_CHANGE;
    event->room_object = room_wrapper->godot_object;
    room_event_push(event);
}

static void on_room_error(int code, const char* message, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;

    gdext_room_event_t* event = (gdext_room_event_t*)calloc(1, sizeof(gdext_room_event_t));
    if (!event) return;
    event->type = ROOM_EVENT_ERROR;
    event->room_object = room_wrapper->godot_object;
    event->code = code;
    event->str_data = message ? strdup(message) : strdup("");
    room_event_push(event);
}

static void on_room_leave(int code, const char* reason, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;

    gdext_room_event_t* event = (gdext_room_event_t*)calloc(1, sizeof(gdext_room_event_t));
    if (!event) return;
    event->type = ROOM_EVENT_LEAVE;
    event->room_object = room_wrapper->godot_object;
    event->code = code;
    event->str_data = reason ? strdup(reason) : strdup("");
    room_event_push(event);
}

static void on_room_drop(int code, const char* reason, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;

    gdext_room_event_t* event = (gdext_room_event_t*)calloc(1, sizeof(gdext_room_event_t));
    if (!event) return;
    event->type = ROOM_EVENT_DROP;
    event->room_object = room_wrapper->godot_object;
    event->code = code;
    event->str_data = reason ? strdup(reason) : strdup("");
    room_event_push(event);
}

static void on_room_reconnect(void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (!room_wrapper || !room_wrapper->godot_object) return;

    gdext_room_event_t* event = (gdext_room_event_t*)calloc(1, sizeof(gdext_room_event_t));
    if (!event) return;
    event->type = ROOM_EVENT_RECONNECT;
    event->room_object = room_wrapper->godot_object;
    room_event_push(event);
}

// Matchmaking success callback (shared by all matchmaking methods)
static void on_matchmaking_success(colyseus_room_t* room, void* userdata) {
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
    colyseus_room_on_drop(room, on_room_drop, room_wrapper);
    colyseus_room_on_reconnect(room, on_room_reconnect, room_wrapper);
    colyseus_room_on_message_any_with_type_encoded(room, on_room_message_with_type, room_wrapper);
}

// Matchmaking error callback (shared by all matchmaking methods)
static void on_matchmaking_error(int code, const char* message, void* userdata) {
    ColyseusRoomWrapper* room_wrapper = (ColyseusRoomWrapper*)userdata;
    if (room_wrapper) {
        on_room_error(code, message, room_wrapper);
    }
}

// =============================================================================
// Common matchmaking helpers
// =============================================================================

// Function pointer type for matchmaking methods that take (client, name, options, callbacks)
typedef void (*matchmaking_with_options_fn)(colyseus_client_t*, const char*, const char*,
    colyseus_client_room_callback_t, colyseus_client_error_callback_t, void*);

// Function pointer type for reconnect (client, token, callbacks — no options)
typedef void (*matchmaking_reconnect_fn)(colyseus_client_t*, const char*,
    colyseus_client_room_callback_t, colyseus_client_error_callback_t, void*);

// Common ptrcall implementation for matchmaking methods with options (join_or_create, create, join, join_by_id)
// p_args[0] = String (room name / room id), p_args[1] = String (options JSON)
static void matchmaking_ptrcall_with_options(GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret, matchmaking_with_options_fn native_fn) {
    ColyseusClientWrapper* client_wrapper = (ColyseusClientWrapper*)p_instance;
    if (!client_wrapper || !client_wrapper->native_client) {
        if (r_ret) {
            *(GDExtensionObjectPtr*)r_ret = NULL;
        }
        return;
    }

    // p_args[0] = room name / room id, p_args[1] = options JSON string
    const String* arg_string = (const String*)p_args[0];
    char* arg_cstr = string_to_c_str(arg_string);

    const String* options_string = (const String*)p_args[1];
    char* options_cstr = string_to_c_str(options_string);

    // Create a ColyseusRoom Godot object
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "_ColyseusRoom", false);

    GDExtensionObjectPtr room_object = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);

    if (!room_object) {
        free(arg_cstr);
        free(options_cstr);
        if (r_ret) {
            *(GDExtensionObjectPtr*)r_ret = NULL;
        }
        return;
    }

    // Get the wrapper that was created by the constructor
    ColyseusRoomWrapper* room_wrapper = gdext_colyseus_room_get_last_wrapper();
    if (!room_wrapper) {
        free(arg_cstr);
        free(options_cstr);
        return;
    }

    // Call the native matchmaking function (async)
    native_fn(
        client_wrapper->native_client,
        arg_cstr,
        options_cstr,
        on_matchmaking_success,
        on_matchmaking_error,
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

    // Return the room object
    if (r_ret) {
        *(GDExtensionObjectPtr*)r_ret = room_object;
    }

    free(arg_cstr);
    free(options_cstr);
}

// Common ptrcall implementation for reconnect (no options parameter)
static void matchmaking_ptrcall_reconnect(GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret, matchmaking_reconnect_fn native_fn) {
    ColyseusClientWrapper* client_wrapper = (ColyseusClientWrapper*)p_instance;
    if (!client_wrapper || !client_wrapper->native_client) {
        if (r_ret) {
            *(GDExtensionObjectPtr*)r_ret = NULL;
        }
        return;
    }

    const String* token_string = (const String*)p_args[0];
    char* token_cstr = string_to_c_str(token_string);

    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "_ColyseusRoom", false);

    GDExtensionObjectPtr room_object = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);

    if (!room_object) {
        free(token_cstr);
        if (r_ret) {
            *(GDExtensionObjectPtr*)r_ret = NULL;
        }
        return;
    }

    ColyseusRoomWrapper* room_wrapper = gdext_colyseus_room_get_last_wrapper();
    if (!room_wrapper) {
        free(token_cstr);
        return;
    }

    native_fn(
        client_wrapper->native_client,
        token_cstr,
        on_matchmaking_success,
        on_matchmaking_error,
        room_wrapper
    );

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

    if (r_ret) {
        *(GDExtensionObjectPtr*)r_ret = room_object;
    }

    free(token_cstr);
}

// Common call wrapper: extracts args from Variants, delegates to ptrcall function
typedef void (*matchmaking_ptrcall_fn)(void*, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr*, GDExtensionTypePtr);

// Call wrapper for methods with 1 String arg + optional options JSON (defaults to "{}")
static void matchmaking_call_wrapper_2(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, matchmaking_ptrcall_fn ptrcall_fn) {
    String arg0_string, arg1_string;
    constructors.string_from_variant_constructor(&arg0_string, (GDExtensionVariantPtr)p_args[0]);

    if (p_argument_count >= 2) {
        constructors.string_from_variant_constructor(&arg1_string, (GDExtensionVariantPtr)p_args[1]);
    } else {
        constructors.string_new_with_utf8_chars(&arg1_string, "{}");
    }

    GDExtensionConstTypePtr ptrcall_args[2] = {
        (GDExtensionConstTypePtr)&arg0_string,
        (GDExtensionConstTypePtr)&arg1_string,
    };

    GDExtensionObjectPtr result = NULL;
    ptrcall_fn(p_method_userdata, p_instance, ptrcall_args, &result);

    if (r_return) {
        constructors.variant_from_object_constructor(r_return, &result);
    }

    destructors.string_destructor(&arg0_string);
    destructors.string_destructor(&arg1_string);
}

// Call wrapper for methods with 1 String arg (reconnect token)
static void matchmaking_call_wrapper_1(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionVariantPtr r_return, matchmaking_ptrcall_fn ptrcall_fn) {
    String arg_string;
    constructors.string_from_variant_constructor(&arg_string, (GDExtensionVariantPtr)p_args[0]);

    GDExtensionConstTypePtr ptrcall_args[1] = { (GDExtensionConstTypePtr)&arg_string };

    GDExtensionObjectPtr result = NULL;
    ptrcall_fn(p_method_userdata, p_instance, ptrcall_args, &result);

    if (r_return) {
        constructors.variant_from_object_constructor(r_return, &result);
    }

    destructors.string_destructor(&arg_string);
}

// =============================================================================
// Matchmaking method implementations
// =============================================================================

// join_or_create(room_name: String, options_json: String)
void gdext_colyseus_client_join_or_create_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    matchmaking_ptrcall_with_options(p_instance, p_args, r_ret, colyseus_client_join_or_create);
}
void gdext_colyseus_client_join_or_create(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)r_error;
    matchmaking_call_wrapper_2(p_method_userdata, p_instance, p_args, p_argument_count, r_return, gdext_colyseus_client_join_or_create_ptrcall);
}

// create(room_name: String, options_json: String)
void gdext_colyseus_client_create_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    matchmaking_ptrcall_with_options(p_instance, p_args, r_ret, colyseus_client_create_room);
}
void gdext_colyseus_client_create(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)r_error;
    matchmaking_call_wrapper_2(p_method_userdata, p_instance, p_args, p_argument_count, r_return, gdext_colyseus_client_create_ptrcall);
}

// join(room_name: String, options_json: String)
void gdext_colyseus_client_join_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    matchmaking_ptrcall_with_options(p_instance, p_args, r_ret, colyseus_client_join);
}
void gdext_colyseus_client_join(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)r_error;
    matchmaking_call_wrapper_2(p_method_userdata, p_instance, p_args, p_argument_count, r_return, gdext_colyseus_client_join_ptrcall);
}

// join_by_id(room_id: String, options_json: String)
void gdext_colyseus_client_join_by_id_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    matchmaking_ptrcall_with_options(p_instance, p_args, r_ret, colyseus_client_join_by_id);
}
void gdext_colyseus_client_join_by_id(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)r_error;
    matchmaking_call_wrapper_2(p_method_userdata, p_instance, p_args, p_argument_count, r_return, gdext_colyseus_client_join_by_id_ptrcall);
}

// reconnect(reconnection_token: String)
void gdext_colyseus_client_reconnect_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    matchmaking_ptrcall_reconnect(p_instance, p_args, r_ret, colyseus_client_reconnect);
}
void gdext_colyseus_client_reconnect(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_argument_count; (void)r_error;
    matchmaking_call_wrapper_1(p_method_userdata, p_instance, p_args, r_return, gdext_colyseus_client_reconnect_ptrcall);
}

// =============================================================================
// HTTP methods — background-threaded requests with signal-based responses
// =============================================================================

static int64_t g_http_request_counter = 0;

// =============================================================================
// HTTP response queue — thread-safe queue polled from main thread via poll()
// =============================================================================

#ifndef __EMSCRIPTEN__
#ifdef _WIN32
// Windows critical section
static CRITICAL_SECTION g_http_queue_lock;
static int g_http_queue_lock_init = 0;
#define HTTP_QUEUE_LOCK() do { if (!g_http_queue_lock_init) { InitializeCriticalSection(&g_http_queue_lock); g_http_queue_lock_init = 1; } EnterCriticalSection(&g_http_queue_lock); } while(0)
#define HTTP_QUEUE_UNLOCK() LeaveCriticalSection(&g_http_queue_lock)
#else
#include <pthread.h>
static pthread_mutex_t g_http_queue_lock = PTHREAD_MUTEX_INITIALIZER;
#define HTTP_QUEUE_LOCK() pthread_mutex_lock(&g_http_queue_lock)
#define HTTP_QUEUE_UNLOCK() pthread_mutex_unlock(&g_http_queue_lock)
#endif
#else
#define HTTP_QUEUE_LOCK()
#define HTTP_QUEUE_UNLOCK()
#endif

static gdext_http_event_t* g_http_event_head = NULL;
static gdext_http_event_t* g_http_event_tail = NULL;

// Room event queue (shares same lock macros as HTTP)
static gdext_room_event_t* g_room_event_head = NULL;
static gdext_room_event_t* g_room_event_tail = NULL;

static void http_event_push(gdext_http_event_t* event) {
    event->next = NULL;
    HTTP_QUEUE_LOCK();
    if (g_http_event_tail) {
        g_http_event_tail->next = event;
    } else {
        g_http_event_head = event;
    }
    g_http_event_tail = event;
    HTTP_QUEUE_UNLOCK();
}

static gdext_http_event_t* http_event_pop(void) {
    HTTP_QUEUE_LOCK();
    gdext_http_event_t* event = g_http_event_head;
    if (event) {
        g_http_event_head = event->next;
        if (!g_http_event_head) g_http_event_tail = NULL;
    }
    HTTP_QUEUE_UNLOCK();
    return event;
}

static void room_event_push(gdext_room_event_t* event) {
    event->next = NULL;
    HTTP_QUEUE_LOCK();
    if (g_room_event_tail) {
        g_room_event_tail->next = event;
    } else {
        g_room_event_head = event;
    }
    g_room_event_tail = event;
    HTTP_QUEUE_UNLOCK();
}

static gdext_room_event_t* room_event_pop(void) {
    HTTP_QUEUE_LOCK();
    gdext_room_event_t* event = g_room_event_head;
    if (event) {
        g_room_event_head = event->next;
        if (!g_room_event_head) g_room_event_tail = NULL;
    }
    HTTP_QUEUE_UNLOCK();
    return event;
}

static void room_event_free(gdext_room_event_t* event) {
    if (event->str_data) free(event->str_data);
    if (event->binary_data) free(event->binary_data);
    free(event);
}

typedef struct {
    colyseus_http_t* http;
    char* path;
    char* body;
    int method;  // 0=GET, 1=POST, 2=PUT, 3=DELETE, 4=PATCH
    int64_t request_id;
    GDExtensionObjectPtr client_object;
    ColyseusClientWrapper* wrapper;  // For decrementing pending count
} gdext_http_request_t;

// HTTP success trampoline — pushes to event queue (processed in poll)
static void on_gdext_http_success(const colyseus_http_response_t* response, void* userdata) {
    gdext_http_request_t* req = (gdext_http_request_t*)userdata;

    gdext_http_event_t* event = (gdext_http_event_t*)calloc(1, sizeof(gdext_http_event_t));
    if (!event) return;
    event->is_error = 0;
    event->request_id = req->request_id;
    event->status_or_code = response->status_code;
    event->body_or_message = response->body ? strdup(response->body) : strdup("");
    event->client_object = req->client_object;
    http_event_push(event);
}

// HTTP error trampoline — pushes to event queue (processed in poll)
static void on_gdext_http_error(const colyseus_http_error_t* error, void* userdata) {
    gdext_http_request_t* req = (gdext_http_request_t*)userdata;

    gdext_http_event_t* event = (gdext_http_event_t*)calloc(1, sizeof(gdext_http_event_t));
    if (!event) return;
    event->is_error = 1;
    event->request_id = req->request_id;
    event->status_or_code = error->code;
    event->body_or_message = error->message ? strdup(error->message) : strdup("");
    event->client_object = req->client_object;
    http_event_push(event);
}

// Thread function — runs the blocking HTTP call
static void gdext_http_thread_func(void* userdata) {
    gdext_http_request_t* req = (gdext_http_request_t*)userdata;
    switch (req->method) {
        case 0: colyseus_http_get(req->http, req->path, on_gdext_http_success, on_gdext_http_error, req); break;
        case 1: colyseus_http_post(req->http, req->path, req->body, on_gdext_http_success, on_gdext_http_error, req); break;
        case 2: colyseus_http_put(req->http, req->path, req->body, on_gdext_http_success, on_gdext_http_error, req); break;
        case 3: colyseus_http_delete(req->http, req->path, on_gdext_http_success, on_gdext_http_error, req); break;
        case 4: colyseus_http_patch(req->http, req->path, req->body, on_gdext_http_success, on_gdext_http_error, req); break;
    }
    if (req->wrapper) {
        __sync_fetch_and_sub(&req->wrapper->pending_http_requests, 1);
    }
    free(req->path);
    if (req->body) free(req->body);
    free(req);
}

/*
 * One detached thread per request. The core's http and auth calls BLOCK, and
 * their result reaches Godot through the polled event queue rather than a
 * signal emitted off-thread — which never fires in headless.
 */
typedef void (*gdext_request_fn)(void*);

typedef struct {
    gdext_request_fn run;
    void* request;
} gdext_thread_arg_t;

#ifndef __EMSCRIPTEN__
#ifdef _WIN32
static DWORD WINAPI gdext_request_thread(LPVOID arg) {
    gdext_thread_arg_t* a = (gdext_thread_arg_t*)arg;
    a->run(a->request);
    free(a);
    return 0;
}
#else
static void* gdext_request_thread(void* arg) {
    gdext_thread_arg_t* a = (gdext_thread_arg_t*)arg;
    a->run(a->request);
    free(a);
    return NULL;
}
#endif
#endif

static void gdext_spawn_request(gdext_request_fn run, void* request) {
#ifdef __EMSCRIPTEN__
    run(request); /* single-threaded: the browser blocks here anyway */
#else
    gdext_thread_arg_t* arg = (gdext_thread_arg_t*)calloc(1, sizeof(*arg));
    if (!arg) { run(request); return; }
    arg->run = run;
    arg->request = request;
#ifdef _WIN32
    HANDLE thread = CreateThread(NULL, 0, gdext_request_thread, arg, 0, NULL);
    if (thread) CloseHandle(thread);
#else
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&thread, &attr, gdext_request_thread, arg);
    pthread_attr_destroy(&attr);
#endif
#endif
}

// Dispatch HTTP request, returns request_id
static int64_t gdext_http_dispatch(ColyseusClientWrapper* wrapper, int method, const char* path, const char* body) {
    if (!wrapper || !wrapper->native_client || !wrapper->native_client->http) return 0;

    gdext_http_request_t* req = (gdext_http_request_t*)calloc(1, sizeof(gdext_http_request_t));
    if (!req) return 0;

    g_http_request_counter++;
    req->http = wrapper->native_client->http;
    req->path = strdup(path ? path : "");
    req->body = body ? strdup(body) : NULL;
    req->method = method;
    req->request_id = g_http_request_counter;
    req->client_object = wrapper->godot_object;
    req->wrapper = wrapper;
    __sync_fetch_and_add(&wrapper->pending_http_requests, 1);

    gdext_spawn_request(gdext_http_thread_func, req);
    return g_http_request_counter;
}

// =============================================================================
// Auth — the same road as HTTP
//
// Every auth call IS a request to /auth/*, and the core keeps the reply's
// {user, token} shape, so recomposing that object lets the result travel the
// HTTP event queue and reach GDScript through the same _http_response signal.
// No second queue, no second signal, and the callback receives exactly what
// the server sent.
// =============================================================================

typedef struct {
    colyseus_auth_t* auth;
    int op;              // gdext_auth_op_t
    char* email;
    char* password;
    char* options_json;
    int64_t request_id;
    GDExtensionObjectPtr client_object;
    ColyseusClientWrapper* wrapper;
} gdext_auth_request_t;

static void auth_event_push(gdext_auth_request_t* req, int is_error,
                            int code, char* body_or_message) {
    gdext_http_event_t* event = (gdext_http_event_t*)calloc(1, sizeof(gdext_http_event_t));
    if (!event) { free(body_or_message); return; }
    event->is_error = is_error;
    event->request_id = req->request_id;
    event->status_or_code = code;
    event->body_or_message = body_or_message;
    event->client_object = req->client_object;
    http_event_push(event);
}

static void on_gdext_auth_success(const colyseus_auth_data_t* data, void* userdata) {
    gdext_auth_request_t* req = (gdext_auth_request_t*)userdata;

    cJSON* root = cJSON_CreateObject();
    if (data && data->user_json) {
        cJSON* user = cJSON_Parse(data->user_json);
        if (user) cJSON_AddItemToObject(root, "user", user);
    }
    if (data && data->token) cJSON_AddStringToObject(root, "token", data->token);
    char* body = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);

    auth_event_push(req, 0, 200, body ? body : strdup("{}"));
}

/* The core's auth error callback carries a message but no status, so the code
 * is 0 and the server's body is the message. */
static void on_gdext_auth_error(const char* message, void* userdata) {
    gdext_auth_request_t* req = (gdext_auth_request_t*)userdata;
    auth_event_push(req, 1, 0, strdup(message ? message : "auth request failed"));
}

static void gdext_auth_thread_func(void* userdata) {
    gdext_auth_request_t* req = (gdext_auth_request_t*)userdata;
    switch ((gdext_auth_op_t)req->op) {
        case GDEXT_AUTH_GET_USER_DATA:
            colyseus_auth_get_user_data(req->auth, on_gdext_auth_success, on_gdext_auth_error, req);
            break;
        case GDEXT_AUTH_REGISTER:
            colyseus_auth_register_email_password(req->auth, req->email, req->password,
                req->options_json, on_gdext_auth_success, on_gdext_auth_error, req);
            break;
        case GDEXT_AUTH_SIGNIN:
            colyseus_auth_signin_email_password(req->auth, req->email, req->password,
                on_gdext_auth_success, on_gdext_auth_error, req);
            break;
        case GDEXT_AUTH_SIGNIN_ANONYMOUS:
            colyseus_auth_signin_anonymous(req->auth, req->options_json,
                on_gdext_auth_success, on_gdext_auth_error, req);
            break;
        case GDEXT_AUTH_SEND_PASSWORD_RESET:
            colyseus_auth_send_password_reset(req->auth, req->email,
                on_gdext_auth_success, on_gdext_auth_error, req);
            break;
    }
    if (req->wrapper) {
        __sync_fetch_and_sub(&req->wrapper->pending_http_requests, 1);
    }
    free(req->email);
    free(req->password);
    free(req->options_json);
    free(req);
}

static int64_t gdext_auth_dispatch(ColyseusClientWrapper* wrapper, int op,
                                   const char* email, const char* password,
                                   const char* options_json) {
    if (!wrapper || !wrapper->native_client || !wrapper->native_client->auth) return 0;

    gdext_auth_request_t* req = (gdext_auth_request_t*)calloc(1, sizeof(gdext_auth_request_t));
    if (!req) return 0;

    g_http_request_counter++;
    req->auth = wrapper->native_client->auth;
    req->op = op;
    req->email = email ? strdup(email) : NULL;
    req->password = password ? strdup(password) : NULL;
    req->options_json = options_json ? strdup(options_json) : NULL;
    req->request_id = g_http_request_counter;
    req->client_object = wrapper->godot_object;
    req->wrapper = wrapper;
    __sync_fetch_and_add(&wrapper->pending_http_requests, 1);

    gdext_spawn_request(gdext_auth_thread_func, req);
    return g_http_request_counter;
}

// =============================================================================
// HTTP event processing — called from poll() on main thread
// =============================================================================

// Helper: emit signal directly on main thread (NOT call_deferred)
static void emit_signal_direct(GDExtensionObjectPtr object, const char* signal_name, GDExtensionConstVariantPtr* args, int arg_count) {
    if (!object) return;

    Variant obj_variant;
    constructors.variant_from_object_constructor(&obj_variant, &object);
    StringName emit_method;
    constructors.string_name_new_with_latin1_chars(&emit_method, "emit_signal", false);
    String sig_str;
    string_from_c_str(&sig_str, signal_name);
    Variant sig_variant;
    constructors.variant_from_string_constructor(&sig_variant, &sig_str);

    GDExtensionConstVariantPtr emit_args[16];
    emit_args[0] = &sig_variant;
    for (int i = 0; i < arg_count && i < 15; i++) {
        emit_args[i + 1] = args[i];
    }

    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&obj_variant, &emit_method, emit_args, arg_count + 1, &ret, &err);

    destructors.string_name_destructor(&emit_method);
    destructors.string_destructor(&sig_str);
    destructors.variant_destroy(&sig_variant);
    destructors.variant_destroy(&ret);
    destructors.variant_destroy(&obj_variant);
}

void gdext_http_process_events(void) {
    gdext_http_event_t* event;
    while ((event = http_event_pop()) != NULL) {
        if (event->client_object) {
            int64_t rid = event->request_id;
            Variant rid_variant;
            constructors.variant_from_int_constructor(&rid_variant, &rid);

            int64_t code = event->status_or_code;
            Variant code_variant;
            constructors.variant_from_int_constructor(&code_variant, &code);

            String str;
            string_from_c_str(&str, event->body_or_message ? event->body_or_message : "");
            Variant str_variant;
            constructors.variant_from_string_constructor(&str_variant, &str);

            const char* signal_name = event->is_error ? "_http_error" : "_http_response";
            GDExtensionConstVariantPtr args[3] = { &rid_variant, &code_variant, &str_variant };
            emit_signal_direct(event->client_object, signal_name, args, 3);

            destructors.variant_destroy(&rid_variant);
            destructors.variant_destroy(&code_variant);
            destructors.string_destructor(&str);
            destructors.variant_destroy(&str_variant);
        }

        free(event->body_or_message);
        free(event);
    }
}

// =============================================================================
// Latency measurement — get_latency / select_by_latency
// The C SDK runs its own worker threads; the binding just queues results and
// emits signals from poll() (mirrors the HTTP pattern above).
// =============================================================================

typedef struct gdext_latency_event {
    int kind;                  // 0 = get_latency ok, 1 = get_latency error, 2 = select
    int64_t request_id;
    GDExtensionObjectPtr client_object;
    double latency_ms;
    int code;
    char* endpoint;            // measured/best endpoint ("" if none)
    char* message;             // error message (kind 1) or results JSON (kind 2)
    struct gdext_latency_event* next;
} gdext_latency_event_t;

static gdext_latency_event_t* g_latency_event_head = NULL;
static gdext_latency_event_t* g_latency_event_tail = NULL;

static void latency_event_push(gdext_latency_event_t* event) {
    event->next = NULL;
    HTTP_QUEUE_LOCK();
    if (g_latency_event_tail) g_latency_event_tail->next = event;
    else g_latency_event_head = event;
    g_latency_event_tail = event;
    HTTP_QUEUE_UNLOCK();
}

static gdext_latency_event_t* latency_event_pop(void) {
    HTTP_QUEUE_LOCK();
    gdext_latency_event_t* event = g_latency_event_head;
    if (event) {
        g_latency_event_head = event->next;
        if (!g_latency_event_head) g_latency_event_tail = NULL;
    }
    HTTP_QUEUE_UNLOCK();
    return event;
}

typedef struct {
    int64_t request_id;
    GDExtensionObjectPtr client_object;
} gdext_latency_request_t;

static void on_gdext_get_latency(const colyseus_latency_result_t* r, void* userdata) {
    gdext_latency_request_t* req = (gdext_latency_request_t*)userdata;
    gdext_latency_event_t* e = (gdext_latency_event_t*)calloc(1, sizeof(*e));
    if (e) {
        e->request_id = req->request_id;
        e->client_object = req->client_object;
        e->latency_ms = r->latency_ms;
        if (r->ok) {
            e->kind = 0;
            e->endpoint = strdup(r->endpoint ? r->endpoint : "");
        } else {
            e->kind = 1;
            e->code = r->error_code;
            e->message = strdup(r->error ? r->error : "latency measurement failed");
        }
        latency_event_push(e);
    }
    free(req);
}

static void on_gdext_select_by_latency(const char* best_endpoint, double best_latency_ms, void* userdata) {
    gdext_latency_request_t* req = (gdext_latency_request_t*)userdata;
    gdext_latency_event_t* e = (gdext_latency_event_t*)calloc(1, sizeof(*e));
    if (e) {
        e->kind = 2;
        e->request_id = req->request_id;
        e->client_object = req->client_object;
        e->endpoint = strdup(best_endpoint ? best_endpoint : "");
        e->latency_ms = best_endpoint ? best_latency_ms : -1.0;
        latency_event_push(e);
    }
    free(req);
}

static void gdext_latency_fill_tls(ColyseusClientWrapper* wrapper, colyseus_latency_options_t* opt) {
    if (wrapper && wrapper->native_client && wrapper->native_client->settings) {
        const colyseus_settings_t* s = wrapper->native_client->settings;
        opt->use_secure = s->use_secure_protocol;
        opt->tls_skip_verification = s->tls_skip_verification;
        opt->ca_pem_data = s->ca_pem_data;
        opt->ca_pem_len = s->ca_pem_len;
    }
}

static int64_t gdext_get_latency_dispatch(ColyseusClientWrapper* wrapper, const char* endpoint, int timeout_ms) {
    if (!wrapper) return 0;
    g_http_request_counter++;
    int64_t rid = g_http_request_counter;
    gdext_latency_request_t* req = (gdext_latency_request_t*)calloc(1, sizeof(*req));
    if (!req) return 0;
    req->request_id = rid;
    req->client_object = wrapper->godot_object;
    colyseus_latency_options_t opt = {0};
    if (timeout_ms > 0) opt.timeout_ms = timeout_ms;
    gdext_latency_fill_tls(wrapper, &opt);
    colyseus_get_latency(endpoint, &opt, on_gdext_get_latency, req);
    return rid;
}

// Read a Godot Array of Strings into a newly-allocated char*[] (count via out_count).
static char** gdext_read_string_array(const GDExtensionConstVariantPtr arr_variant, size_t* out_count) {
    *out_count = 0;
    StringName size_method;
    constructors.string_name_new_with_latin1_chars(&size_method, "size", false);
    Variant size_ret;
    GDExtensionCallError err;
    api.variant_call((Variant*)arr_variant, &size_method, NULL, 0, &size_ret, &err);
    int64_t n = 0;
    constructors.int_from_variant_constructor(&n, &size_ret);
    destructors.string_name_destructor(&size_method);
    destructors.variant_destroy(&size_ret);
    if (n <= 0) return NULL;

    Array arr;
    constructors.array_from_variant_constructor(&arr, arr_variant);
    char** out = (char**)calloc((size_t)n, sizeof(char*));
    for (int64_t i = 0; i < n; i++) {
        Variant* el = api.array_operator_index(&arr, i);
        String s;
        constructors.string_from_variant_constructor(&s, el);
        out[i] = string_to_c_str(&s);
        destructors.string_destructor(&s);
    }
    destructors.array_destructor(&arr);
    *out_count = (size_t)n;
    return out;
}

static int64_t gdext_select_by_latency_dispatch(ColyseusClientWrapper* wrapper,
                                                const char* const* endpoints, size_t count, int timeout_ms) {
    if (!wrapper) return 0;
    g_http_request_counter++;
    int64_t rid = g_http_request_counter;
    gdext_latency_request_t* req = (gdext_latency_request_t*)calloc(1, sizeof(*req));
    if (!req) return 0;
    req->request_id = rid;
    req->client_object = wrapper->godot_object;
    colyseus_latency_options_t opt = {0};
    if (timeout_ms > 0) opt.timeout_ms = timeout_ms;
    gdext_latency_fill_tls(wrapper, &opt);
    colyseus_select_by_latency(endpoints, count, &opt, on_gdext_select_by_latency, req);
    return rid;
}

// get_latency(endpoint: String, timeout_ms: int = 0) -> request_id
void gdext_colyseus_client_get_latency(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 1) return;

    String endpoint_string;
    constructors.string_from_variant_constructor(&endpoint_string, (GDExtensionVariantPtr)p_args[0]);
    char* endpoint = string_to_c_str(&endpoint_string);

    int timeout_ms = 0;
    if (p_argument_count >= 2) {
        int64_t t = 0;
        constructors.int_from_variant_constructor(&t, (GDExtensionVariantPtr)p_args[1]);
        timeout_ms = (int)t;
    }

    int64_t rid = gdext_get_latency_dispatch(wrapper, endpoint, timeout_ms);
    if (r_return) constructors.variant_from_int_constructor(r_return, &rid);

    destructors.string_destructor(&endpoint_string);
    free(endpoint);
}

// select_by_latency(endpoints: Array, timeout_ms: int = 0) -> request_id
void gdext_colyseus_client_select_by_latency(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 1) return;

    size_t count = 0;
    char** endpoints = gdext_read_string_array(p_args[0], &count);

    int timeout_ms = 0;
    if (p_argument_count >= 2) {
        int64_t t = 0;
        constructors.int_from_variant_constructor(&t, (GDExtensionVariantPtr)p_args[1]);
        timeout_ms = (int)t;
    }

    int64_t rid = 0;
    if (endpoints && count > 0)
        rid = gdext_select_by_latency_dispatch(wrapper, (const char* const*)endpoints, count, timeout_ms);
    if (r_return) constructors.variant_from_int_constructor(r_return, &rid);

    if (endpoints) {
        for (size_t i = 0; i < count; i++) free(endpoints[i]);
        free(endpoints);
    }
}

// Process queued latency events on the main thread (called from poll()).
void gdext_latency_process_events(void) {
    gdext_latency_event_t* event;
    while ((event = latency_event_pop()) != NULL) {
        if (event->client_object) {
            int64_t rid = event->request_id;
            Variant rid_v;
            constructors.variant_from_int_constructor(&rid_v, &rid);

            if (event->kind == 0) {
                double lat = event->latency_ms;
                Variant lat_v; constructors.variant_from_float_constructor(&lat_v, &lat);
                String ep; string_from_c_str(&ep, event->endpoint ? event->endpoint : "");
                Variant ep_v; constructors.variant_from_string_constructor(&ep_v, &ep);
                GDExtensionConstVariantPtr args[3] = { &rid_v, &lat_v, &ep_v };
                emit_signal_direct(event->client_object, "_latency_response", args, 3);
                destructors.variant_destroy(&lat_v);
                destructors.string_destructor(&ep);
                destructors.variant_destroy(&ep_v);
            } else if (event->kind == 1) {
                int64_t code = event->code;
                Variant code_v; constructors.variant_from_int_constructor(&code_v, &code);
                String msg; string_from_c_str(&msg, event->message ? event->message : "");
                Variant msg_v; constructors.variant_from_string_constructor(&msg_v, &msg);
                GDExtensionConstVariantPtr args[3] = { &rid_v, &code_v, &msg_v };
                emit_signal_direct(event->client_object, "_latency_error", args, 3);
                destructors.variant_destroy(&code_v);
                destructors.string_destructor(&msg);
                destructors.variant_destroy(&msg_v);
            } else {
                String ep; string_from_c_str(&ep, event->endpoint ? event->endpoint : "");
                Variant ep_v; constructors.variant_from_string_constructor(&ep_v, &ep);
                double lat = event->latency_ms;
                Variant lat_v; constructors.variant_from_float_constructor(&lat_v, &lat);
                GDExtensionConstVariantPtr args[3] = { &rid_v, &ep_v, &lat_v };
                emit_signal_direct(event->client_object, "_latency_selected", args, 3);
                destructors.string_destructor(&ep);
                destructors.variant_destroy(&ep_v);
                destructors.variant_destroy(&lat_v);
            }
            destructors.variant_destroy(&rid_v);
        }
        free(event->endpoint);
        free(event->message);
        free(event);
    }
}

void gdext_room_process_events(void) {
    gdext_room_event_t* event;
    while ((event = room_event_pop()) != NULL) {
        if (!event->room_object) {
            room_event_free(event);
            continue;
        }

        switch (event->type) {
            case ROOM_EVENT_JOIN:
                emit_signal_direct(event->room_object, "joined", NULL, 0);
                break;

            case ROOM_EVENT_STATE_CHANGE:
                emit_signal_direct(event->room_object, "state_changed", NULL, 0);
                break;

            case ROOM_EVENT_ERROR: {
                int64_t code = event->code;
                Variant code_variant;
                constructors.variant_from_int_constructor(&code_variant, &code);
                String msg;
                string_from_c_str(&msg, event->str_data ? event->str_data : "");
                Variant msg_variant;
                constructors.variant_from_string_constructor(&msg_variant, &msg);

                GDExtensionConstVariantPtr args[2] = { &code_variant, &msg_variant };
                emit_signal_direct(event->room_object, "error", args, 2);

                destructors.variant_destroy(&code_variant);
                destructors.string_destructor(&msg);
                destructors.variant_destroy(&msg_variant);
                break;
            }

            case ROOM_EVENT_LEAVE: {
                int64_t code = event->code;
                Variant code_variant;
                constructors.variant_from_int_constructor(&code_variant, &code);
                String reason;
                string_from_c_str(&reason, event->str_data ? event->str_data : "");
                Variant reason_variant;
                constructors.variant_from_string_constructor(&reason_variant, &reason);

                GDExtensionConstVariantPtr args[2] = { &code_variant, &reason_variant };
                emit_signal_direct(event->room_object, "left", args, 2);

                destructors.variant_destroy(&code_variant);
                destructors.string_destructor(&reason);
                destructors.variant_destroy(&reason_variant);
                break;
            }

            case ROOM_EVENT_DROP: {
                int64_t code = event->code;
                Variant code_variant;
                constructors.variant_from_int_constructor(&code_variant, &code);
                String reason;
                string_from_c_str(&reason, event->str_data ? event->str_data : "");
                Variant reason_variant;
                constructors.variant_from_string_constructor(&reason_variant, &reason);

                GDExtensionConstVariantPtr args[2] = { &code_variant, &reason_variant };
                emit_signal_direct(event->room_object, "dropped", args, 2);

                destructors.variant_destroy(&code_variant);
                destructors.string_destructor(&reason);
                destructors.variant_destroy(&reason_variant);
                break;
            }

            case ROOM_EVENT_RECONNECT:
                emit_signal_direct(event->room_object, "reconnected", NULL, 0);
                break;

            case ROOM_EVENT_MESSAGE: {
                // Decode msgpack on main thread
                String type_str;
                string_from_c_str(&type_str, event->str_data ? event->str_data : "");
                Variant type_variant;
                constructors.variant_from_string_constructor(&type_variant, &type_str);

                Variant data_variant;
                bool decoded = false;
                if (event->binary_data && event->binary_len > 0) {
                    decoded = msgpack_to_godot_variant(event->binary_data, event->binary_len, &data_variant);
                }
                if (!decoded) {
                    // Fallback: nil variant
                    int64_t zero = 0;
                    constructors.variant_from_int_constructor(&data_variant, &zero);
                }

                GDExtensionConstVariantPtr args[2] = { &type_variant, &data_variant };
                emit_signal_direct(event->room_object, "message_received", args, 2);

                destructors.string_destructor(&type_str);
                destructors.variant_destroy(&type_variant);
                destructors.variant_destroy(&data_variant);
                break;
            }
        }

        room_event_free(event);
    }
}

// =============================================================================
// HTTP GDExtension method implementations (vararg — path, [body], callable)
// =============================================================================

// http_get(path: String) -> int (request_id)
/* Empty reaches the core as NULL: an absent email is not the same as "". */
static char* auth_arg(const GDExtensionConstVariantPtr* args, GDExtensionInt count, int index) {
    if (index >= count) return NULL;
    String s;
    constructors.string_from_variant_constructor(&s, (GDExtensionVariantPtr)args[index]);
    char* value = string_to_c_str(&s);
    destructors.string_destructor(&s);
    if (value && value[0] == '\0') { free(value); return NULL; }
    return value;
}

// auth_request(op: int, email: String, password: String, options_json: String) -> int
void gdext_colyseus_client_auth_request(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 1) return;

    int64_t op = 0;
    constructors.int_from_variant_constructor(&op, (GDExtensionVariantPtr)p_args[0]);

    char* email = auth_arg(p_args, p_argument_count, 1);
    char* password = auth_arg(p_args, p_argument_count, 2);
    char* options = auth_arg(p_args, p_argument_count, 3);

    int64_t rid = gdext_auth_dispatch(wrapper, (int)op, email, password, options);

    if (r_return) {
        constructors.variant_from_int_constructor(r_return, &rid);
    }
    free(email);
    free(password);
    free(options);
}

// auth_signout() -> void
void gdext_colyseus_client_auth_signout(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args; (void)r_ret;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (wrapper && wrapper->native_client && wrapper->native_client->auth) {
        colyseus_auth_signout(wrapper->native_client->auth);
    }
}

void gdext_colyseus_client_http_get(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 1) return;

    String path_string;
    constructors.string_from_variant_constructor(&path_string, (GDExtensionVariantPtr)p_args[0]);
    char* path = string_to_c_str(&path_string);

    int64_t rid = gdext_http_dispatch(wrapper, 0, path, NULL);

    if (r_return) {
        constructors.variant_from_int_constructor(r_return, &rid);
    }

    destructors.string_destructor(&path_string);
    free(path);
}

// http_post(path: String, body: String) -> int
void gdext_colyseus_client_http_post(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 2) return;

    String path_string;
    constructors.string_from_variant_constructor(&path_string, (GDExtensionVariantPtr)p_args[0]);
    char* path = string_to_c_str(&path_string);

    String body_string;
    constructors.string_from_variant_constructor(&body_string, (GDExtensionVariantPtr)p_args[1]);
    char* body = string_to_c_str(&body_string);

    int64_t rid = gdext_http_dispatch(wrapper, 1, path, body);

    if (r_return) {
        constructors.variant_from_int_constructor(r_return, &rid);
    }

    destructors.string_destructor(&path_string);
    destructors.string_destructor(&body_string);
    free(path);
    free(body);
}

// http_put(path: String, body: String) -> int
void gdext_colyseus_client_http_put(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 2) return;

    String path_string;
    constructors.string_from_variant_constructor(&path_string, (GDExtensionVariantPtr)p_args[0]);
    char* path = string_to_c_str(&path_string);

    String body_string;
    constructors.string_from_variant_constructor(&body_string, (GDExtensionVariantPtr)p_args[1]);
    char* body = string_to_c_str(&body_string);

    int64_t rid = gdext_http_dispatch(wrapper, 2, path, body);

    if (r_return) {
        constructors.variant_from_int_constructor(r_return, &rid);
    }

    destructors.string_destructor(&path_string);
    destructors.string_destructor(&body_string);
    free(path);
    free(body);
}

// http_delete(path: String) -> int
void gdext_colyseus_client_http_delete(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 1) return;

    String path_string;
    constructors.string_from_variant_constructor(&path_string, (GDExtensionVariantPtr)p_args[0]);
    char* path = string_to_c_str(&path_string);

    int64_t rid = gdext_http_dispatch(wrapper, 3, path, NULL);

    if (r_return) {
        constructors.variant_from_int_constructor(r_return, &rid);
    }

    destructors.string_destructor(&path_string);
    free(path);
}

// http_patch(path: String, body: String) -> int
void gdext_colyseus_client_http_patch(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_error;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || p_argument_count < 2) return;

    String path_string;
    constructors.string_from_variant_constructor(&path_string, (GDExtensionVariantPtr)p_args[0]);
    char* path = string_to_c_str(&path_string);

    String body_string;
    constructors.string_from_variant_constructor(&body_string, (GDExtensionVariantPtr)p_args[1]);
    char* body = string_to_c_str(&body_string);

    int64_t rid = gdext_http_dispatch(wrapper, 4, path, body);

    if (r_return) {
        constructors.variant_from_int_constructor(r_return, &rid);
    }

    destructors.string_destructor(&path_string);
    destructors.string_destructor(&body_string);
    free(path);
    free(body);
}

// =============================================================================
// Auth token methods
// =============================================================================

// auth_set_token(token: String)
void gdext_colyseus_client_auth_set_token(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)r_ret;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || !wrapper->native_client || !wrapper->native_client->http) return;

    const String* token_string = (const String*)p_args[0];
    char* token = string_to_c_str(token_string);
    colyseus_http_set_auth_token(wrapper->native_client->http, token);
    free(token);
}

// auth_get_token() -> String
void gdext_colyseus_client_auth_get_token(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (!wrapper || !r_ret) return;

    const char* token = "";
    if (wrapper->native_client && wrapper->native_client->http) {
        const char* t = colyseus_http_get_auth_token(wrapper->native_client->http);
        if (t) token = t;
    }

    string_from_c_str((String*)r_ret, token);
}
