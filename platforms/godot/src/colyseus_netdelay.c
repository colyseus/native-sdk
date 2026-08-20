#include "colyseus_netdelay.h"

#include <colyseus/net_delay.h>
#include <colyseus/room.h>

/*
 * Thin gdext veneer over the core injector (src/network/net_delay.c). The
 * queueing/trampoline logic was born here and lifted into the core for the
 * GameMaker port — one implementation, every engine. Godot rooms keep the
 * zero-delay inbound passthrough (always_queue_inbound=false): decode on
 * the WS thread is this binding's existing threading model.
 */

void gdext_colyseus_room_set_latency(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)r_ret;
    ColyseusRoomWrapper* rw = (ColyseusRoomWrapper*)p_instance;
    /* a NULL room still updates the global delay — wrap arms on the next call
     * with a live transport, same contract as before the lift */
    colyseus_netdelay_set(rw ? rw->native_room : NULL,
        *(const double*)p_args[0], *(const double*)p_args[1]);
}

void gdext_colyseus_room_net_pump(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_instance; (void)p_args; (void)r_ret;
    colyseus_netdelay_pump();
}

void gdext_colyseus_room_net_in_flight(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_instance; (void)p_args;
    *(int64_t*)r_ret = colyseus_netdelay_in_flight();
}

void gdext_colyseus_room_drop_transport(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args; (void)r_ret;
    ColyseusRoomWrapper* rw = (ColyseusRoomWrapper*)p_instance;
    if (rw) colyseus_netdelay_drop(rw->native_room);
}

void gdext_colyseus_netdelay_unwrap(struct colyseus_transport* t) {
    colyseus_netdelay_unwrap(t);
}
