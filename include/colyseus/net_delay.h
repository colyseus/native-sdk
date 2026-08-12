#ifndef COLYSEUS_NET_DELAY_H
#define COLYSEUS_NET_DELAY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct colyseus_room;
struct colyseus_transport;

/*
 * Network-delay injector — a debug/testing wrapper at the transport seam.
 *
 * Wraps a room's transport by swapping its send + event function pointers:
 * outbound and inbound packets are queued with a deliver-at timestamp
 * (delay + jitter, clamped monotonic so jitter never reorders) and released
 * by colyseus_netdelay_pump() on the caller's thread. close/error/open pass
 * straight through. Ported from the Godot binding's injector; used by every
 * platform's latency-simulation surface and by prediction test suites.
 *
 * A wrap armed with `always_queue_inbound` doubles as the THREAD
 * SERIALIZATION seam: inbound messages are queued even at zero injected
 * delay, so decode → acks → predict writes run only inside pump() on the
 * host's frame thread instead of the WS tick thread. Prediction hosts with
 * a polled main loop (GameMaker) arm this mode structurally.
 */

/*
 * Arm (or re-arm after a reconnect replaced the transport) the wrap on this
 * room's transport. Idempotent while the wrap is live; retires wraps whose
 * transport generation the room has moved past. `always_queue_inbound` is
 * applied only when a new wrap is created.
 */
void colyseus_netdelay_wrap(struct colyseus_room* room, bool always_queue_inbound);

/*
 * Set the injected ROUND-TRIP delay/jitter (ms, GLOBAL across wraps) and arm
 * the room's wrap if it isn't already (passthrough inbound policy).
 *
 * Both numbers are round trips, split evenly across the two directions, so
 * `set(200, 0)` yields an RTT near 200 ms — the same meaning the JS SDK's
 * `__net(delay, jitter)` has. A client's `room.clock.smoothed_rtt` should
 * land on `delay` (plus the real link), and the server's lag-comp rewind
 * depth on `render_delay + delay`.
 *
 * Zero delay + zero jitter + empty queues = passthrough (unless the wrap
 * was armed with always_queue_inbound).
 */
void colyseus_netdelay_set(struct colyseus_room* room, double delay_ms, double jitter_ms);

/* Deliver every queued packet that is due, in both directions, across all
 * wraps. Call once per frame on the host's main/frame thread. */
void colyseus_netdelay_pump(void);

/* Packets currently queued across all wraps, both directions. */
int64_t colyseus_netdelay_in_flight(void);

/* Restore the transport's original function pointers and drop the queues.
 * Call from the room teardown path BEFORE the transport is freed. */
void colyseus_netdelay_unwrap(struct colyseus_transport* t);

/* Close the room's transport with COLYSEUS_CLOSE_MAY_TRY_RECONNECT (4010):
 * the SDK sees a DROP, not a consented leave, and auto-reconnect engages. */
void colyseus_netdelay_drop(struct colyseus_room* room);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_NET_DELAY_H */
