#ifndef COLYSEUS_CALLBACKS_H
#define COLYSEUS_CALLBACKS_H

#include "godot_colyseus.h"
#include <colyseus/schema/callbacks.h>
#include <colyseus/schema/decoder.h>
#include <colyseus/schema/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Maximum number of callback entries per callbacks instance
#define COLYSEUS_MAX_CALLBACK_ENTRIES 256

// Callback types
typedef enum {
    COLYSEUS_GDCB_LISTEN,
    COLYSEUS_GDCB_ON_ADD,
    COLYSEUS_GDCB_ON_REMOVE
} ColyseusGodotCallbackType;

// Callback entry - stores the GDScript callable and related info
typedef struct {
    colyseus_callback_handle_t handle;  // Native callback handle
    Variant callable;                    // GDScript Callable stored as Variant
    int ref_id;                          // Schema reference ID (0 for root state)
    char* property;                      // Property name (owned)
    ColyseusGodotCallbackType type;      // Callback type
    bool active;                         // Whether this entry is in use
    int field_type;                      // Field type from colyseus_field_type_t
    const colyseus_schema_vtable_t* item_vtable;  // For collections: vtable of items
} GodotCallbackEntry;

// ColyseusCallbacks wrapper
typedef struct {
    colyseus_callbacks_t* native_callbacks;  // Native callbacks manager
    ColyseusRoomWrapper* room_wrapper;       // Reference to room
    GDExtensionObjectPtr godot_object;       // Godot object pointer
    GodotCallbackEntry entries[COLYSEUS_MAX_CALLBACK_ENTRIES];
    int entry_count;
} ColyseusCallbacksWrapper;

// Constructor/destructor
GDExtensionObjectPtr gdext_colyseus_callbacks_constructor(void* p_class_userdata);
void gdext_colyseus_callbacks_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);

// Static factory method: ColyseusCallbacks.get(room)
void gdext_colyseus_callbacks_get(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
);

// Instance methods

// listen(target, property_or_callback, [callback]) -> int
// - listen("property", callback) - root state
// - listen(schema_dict, "property", callback) - nested schema
void gdext_colyseus_callbacks_listen(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
);

// on_add(target, property_or_callback, [callback]) -> int
void gdext_colyseus_callbacks_on_add(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
);

// on_remove(target, property_or_callback, [callback]) -> int
void gdext_colyseus_callbacks_on_remove(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
);

// remove(handle) -> void
void gdext_colyseus_callbacks_remove(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
);

// Internal: Initialize a callbacks wrapper with a room
void gdext_colyseus_callbacks_init_with_room(
    ColyseusCallbacksWrapper* wrapper,
    ColyseusRoomWrapper* room_wrapper
);

// Internal: Get the last created wrapper (for factory method)
ColyseusCallbacksWrapper* gdext_colyseus_callbacks_get_last_wrapper(void);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_CALLBACKS_H */
