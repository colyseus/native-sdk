#ifndef COLYSEUS_GODOT_INPUT_H
#define COLYSEUS_GODOT_INPUT_H

#include "godot_colyseus.h"
#include <colyseus/input_handle.h>

/*
 * _ColyseusInputHandle — the per-room input handle (input_handle.h) surfaced
 * to GDScript. The native handle is OWNED BY THE ROOM (lazily created by
 * colyseus_room_input); this wrapper only borrows it, so the destructor frees
 * the wrapper alone.
 *
 * The input schema comes from the handshake's INPUT_REFLECTION section
 * (dynamic vtable) — GDScript declares nothing. Fields are staged with
 * set_field/get_field; colyseus.gd wraps them in a `data` object with
 * _set/_get so `input.data.move_x = 1` reads naturally.
 */
typedef struct {
    colyseus_input_handle_t* native;   /* borrowed — the room owns it */
    GDExtensionObjectPtr godot_object;
} ColyseusInputHandleWrapper;

/* Class lifecycle */
GDExtensionObjectPtr gdext_colyseus_input_handle_constructor(void* p_class_userdata);
void gdext_colyseus_input_handle_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);

/* Godot object -> wrapper (small registry; the reconciler factory needs the
 * native handle behind an input-handle argument). NULL when unknown. */
ColyseusInputHandleWrapper* gdext_colyseus_input_wrapper_for_object(GDExtensionObjectPtr object);

/* _ColyseusRoom.input() -> _ColyseusInputHandle (ptrcall, 0 args, OBJECT ret) */
void gdext_colyseus_room_input_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/* _ColyseusRoom clock readouts (ptrcall, 0 args, FLOAT ret) */
void gdext_colyseus_room_clock_now(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_clock_server_now(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_clock_render_now(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_clock_rtt(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_clock_smoothed_rtt(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_clock_jitter(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_clock_last_server_time(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_clock_patch_interval(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/* _ColyseusInputHandle methods (ptrcall signatures) */
void gdext_colyseus_input_send(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_reset(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_set_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_get_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_pending_count(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_last_processed(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_sent_count(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_epoch(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_tick_rate(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_patch_rate(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_render_delay(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_input_set_render_delay(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
/* Field-gated allow_rewind: stamp lag-comp times only on inputs whose named
 * field is truthy (labs 06/11's fire frames). One String arg, no return. */
void gdext_colyseus_input_set_rewind_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

#endif /* COLYSEUS_GODOT_INPUT_H */
