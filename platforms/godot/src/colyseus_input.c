#include "colyseus_input.h"

#include <colyseus/room.h>
#include <colyseus/room_clock.h>
#include <colyseus/schema/dynamic_schema.h>
#include <predict/field_access.h>

#include <stdio.h>
#include <stdlib.h>

/* String -> malloc'd utf8 (mirrors colyseus_room.c's helper). */
static char* input_string_to_utf8(const String* p_src) {
    GDExtensionInt length = api.string_to_utf8_chars(p_src, NULL, 0);
    char* buffer = malloc((size_t)length + 1);
    if (!buffer) return NULL;
    api.string_to_utf8_chars(p_src, buffer, length);
    buffer[length] = '\0';
    return buffer;
}

/* ── class lifecycle ─────────────────────────────────────────────────── */

/* The constructor can't take arguments, so input() reaches the wrapper it
 * just made through this side channel — same pattern as colyseus_room.c's
 * g_last_created_room_wrapper. */
static ColyseusInputHandleWrapper* g_last_input_wrapper = NULL;

/* Object -> wrapper registry (rooms hold ONE handle each; 16 is plenty). */
#define MAX_INPUT_WRAPPERS 16
static ColyseusInputHandleWrapper* g_input_wrappers[MAX_INPUT_WRAPPERS];

static void input_registry_add(ColyseusInputHandleWrapper* w) {
    for (int i = 0; i < MAX_INPUT_WRAPPERS; i++) {
        if (!g_input_wrappers[i]) { g_input_wrappers[i] = w; return; }
    }
}

static void input_registry_remove(ColyseusInputHandleWrapper* w) {
    for (int i = 0; i < MAX_INPUT_WRAPPERS; i++) {
        if (g_input_wrappers[i] == w) { g_input_wrappers[i] = NULL; return; }
    }
}

ColyseusInputHandleWrapper* gdext_colyseus_input_wrapper_for_object(GDExtensionObjectPtr object) {
    if (!object) return NULL;
    for (int i = 0; i < MAX_INPUT_WRAPPERS; i++) {
        if (g_input_wrappers[i] && g_input_wrappers[i]->godot_object == object) {
            return g_input_wrappers[i];
        }
    }
    return NULL;
}

GDExtensionObjectPtr gdext_colyseus_input_handle_constructor(void* p_class_userdata) {
    (void)p_class_userdata;

    StringName parent_class_name;
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);
    GDExtensionObjectPtr object = api.classdb_construct_object(&parent_class_name);
    destructors.string_name_destructor(&parent_class_name);
    if (!object) return NULL;

    ColyseusInputHandleWrapper* wrapper = malloc(sizeof(ColyseusInputHandleWrapper));
    if (!wrapper) return NULL;
    wrapper->native = NULL;
    wrapper->godot_object = object;

    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "_ColyseusInputHandle", false);
    api.object_set_instance(object, &class_name, wrapper);
    destructors.string_name_destructor(&class_name);

    g_last_input_wrapper = wrapper;
    input_registry_add(wrapper);
    return object;
}

void gdext_colyseus_input_handle_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    /* native is owned by the room — free only the wrapper */
    ColyseusInputHandleWrapper* wrapper = (ColyseusInputHandleWrapper*)p_instance;
    input_registry_remove(wrapper);
    free(wrapper);
}

/* ── _ColyseusRoom.input() ───────────────────────────────────────────── */

void gdext_colyseus_room_input_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusRoomWrapper* rw = (ColyseusRoomWrapper*)p_instance;
    *(GDExtensionObjectPtr*)r_ret = NULL;
    if (!rw || !rw->native_room) return;

    /* NULL vtable: synthesize the input schema from the handshake's
     * INPUT_REFLECTION section. Later calls return the same handle. */
    colyseus_input_handle_t* handle = colyseus_room_input(rw->native_room, NULL, NULL);
    if (!handle) return;

    GDExtensionObjectPtr object = gdext_colyseus_input_handle_constructor(NULL);
    if (!object || !g_last_input_wrapper) return;
    g_last_input_wrapper->native = handle;

    *(GDExtensionObjectPtr*)r_ret = object;
}

/* ── clock readouts ──────────────────────────────────────────────────── */

static colyseus_room_clock_t* room_clock_of(GDExtensionClassInstancePtr p_instance) {
    ColyseusRoomWrapper* rw = (ColyseusRoomWrapper*)p_instance;
    if (!rw || !rw->native_room) return NULL;
    return colyseus_room_get_clock(rw->native_room);
}

