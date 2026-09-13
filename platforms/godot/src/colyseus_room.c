#include "godot_colyseus.h"
#include "colyseus_state.h"
#include "colyseus_schema_registry.h"
#include "colyseus_gdscript_schema.h"
#include "colyseus_callbacks.h"
#include "colyseus_netdelay.h"
#include "msgpack_encoder.h"
#include <colyseus/room.h>
#include <colyseus/schema.h>
#include <colyseus/schema/decoder.h>
#include <colyseus/schema/dynamic_schema.h>
#include <stdlib.h>
#include <string.h>

// Temporary storage for the last created wrapper
// Used to pass wrapper reference from constructor to caller
static ColyseusRoomWrapper* g_last_created_room_wrapper = NULL;

// Room wrapper registry for lookup by instance ID. Grows: a fixed table used to
// refuse room #65, and Callbacks.of() on it then had no room behind it.
typedef struct {
    GDObjectInstanceID instance_id;
    ColyseusRoomWrapper* wrapper;
} room_slot_t;
static room_slot_t* g_room_registry = NULL;
static int g_room_registry_capacity = 0;

static void register_room_wrapper(GDObjectInstanceID instance_id, ColyseusRoomWrapper* wrapper) {
    for (int i = 0; i < g_room_registry_capacity; i++) {
        if (g_room_registry[i].wrapper == NULL) {
            g_room_registry[i].instance_id = instance_id;
            g_room_registry[i].wrapper = wrapper;
            return;
        }
    }
    int capacity = g_room_registry_capacity ? g_room_registry_capacity * 2 : 64;
    room_slot_t* grown = (room_slot_t*)realloc(g_room_registry, (size_t)capacity * sizeof(room_slot_t));
    if (!grown) {
        gdext_push_error("Colyseus: out of memory registering room #%d", g_room_registry_capacity + 1);
        return;
    }
    memset(grown + g_room_registry_capacity, 0,
           (size_t)(capacity - g_room_registry_capacity) * sizeof(room_slot_t));
    grown[g_room_registry_capacity].instance_id = instance_id;
    grown[g_room_registry_capacity].wrapper = wrapper;
    g_room_registry = grown;
    g_room_registry_capacity = capacity;
}

static void unregister_room_wrapper(ColyseusRoomWrapper* wrapper) {
    for (int i = 0; i < g_room_registry_capacity; i++) {
        if (g_room_registry[i].wrapper == wrapper) {
            g_room_registry[i].instance_id = 0;
            g_room_registry[i].wrapper = NULL;
            return;
        }
    }
}

ColyseusRoomWrapper* gdext_colyseus_room_get_wrapper_by_id(GDObjectInstanceID instance_id) {
    for (int i = 0; i < g_room_registry_capacity; i++) {
        if (g_room_registry[i].wrapper && g_room_registry[i].instance_id == instance_id) {
            return g_room_registry[i].wrapper;
        }
    }
    return NULL;
}

void gdext_rooms_flush_joined(void) {
    /* by index: a `joined` handler may create rooms (and grow the table) */
    for (int i = 0; i < g_room_registry_capacity; i++) {
        ColyseusRoomWrapper* wrapper = g_room_registry[i].wrapper;
        if (wrapper && wrapper->join_pending) gdext_room_deliver_joined(wrapper);
    }
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
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)calloc(1, sizeof(ColyseusRoomWrapper));
    if (!wrapper) return NULL;

    wrapper->godot_object = object;
    
    // Attach our wrapper to the Godot object
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "_ColyseusRoom", false);
    api.object_set_instance(object, &class_name, wrapper);
    destructors.string_name_destructor(&class_name);
    
    // Store wrapper for retrieval by caller (e.g., join_or_create)
    g_last_created_room_wrapper = wrapper;
    
    // Register in the global registry for lookup by instance ID
    GDObjectInstanceID instance_id = api.object_get_instance_id(object);
    register_room_wrapper(instance_id, wrapper);
    
    return object;
}

static void room_wrapper_release(void* data) {
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)data;
    /* Callbacks hook the decoder: unhook them before it goes */
    gdext_callbacks_detach_room(wrapper);
    if (wrapper->native_room) {
        /* retire any latency-injector wrap before the transport dies */
        if (wrapper->native_room->transport) {
            gdext_colyseus_netdelay_unwrap(wrapper->native_room->transport);
        }
        colyseus_room_free(wrapper->native_room);
    }
    if (wrapper->gdscript_schema_ctx) {
        gdscript_schema_context_free(wrapper->gdscript_schema_ctx);
    }
    free(wrapper);
}

