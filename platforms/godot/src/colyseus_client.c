#include "godot_colyseus.h"
#include <colyseus/client.h>
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
    // For now, return a dummy string. We'll implement proper conversion later
    // when we need actual string data from Godot
    return strdup("");
}

GDExtensionObjectPtr gdext_colyseus_client_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)malloc(sizeof(ColyseusClientWrapper));
    wrapper->native_client = NULL; // Will be initialized on connect
    return (GDExtensionObjectPtr)wrapper;
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

void gdext_colyseus_client_connect_to(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)r_ret; // void return
    
    // p_args[0] is a pointer to a String (GDExtensionStringPtr)
    const String* endpoint = (const String*)p_args[0];
    
    ColyseusClientWrapper* wrapper = (ColyseusClientWrapper*)p_instance;
    if (wrapper) {
        char* endpoint_str = string_to_c_str(endpoint);
        // TODO: Use endpoint_str to connect
        if (endpoint_str) {
            free(endpoint_str);
        }
    }
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
