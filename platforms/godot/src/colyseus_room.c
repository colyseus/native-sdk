#include "godot_colyseus.h"
#include <colyseus/room.h>
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

GDExtensionObjectPtr gdext_colyseus_room_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)malloc(sizeof(ColyseusRoomWrapper));
    wrapper->native_room = NULL; // Will be set when joining
    wrapper->godot_object = NULL; // Will be set when returned from join_or_create
    return (GDExtensionObjectPtr)wrapper;
}

void gdext_colyseus_room_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    
    printf("[ColyseusRoom] Destructor called for instance: %p\n", p_instance);
    fflush(stdout);
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper) {
        if (wrapper->native_room) {
            colyseus_room_free(wrapper->native_room);
        }
        free(wrapper);
    }
}

// Reference counting for RefCounted base class
void gdext_colyseus_room_reference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
    printf("[ColyseusRoom] Reference called\n");
    fflush(stdout);
}

void gdext_colyseus_room_unreference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
    printf("[ColyseusRoom] Unreference called\n");
    fflush(stdout);
}

void gdext_colyseus_room_send_message(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)r_ret; // void return
    
    // p_args[0] is a pointer to a String
    // p_args[1] is a pointer to a PackedByteArray
    (void)p_args;
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room) {
        // TODO: Extract String and PackedByteArray from p_args and send message
    }
}

void gdext_colyseus_room_send_message_int(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)r_ret; // void return
    
    // p_args[0] is a pointer to an int64_t (Godot's int)
    // p_args[1] is a pointer to a PackedByteArray
    (void)p_args;
    
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room) {
        // TODO: Extract int and PackedByteArray from p_args and send message
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