void gdext_colyseus_room_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;

    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (!wrapper) return;

    unregister_room_wrapper(wrapper);
    gdext_room_events_forget(wrapper->godot_object);
    wrapper->godot_object = NULL;
    /* dropped from inside one of its own callbacks: the decode is still on the stack */
    gdext_after_dispatch(room_wrapper_release, wrapper);
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
    colyseus_room_send_encoded(wrapper->native_room, type_cstr, msgpack_data, msgpack_len);
    
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
    colyseus_room_send_int_encoded(wrapper->native_room, (int)type_int, msgpack_data, msgpack_len);
    
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
        /* consented, like the TS SDK's leave() default — else onLeave sees a drop */
        colyseus_room_leave(wrapper->native_room, true);
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

void gdext_colyseus_room_get_reconnection_token(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments

    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room && r_ret) {
        const char* token = colyseus_room_get_reconnection_token(wrapper->native_room);
        string_from_c_str((String*)r_ret, token);
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

void gdext_colyseus_room_is_connected(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args; // no arguments

    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room && r_ret) {
        bool is_connected = colyseus_room_is_connected(wrapper->native_room);
        // For bool, we cast the result directly to the pointer location
        *(GDExtensionBool*)r_ret = is_connected ? 1 : 0;
    }
}

void gdext_colyseus_room_is_reconnecting(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    (void)p_args;

    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (wrapper && wrapper->native_room && r_ret) {
        bool reconnecting = colyseus_room_is_reconnecting(wrapper->native_room);
        *(GDExtensionBool*)r_ret = reconnecting ? 1 : 0;
    }
}

/*
 * set_reconnection_options(options: Dictionary)
 *
 * Accepts a Dictionary with any subset of the following keys (omitted keys
 * keep their current value):
 *   enabled: bool
 *   max_retries: int
 *   min_delay_ms: int
 *   max_delay_ms: int
 *   min_uptime_ms: int
 *   delay_ms: int
 *   max_enqueued_messages: int
 */
void gdext_colyseus_room_set_reconnection_options(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    (void)r_return;

    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    if (!wrapper || !wrapper->native_room || p_argument_count < 1) {
        if (r_error) r_error->error = GDEXTENSION_CALL_OK;
        return;
    }

    colyseus_reconnection_options_t opts;
    colyseus_room_get_reconnection_options(wrapper->native_room, &opts);

    Dictionary dict;
    constructors.dictionary_from_variant_constructor(&dict, (GDExtensionVariantPtr)p_args[0]);

    /* dictionary_operator_index returns a writable Variant pointer; if the
     * key does not exist it returns a NIL Variant. Read its type to decide
     * whether to apply the field. */
    #define READ_INT_FIELD(KEY, FIELD) do {                              \
        String key_s;                                                    \
        constructors.string_new_with_utf8_chars(&key_s, KEY);            \
        Variant key_v;                                                   \
        constructors.variant_from_string_constructor(&key_v, &key_s);    \
        GDExtensionVariantPtr val = api.dictionary_operator_index(       \
            &dict, &key_v);                                              \
        if (val && api.variant_get_type(val) != GDEXTENSION_VARIANT_TYPE_NIL) { \
            int64_t tmp = 0;                                             \
            constructors.int_from_variant_constructor(&tmp, val);        \
            FIELD = (int)tmp;                                            \
        }                                                                \
        destructors.string_destructor(&key_s);                           \
        destructors.variant_destroy(&key_v);                             \
    } while (0)

    #define READ_BOOL_FIELD(KEY, FIELD) do {                             \
        String key_s;                                                    \
        constructors.string_new_with_utf8_chars(&key_s, KEY);            \
        Variant key_v;                                                   \
        constructors.variant_from_string_constructor(&key_v, &key_s);    \
        GDExtensionVariantPtr val = api.dictionary_operator_index(       \
            &dict, &key_v);                                              \
        if (val && api.variant_get_type(val) != GDEXTENSION_VARIANT_TYPE_NIL) { \
            GDExtensionBool tmp = 0;                                     \
            constructors.bool_from_variant_constructor(&tmp, val);       \
            FIELD = tmp ? true : false;                                  \
        }                                                                \
        destructors.string_destructor(&key_s);                           \
        destructors.variant_destroy(&key_v);                             \
    } while (0)

    READ_BOOL_FIELD("enabled", opts.enabled);
    READ_INT_FIELD("max_retries", opts.max_retries);
    READ_INT_FIELD("min_delay_ms", opts.min_delay_ms);
    READ_INT_FIELD("max_delay_ms", opts.max_delay_ms);
    READ_INT_FIELD("min_uptime_ms", opts.min_uptime_ms);
    READ_INT_FIELD("delay_ms", opts.delay_ms);
    READ_INT_FIELD("max_enqueued_messages", opts.max_enqueued_messages);

    #undef READ_INT_FIELD
    #undef READ_BOOL_FIELD

    colyseus_room_set_reconnection_options(wrapper->native_room, &opts);
    destructors.dictionary_destructor(&dict);

    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
}

