#ifndef COLYSEUS_INPUT_HANDLE_H
#define COLYSEUS_INPUT_HANDLE_H

#include "colyseus/schema/types.h"
#include "colyseus/schema/input_encoder.h"
#include "colyseus/room_clock.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Per-room input handle returned by colyseus_room_input(). Mutate the bound
 * input instance, then call colyseus_input_handle_send() to delta-encode
 * and transmit. Port of the JS SDK's input/InputHandle.ts — wire contract:
 * PORTING/sdk-ports-input-layer.md ([19|TIMED?][stamp?][body] framing,
 * delta-coded lag-comp stamps, implicit 1-based count seq, ack → RTT
 * sample, replay ring, epoch-counted reset).
 */
typedef struct colyseus_input_handle colyseus_input_handle_t;

/* Options for colyseus_room_input(). Zero-initialize for defaults. */
typedef struct {
    bool unreliable;                        /* rejected for now (needs a datagram transport); colyseus_room_input() returns NULL */
    int history_size;                       /* unreliable ring size (default 3) */
    double render_delay;                    /* interpolation buffer (ms) */
    bool (*allow_rewind)(void* data, void* userdata); /* stamp gate (optional) */
    void* allow_rewind_userdata;
} colyseus_input_options_t;

/* Construction is internal — rooms create handles via colyseus_room_input(). */
colyseus_input_handle_t* colyseus_input_handle_create(
    colyseus_schema_t* data,
    const colyseus_schema_vtable_t* vtable,
    colyseus_input_encoder_t* encoder,          /* ownership transfers */
    bool stamp_render, bool stamp_reckon,
    const colyseus_input_options_t* options,
    int tick_rate, int patch_rate, int sub_steps, /* 0 = not advertised */
    void (*send)(const uint8_t* data, size_t length, void* userdata),
    bool (*is_open)(void* userdata),
    colyseus_room_clock_t* (*get_clock)(void* userdata),
    void* userdata);

void colyseus_input_handle_free(colyseus_input_handle_t* handle);

/* The bound input instance (mutate, then send). */
colyseus_schema_t* colyseus_input_handle_data(colyseus_input_handle_t* handle);

/*
 * Encode the staged input and send it. Always transmits one input when the
 * connection is open — a body-less frame on a no-change tick. Returns the
 * seq assigned to this input, or 0 when nothing was sent (seqs are 1-based).
 */
int colyseus_input_handle_send(colyseus_input_handle_t* handle);

/*
 * Reset encoder + round-trip state (the SDK calls this on reconnect): next
 * send emits a full snapshot; the stamp baseline re-zeroes; the epoch
 * increments so observing controllers self-reset.
 */
void colyseus_input_handle_reset(colyseus_input_handle_t* handle);

/*
 * Subscribe to sends: `listener(seq, userdata)` fires synchronously at the
 * end of each send (replay ring + reckon instant already recorded) — the
 * prediction layer observes the input stream through this. Returns a
 * subscription id for colyseus_input_handle_off_send (-1 when full).
 */
int colyseus_input_handle_on_send(colyseus_input_handle_t* handle,
    void (*listener)(int seq, void* userdata), void* userdata);
void colyseus_input_handle_off_send(colyseus_input_handle_t* handle, int subscription);

/*
 * Feed the server's last-PROCESSED input seq (decoded from the TIMED
 * prefix). Advances last_processed and returns the RTT sample for that ack,
 * or -1 when unknown.
 */
double colyseus_input_handle_ack_input(colyseus_input_handle_t* handle, int seq);

/*
 * The buffered snapshot of reliable input `seq` for reconciliation replay.
 * NULL if already acked, never sent, or aged out. The instance is REUSED —
 * read synchronously, don't retain.
 */
colyseus_schema_t* colyseus_input_handle_at(colyseus_input_handle_t* handle, int seq);

/*
 * The reckon instant (server-clock ms) stamped onto reliable input `seq`;
 * 0 when reckon stamping is off or seq is outside the valid window.
 */
double colyseus_input_handle_reckon_time_at(colyseus_input_handle_t* handle, int seq);

/*
 * Lag-comp render delay (ms): the stamp is serverNow - (render_delay + rtt/2),
 * so this MUST equal the delay the app renders remote entities at or the server
 * rewinds to an instant the client never displayed. `colyseus_predict_*` binds
 * it automatically from the Predict's lerp delay; set it by hand only when you
 * interpolate outside the predict layer. An explicit value passed to
 * colyseus_room_input() wins over the automatic binding.
 */
void colyseus_input_handle_set_render_delay(colyseus_input_handle_t* handle, double milliseconds);
double colyseus_input_handle_render_delay(const colyseus_input_handle_t* handle);

/*
 * Install (or replace) the allow_rewind stamp gate after creation — for
 * bindings whose room_input() call can't thread options through (reflection
 * handles are created on first access, options are first-call-wins). The
 * gate is consulted at send(): truthy = stamp lag-comp times on this input.
 */
void colyseus_input_handle_set_allow_rewind(colyseus_input_handle_t* handle,
    bool (*allow_rewind)(void* data, void* userdata), void* userdata);

/* Round-trip state. */
int colyseus_input_handle_sent_count(const colyseus_input_handle_t* handle);
int colyseus_input_handle_last_processed(const colyseus_input_handle_t* handle);
int colyseus_input_handle_pending_count(const colyseus_input_handle_t* handle);
int colyseus_input_handle_replay_buffer_size(const colyseus_input_handle_t* handle);
int colyseus_input_handle_epoch(const colyseus_input_handle_t* handle);

/* Server-advertised rates (0 = not advertised; sub_steps floors at 1). */
int colyseus_input_handle_tick_rate(const colyseus_input_handle_t* handle);
int colyseus_input_handle_patch_rate(const colyseus_input_handle_t* handle);
int colyseus_input_handle_sub_steps(const colyseus_input_handle_t* handle);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_INPUT_HANDLE_H */
