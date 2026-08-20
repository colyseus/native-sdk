#ifndef COLYSEUS_PREDICT_EVENTS_H
#define COLYSEUS_PREDICT_EVENTS_H

#include "colyseus/room_clock.h"
#include "colyseus/input_handle.h"
#include "colyseus/predict/reconciler.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Typed optimistic-event CHANNEL (port of predict/predictedEventChannel.ts +
 * the internal PredictedEvents store). One logical event type end-to-end:
 * birth in the predicted sim (colyseus_step_predict inside a reconciler step
 * — live-only, replay-safe) or from UI (colyseus_event_channel_predict);
 * optimistic feedback via on_predict; settlement: confirm on the
 * authoritative signal, sim-born grace-tick auto-reject once the server
 * processed past the prediction without confirming, UI-born wall-clock TTL.
 *
 * Entries are keyed by string. Payloads are opaque pointers owned by the
 * app; after a settle callback returns (and on silent drops — clear/dispose)
 * the optional payload_free runs.
 */
typedef struct colyseus_event_channel colyseus_event_channel_t;

typedef struct {
    void (*on_predict)(void* payload, void* userdata);
    void (*on_confirm)(void* payload, void* userdata);
    void (*on_reject)(void* payload, void* userdata);
    /* a confirm settled NOTHING — the signal arrived unpredicted */
    void (*on_unpredicted)(const char* key, void* userdata);
    void (*payload_free)(void* payload);
    /* sim-born settlement deadline in input ticks (default 10) */
    int grace_ticks;
    /* UI-born eviction window (ms); 0 = the default max(2·rtt, 600) */
    double ttl_ms;
    /* min gap (ms) between on_predict fires; 0 = off */
    double cooldown_ms;
    void* userdata;
} colyseus_event_channel_options_t;

colyseus_event_channel_t* colyseus_event_channel_create(
    const colyseus_event_channel_options_t* options,
    colyseus_room_clock_t* clock /* nullable */);

void colyseus_event_channel_free(colyseus_event_channel_t* channel);

/* Predict from OUTSIDE the sim (UI-optimistic; wall-clock TTL settlement).
 * Returns false when dropped (already pending / cooldown). */
bool colyseus_event_channel_predict(colyseus_event_channel_t* channel,
    const char* key, void* payload);

/* Declare a sim-born optimistic event from inside a reconciler step —
 * fires only on the LIVE step (silently skipped on rollback replay); the
 * entry settles by server progress (grace ticks) instead of wall clock. */
void colyseus_step_predict(const colyseus_step_ctx_t* ctx,
    colyseus_event_channel_t* channel, const char* key, void* payload);

/* Is a prediction pending? NULL key = any. */
bool colyseus_event_channel_has(const colyseus_event_channel_t* channel, const char* key);
int colyseus_event_channel_pending_count(const colyseus_event_channel_t* channel);

/* The server agreed: settle `key` (NULL = every pending entry). Fires
 * on_confirm per settled entry; returns the count — 0 fires on_unpredicted. */
int colyseus_event_channel_confirm(colyseus_event_channel_t* channel, const char* key);

/* The server overruled: reject `key` (NULL = every pending). Fires on_reject. */
int colyseus_event_channel_reject(colyseus_event_channel_t* channel, const char* key);

/* Drop every pending entry SILENTLY (payload_free only). */
void colyseus_event_channel_clear(colyseus_event_channel_t* channel);

/* Per-frame drive: sim-born grace auto-rejects, then wall-clock TTL. */
void colyseus_event_channel_prune(colyseus_event_channel_t* channel);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_PREDICT_EVENTS_H */