/*
 * get_state() - Returns the room state
 *
 * With set_state_type(GDScript class): the typed root instance — the same
 * object on every call, kept current by the decoder (null until the room has
 * joined). Otherwise a Dictionary snapshot, rebuilt per call.
 */
void gdext_colyseus_room_get_state(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)p_args; (void)p_argument_count; (void)r_error;
    if (!r_return) return;

    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)p_instance;
    colyseus_schema_t* state = (wrapper && wrapper->native_room)
        ? colyseus_room_get_state(wrapper->native_room) : NULL;

    if (state && state->__vtable && colyseus_vtable_is_dynamic(state->__vtable)) {
        colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)state;
        if (dyn_schema->userdata) {
            api.variant_new_copy(r_return, (Variant*)dyn_schema->userdata);
            return;
        }
    }
    if (wrapper && wrapper->gdscript_schema_ctx && !state) {
        gdext_variant_new_nil((Variant*)r_return);
        return;
    }

    Dictionary result;
    constructors.dictionary_constructor(&result, NULL);
    if (state && state->__vtable) {
        colyseus_schema_to_dictionary(state, state->__vtable, &result);
    }
    constructors.variant_from_dictionary_constructor(r_return, &result);
    destructors.dictionary_destructor(&result);
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

    /* the decoder already runs on the current vtables; swapping them frees them */
    if (wrapper->native_room && wrapper->native_room->serializer) {
        gdext_push_error("Room.set_state_type() must be called before the room joins "
                         "(right after join_or_create()/create()/join() returns); ignored.");
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

/* First in the decoder's listener order (hooked at JOIN, before any Callbacks
 * or Predict exists): typed collections are current by the time app
 * callbacks run, and registrations made from here on know a decode is open. */
static void room_change_listener(colyseus_changes_t* changes, void* userdata) {
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)userdata;
    wrapper->decoding = true;
    if (wrapper->gdscript_schema_ctx && wrapper->hooked_decoder) {
        gdscript_live_apply(wrapper->gdscript_schema_ctx, wrapper->hooked_decoder->refs, changes);
    }
}

/* The decoder's GC let go of a ref: its id is free for the server to reuse. */
static void room_ref_collected(int ref_id, void* userdata) {
    ColyseusRoomWrapper* wrapper = (ColyseusRoomWrapper*)userdata;
    gdext_callbacks_ref_collected(wrapper, ref_id);
    if (wrapper->gdscript_schema_ctx) gdscript_live_collect(wrapper->gdscript_schema_ctx, ref_id);
}

void gdext_room_hook_decoder(ColyseusRoomWrapper* wrapper) {
    if (!wrapper || !wrapper->native_room || !wrapper->native_room->serializer) return;
    colyseus_decoder_t* decoder = wrapper->native_room->serializer->decoder;
    if (!decoder || decoder == wrapper->hooked_decoder) return;
    if (!colyseus_decoder_set_trigger_callback(decoder, room_change_listener, wrapper)) {
        gdext_push_error("Colyseus: the room's decoder has no change-listener slot left "
                         "(COLYSEUS_DECODER_MAX_TRIGGERS); typed collections won't update");
        return;
    }
    if (!colyseus_ref_tracker_add_collect_listener(decoder->refs, room_ref_collected, wrapper)) {
        gdext_push_error("Colyseus: the room's ref tracker has no collect-listener slot left; "
                         "removed instances keep their __ref_id");
    }
    wrapper->hooked_decoder = decoder;
}

void gdext_room_after_decode(ColyseusRoomWrapper* wrapper) {
    if (wrapper) wrapper->decoding = false;
}
