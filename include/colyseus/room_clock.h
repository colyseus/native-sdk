#ifndef COLYSEUS_ROOM_CLOCK_H
#define COLYSEUS_ROOM_CLOCK_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Per-room clock-sync + RTT estimator, fed by the TIMED prefix the server
 * prepends to state messages when the room declared input via defineInput().
 * Port of the JS SDK's RoomClock.ts (RoomClockImpl) — pure math.
 *
 * Two independent estimates:
 *   - clock offset (colyseus_room_clock_server_now): seeded by the first
 *     sample, then EMA-smoothed; updates gated to low-jitter packets (RTT
 *     within 1.2× the 10s windowed-minimum RTT), except during a 30-sample
 *     post-reset warmup.
 *   - RTT (rtt / smoothed_rtt): fed by the input ack round-trip; seeded by
 *     the first valid sample; outliers (> 4× smoothed) rejected.
 *
 * A room that never declares input never receives TIMED samples: the clock
 * then reports server_now() == now() and zeros.
 */
typedef struct colyseus_room_clock colyseus_room_clock_t;

/* Injectable monotonic ms clock (tests replace this; NULL restores default). */
extern double (*colyseus_room_clock_now_provider)(void);

colyseus_room_clock_t* colyseus_room_clock_create(void);
void colyseus_room_clock_free(colyseus_room_clock_t* clock);

/* Local monotonic clock (ms) — the un-offset base server_now() builds on. */
double colyseus_room_clock_now(const colyseus_room_clock_t* clock);

/* Estimated server clock: ms since room start (wire sNow + local offset). */
double colyseus_room_clock_server_now(const colyseus_room_clock_t* clock);

/*
 * Server clock on a SLEW-LIMITED render timeline: free-runs at 1 ms/ms and
 * servos toward server_now() (tau ~250ms), snapping past gaps > 250ms. Use
 * for DRAWING remote entities; never for server-stamped deadlines.
 */
double colyseus_room_clock_render_now(colyseus_room_clock_t* clock);

/* Set the render_now slew time-constant (ms); <= 0 disables slewing. */
void colyseus_room_clock_set_render_tau(colyseus_room_clock_t* clock, double milliseconds);

/* Most recent RTT sample (ms); 0 until the first valid sample. */
double colyseus_room_clock_rtt(const colyseus_room_clock_t* clock);

/* EMA-smoothed RTT (ms); prefer for forward-prediction. */
double colyseus_room_clock_smoothed_rtt(const colyseus_room_clock_t* clock);

/* RFC 3550-style interarrival jitter (ms) vs the advertised patch cadence. */
double colyseus_room_clock_jitter(const colyseus_room_clock_t* clock);

/* Raw sNow of the last TIMED sample — the snapshot's server-encode time. */
double colyseus_room_clock_last_server_time(const colyseus_room_clock_t* clock);

/* Server snapshot cadence (patchRate, ms); 0 until advertised. */
double colyseus_room_clock_patch_interval(const colyseus_room_clock_t* clock);

/* Feed the advertised patch cadence (ms) from the input handshake. */
void colyseus_room_clock_set_patch_interval(colyseus_room_clock_t* clock, double milliseconds);

/*
 * Feed a decoded TIMED sample: sNow (ms since room start) updates the clock
 * offset; rtt_sample (ms round-trip from the input ack, < 0 if none this
 * packet) updates the RTT estimate.
 */
void colyseus_room_clock_sample(colyseus_room_clock_t* clock, double s_now, double rtt_sample);

/* Reset all state (reconnect). tau and patch interval are config — they survive. */
void colyseus_room_clock_reset(colyseus_room_clock_t* clock);

/* Internal (tests): current clock offset estimate. */
double colyseus_room_clock_offset(const colyseus_room_clock_t* clock);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_ROOM_CLOCK_H */
