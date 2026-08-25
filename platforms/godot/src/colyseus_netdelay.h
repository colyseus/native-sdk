#ifndef COLYSEUS_GODOT_NETDELAY_H
#define COLYSEUS_GODOT_NETDELAY_H

#include "godot_colyseus.h"

/*
 * Latency injector (APPS_PLAN §3) at the C transport seam: capture
 * transport->send / events.on_message, put a queue in front of each, and
 * deliver due packets from net_pump() — which the app calls once per frame
 * right after Colyseus.poll(). Two load-bearing properties, same as every
 * other port's injector:
 *
 *   - No reordering: each packet's deliver-at clamps to >= the previous
 *     one's (the wire is a stream).
 *   - Wrap AFTER the join: room.set_latency() is a no-op until the room has
 *     a live transport, so the handshake always rides an undelayed link.
 */

/* _ColyseusRoom methods */
void gdext_colyseus_room_set_latency(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);  /* (delay_ms, jitter_ms) */
void gdext_colyseus_room_net_pump(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_net_in_flight(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/* Kill the socket uncleanly (close code 4010) so the SDK sees a DROP and
 * auto-reconnects — the labs' `D` key. Native only; web has no auto-reconnect. */
void gdext_colyseus_room_drop_transport(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/* Retire a transport's wrap BEFORE the transport is destroyed (the room
 * wrapper destructor calls this) — a stale wrap would otherwise pump into
 * freed memory and permanently occupy its table slot. */
struct colyseus_transport;
void gdext_colyseus_netdelay_unwrap(struct colyseus_transport* t);

#endif /* COLYSEUS_GODOT_NETDELAY_H */
