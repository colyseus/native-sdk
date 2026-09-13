#ifndef COLYSEUS_CALLBACKS_H
#define COLYSEUS_CALLBACKS_H

#include "godot_colyseus.h"
#include <colyseus/room.h>
#include <colyseus/schema/callbacks.h>
#include <colyseus/schema/decoder.h>
#include <colyseus/schema/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Callback types
typedef enum {
    COLYSEUS_GDCB_LISTEN,
    COLYSEUS_GDCB_ON_ADD,
    COLYSEUS_GDCB_ON_REMOVE,
    COLYSEUS_GDCB_ON_CHANGE
} ColyseusGodotCallbackType;

struct ColyseusCallbacksWrapper;

/*
 * One registration. Heap-allocated so its address — the userdata the core
 * calls back with — never moves while the entry table grows.
 */
typedef struct GodotCallbackEntry {
    int handle;                          // what GDScript holds (stable, > 0)
    colyseus_callback_handle_t native;   // core handle; invalid while pending
    Variant callable;
    char* property;                      // owned; NULL for on_change(instance)
    ColyseusGodotCallbackType type;
    bool active;                         // false once removed: the trampoline no-ops
    bool pending;                        // waiting for the room to join / a decode to end
    bool attaching;                      // inside the core call (immediate replays run here)
    int target_ref_id;                   // nested target's ref id (-1 = root): retired when it's collected
    colyseus_schema_t* target;           // pending nested target, validated at flush
    int field_type;
    const colyseus_schema_vtable_t* item_vtable;  // schema children
    const char* item_primitive;          // primitive children (borrowed from the vtable)
    struct ColyseusCallbacksWrapper* owner;
} GodotCallbackEntry;

typedef struct ColyseusCallbacksWrapper {
    colyseus_callbacks_t* native_callbacks;  // created once the room's decoder exists
    ColyseusRoomWrapper* room_wrapper;       // NULL once the room is gone
    GDExtensionObjectPtr godot_object;
    GodotCallbackEntry** entries;            // grows on demand, no cap
    int entry_count;
    int entry_capacity;
    int next_handle;
    int busy;                                // inside a core call that can re-enter GDScript
    bool dead;                               // object freed; memory released when idle
    bool reap_scheduled;
    bool slot_error_reported;
    struct ColyseusCallbacksWrapper* next_in_room;
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

/*
 * Registration methods return a handle for remove(), or -1 when the target
 * or field can't be resolved (an engine error names the reason).
 *
 *   listen("field", cb) / listen(target, "field", cb)       cb(value, previous)
 *   on_add("field", cb) / on_add(target, "field", cb)       cb(value, key)
 *   on_remove(...)                                          cb(value, key)
 *   on_change(cb) / on_change(target, cb)                   cb()
 *   on_change("field", cb) / on_change(target, "field", cb) cb(key, value)
 *
 * Root registrations (no target) made before the room joins are held and go
 * live right after `joined`, replaying what is already there.
 */
void gdext_colyseus_callbacks_listen(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_callbacks_on_add(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_callbacks_on_remove(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_callbacks_on_change(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

// remove(handle) -> void
void gdext_colyseus_callbacks_remove(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

// Internal: bind a callbacks wrapper to its room (and the room's list)
void gdext_colyseus_callbacks_init_with_room(ColyseusCallbacksWrapper* wrapper, ColyseusRoomWrapper* room_wrapper);

// Internal: Get the last created wrapper (for factory method)
ColyseusCallbacksWrapper* gdext_colyseus_callbacks_get_last_wrapper(void);

/* Registers what the room's Callbacks held back (before JOIN, or mid-decode). */
void gdext_callbacks_flush_room(ColyseusRoomWrapper* room_wrapper);

/* The room is being freed: unhook every Callbacks from its decoder first. */
void gdext_callbacks_detach_room(ColyseusRoomWrapper* room_wrapper);

/* The decoder's GC collected `ref_id`: retire registrations made on that
 * instance — the core already dropped them, so they'd only leak. */
void gdext_callbacks_ref_collected(ColyseusRoomWrapper* room_wrapper, int ref_id);

/*
 * A GDScript schema object or state Dictionary -> the decoded instance it
 * mirrors, via its __ref_id. Ref ids are recycled, so an object only resolves
 * to the schema whose userdata IS that object; NULL otherwise.
 */
colyseus_schema_t* gdext_resolve_schema(colyseus_room_t* room, GDExtensionConstVariantPtr target);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_CALLBACKS_H */