#define CLOCK_GETTER(fn_name, clock_call)                                             \
    void fn_name(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,      \
        const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {             \
        (void)p_method_userdata; (void)p_args;                                         \
        colyseus_room_clock_t* clock = room_clock_of(p_instance);                      \
        *(double*)r_ret = clock ? clock_call : 0;                                      \
    }

CLOCK_GETTER(gdext_colyseus_room_clock_now, colyseus_room_clock_now(clock))
CLOCK_GETTER(gdext_colyseus_room_clock_server_now, colyseus_room_clock_server_now(clock))
CLOCK_GETTER(gdext_colyseus_room_clock_render_now, colyseus_room_clock_render_now(clock))
CLOCK_GETTER(gdext_colyseus_room_clock_rtt, colyseus_room_clock_rtt(clock))
CLOCK_GETTER(gdext_colyseus_room_clock_smoothed_rtt, colyseus_room_clock_smoothed_rtt(clock))
CLOCK_GETTER(gdext_colyseus_room_clock_jitter, colyseus_room_clock_jitter(clock))
CLOCK_GETTER(gdext_colyseus_room_clock_last_server_time, colyseus_room_clock_last_server_time(clock))
CLOCK_GETTER(gdext_colyseus_room_clock_patch_interval, colyseus_room_clock_patch_interval(clock))

/* ── handle methods ──────────────────────────────────────────────────── */

#define HANDLE_OF(p) ((ColyseusInputHandleWrapper*)(p))

void gdext_colyseus_input_send(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);
    *(int64_t*)r_ret = w && w->native ? colyseus_input_handle_send(w->native) : 0;
}

void gdext_colyseus_input_reset(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args; (void)r_ret;
    ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);
    if (w && w->native) colyseus_input_handle_reset(w->native);
}

void gdext_colyseus_input_set_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)r_ret;
    ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);
    if (!w || !w->native) return;
    colyseus_schema_t* data = colyseus_input_handle_data(w->native);
    if (!data || !data->__vtable) return;

    char* name = input_string_to_utf8((const String*)p_args[0]);
    if (!name) return;
    double value = *(const double*)p_args[1];

    predict_fref_t f;
    if (predict_vt_find(data->__vtable, name, &f) && predict_fref_scalar(&f)) {
        predict_fwrite(data, &f, value);
    }
    free(name);
}

void gdext_colyseus_input_get_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    *(double*)r_ret = 0;
    ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);
    if (!w || !w->native) return;
    colyseus_schema_t* data = colyseus_input_handle_data(w->native);
    if (!data || !data->__vtable) return;

    char* name = input_string_to_utf8((const String*)p_args[0]);
    if (!name) return;
    predict_fref_t f;
    if (predict_vt_find(data->__vtable, name, &f) && predict_fref_scalar(&f)) {
        *(double*)r_ret = predict_fread(data, &f);
    }
    free(name);
}

#define HANDLE_INT_GETTER(fn_name, native_call)                                       \
    void fn_name(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,      \
        const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {             \
        (void)p_method_userdata; (void)p_args;                                         \
        ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);                         \
        *(int64_t*)r_ret = w && w->native ? (int64_t)native_call : 0;                  \
    }

HANDLE_INT_GETTER(gdext_colyseus_input_pending_count, colyseus_input_handle_pending_count(w->native))
HANDLE_INT_GETTER(gdext_colyseus_input_last_processed, colyseus_input_handle_last_processed(w->native))
HANDLE_INT_GETTER(gdext_colyseus_input_sent_count, colyseus_input_handle_sent_count(w->native))
HANDLE_INT_GETTER(gdext_colyseus_input_epoch, colyseus_input_handle_epoch(w->native))
HANDLE_INT_GETTER(gdext_colyseus_input_tick_rate, colyseus_input_handle_tick_rate(w->native))
HANDLE_INT_GETTER(gdext_colyseus_input_patch_rate, colyseus_input_handle_patch_rate(w->native))

void gdext_colyseus_input_render_delay(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);
    *(double*)r_ret = w && w->native ? colyseus_input_handle_render_delay(w->native) : 0;
}

void gdext_colyseus_input_set_render_delay(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)r_ret;
    ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);
    if (w && w->native) colyseus_input_handle_set_render_delay(w->native, *(const double*)p_args[0]);
}

/* ── allow_rewind field gate ─────────────────────────────────────────── */

/* The gate context is malloc'd and deliberately never freed: the C handle
 * (room-owned) can outlive the Godot wrapper, so tying the context to either
 * lifetime risks a read-after-free at send(). One ~64-byte leak per
 * set_rewind_field call per room, bounded by the lab count. */
typedef struct { char field[64]; } input_rewind_gate_t;

static bool input_rewind_field_gate(void* data, void* userdata) {
    input_rewind_gate_t* g = (input_rewind_gate_t*)userdata;
    colyseus_schema_t* d = (colyseus_schema_t*)data;
    if (!g || !d || !d->__vtable) return true;
    predict_fref_t f;
    if (predict_vt_find(d->__vtable, g->field, &f) && predict_fref_scalar(&f)) {
        return predict_fread(d, &f) != 0;
    }
    return true;   /* unknown field: stamp everything rather than nothing */
}

void gdext_colyseus_input_set_rewind_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)r_ret;
    ColyseusInputHandleWrapper* w = HANDLE_OF(p_instance);
    if (!w || !w->native) return;
    char* name = input_string_to_utf8((const String*)p_args[0]);
    if (!name) return;
    input_rewind_gate_t* g = malloc(sizeof(input_rewind_gate_t));
    if (g) {
        snprintf(g->field, sizeof g->field, "%s", name);
        colyseus_input_handle_set_allow_rewind(w->native, input_rewind_field_gate, g);
    }
    free(name);
}
