#ifndef COLYSEUS_ROOM_H
#define COLYSEUS_ROOM_H

#include "colyseus/transport.h"
#include "colyseus/protocol.h"
#include "colyseus/messages.h"
#include "colyseus/settings.h"
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "uthash.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Forward declarations */
typedef struct colyseus_room colyseus_room_t;
typedef struct colyseus_schema_serializer colyseus_schema_serializer_t;
typedef struct colyseus_schema_vtable colyseus_schema_vtable_t;

/* Room event callbacks */
typedef void (*colyseus_room_on_join_fn)(void* userdata);
typedef void (*colyseus_room_on_state_change_fn)(void* userdata);
typedef void (*colyseus_room_on_error_fn)(int code, const char* message, void* userdata);
typedef void (*colyseus_room_on_leave_fn)(int code, const char* reason, void* userdata);
typedef void (*colyseus_room_on_drop_fn)(int code, const char* reason, void* userdata);
typedef void (*colyseus_room_on_reconnect_fn)(void* userdata);

/* Reconnection configuration.
 *
 * Defaults match the @colyseus/sdk TypeScript SDK:
 *   enabled              true
 *   max_retries          15
 *   min_delay_ms         100
 *   max_delay_ms         5000
 *   min_uptime_ms        5000
 *   delay_ms             100   (base delay for backoff)
 *   max_enqueued_messages 10
 *
 * Delay for attempt N is computed as:
 *   clamp(min_delay_ms, max_delay_ms, (1 << N) * delay_ms)
 */
typedef struct {
    bool enabled;
    int max_retries;
    int min_delay_ms;
    int max_delay_ms;
    int min_uptime_ms;
    int delay_ms;
    int max_enqueued_messages;
} colyseus_reconnection_options_t;

void colyseus_reconnection_options_init_defaults(colyseus_reconnection_options_t* options);

/* Message callbacks - default (message reader, auto-decoded) */
typedef void (*colyseus_room_on_message_fn)(colyseus_message_reader_t* reader, void* userdata);
typedef void (*colyseus_room_on_message_with_type_fn)(const char* type, colyseus_message_reader_t* reader, void* userdata);

/* Message callbacks - encoded (raw msgpack bytes, platform decodes) */
typedef void (*colyseus_room_on_message_encoded_fn)(const uint8_t* data, size_t length, void* userdata);
typedef void (*colyseus_room_on_message_with_type_encoded_fn)(const char* type, const uint8_t* data, size_t length, void* userdata);

/* Message callbacks - bytes (raw bytes, ROOM_DATA_BYTES protocol) */
typedef void (*colyseus_room_on_message_bytes_fn)(const uint8_t* data, size_t length, void* userdata);
typedef void (*colyseus_room_on_message_with_type_bytes_fn)(const char* type, const uint8_t* data, size_t length, void* userdata);

/* Message handler entry for hash map */
typedef struct {
    char* key;  /* Message type as string (or "i123" for numeric) */

    /* Default callback (msgpack reader) */
    colyseus_room_on_message_fn callback;
    void* userdata;

    /* Encoded callback (raw msgpack bytes) */
    colyseus_room_on_message_encoded_fn callback_encoded;
    void* userdata_encoded;

    /* Bytes callback (raw bytes, ROOM_DATA_BYTES) */
    colyseus_room_on_message_bytes_fn callback_bytes;
    void* userdata_bytes;

    UT_hash_handle hh;
} colyseus_message_handler_t;

/* Pending outbound message buffered while disconnected. */
typedef struct colyseus_pending_msg {
    uint8_t* data;
    size_t length;
    struct colyseus_pending_msg* next;
} colyseus_pending_msg_t;

/*
 * Reply outcome of colyseus_room_request(), collapsing the wire's
 * ROOM_RESPONSE statuses:
 *
 *   OK        → ok=true,  reader = reply payload (NULL when empty), error=NULL
 *   REJECTED  → ok=false, reader = the authored rejection reason,   error=NULL
 *   ERROR     → ok=false, reader = {name, message, code?},          error="request faulted"
 *   closed    → ok=false, reader = NULL, error="connection closed ..."
 *
 * `reader` is only valid for the duration of the callback.
 */
typedef void (*colyseus_room_on_response_fn)(bool ok, colyseus_message_reader_t* reader,
    const char* error, void* userdata);

/* Reply to a colyseus_room_ping() — round-trip time in whole milliseconds. */
typedef void (*colyseus_room_on_ping_fn)(int rtt_ms, void* userdata);

/* Pending request awaiting a ROOM_RESPONSE (hash by request id). */
typedef struct colyseus_pending_request {
    uint32_t request_id;
    colyseus_room_on_response_fn callback;
    void* userdata;
    UT_hash_handle hh;
} colyseus_pending_request_t;

/* Reconnection runtime state. Internal — do not modify directly. */
typedef struct {
    colyseus_reconnection_options_t options;
    int retry_count;
    bool is_reconnecting;
    bool cancelled;

    /* FIFO queue of messages buffered while disconnected. */
    colyseus_pending_msg_t* queue_head;
    colyseus_pending_msg_t* queue_tail;
    int queue_count;

    /* Worker thread + condvar. Defined opaquely to keep platform headers out
     * of this public header. Implementation file allocates and casts. */
    void* worker;
} colyseus_reconnection_state_t;

/* Room structure */
struct colyseus_room {
    char* name;
    char* room_id;
    char* session_id;
    char* reconnection_token;
    char* serializer_id;
    bool has_joined;

    colyseus_transport_t* transport;
    colyseus_transport_factory_fn transport_factory;

    /* Saved for automatic reconnection */
    char* endpoint_url;
    const colyseus_settings_t* settings;
    uint64_t joined_at_ms;
    colyseus_reconnection_state_t reconnection;

    /* Schema serializer */
    colyseus_schema_serializer_t* serializer;
    const colyseus_schema_vtable_t* state_vtable;

    /* Connection callbacks (stored for async response) */
    void (*connect_on_success)(void* userdata);
    void (*connect_on_error)(int code, const char* message, void* userdata);
    void* connect_userdata;

    /* Event callbacks */
    colyseus_room_on_join_fn on_join;
    void* on_join_userdata;

    colyseus_room_on_state_change_fn on_state_change;
    void* on_state_change_userdata;

    colyseus_room_on_error_fn on_error;
    void* on_error_userdata;

    colyseus_room_on_leave_fn on_leave;
    void* on_leave_userdata;

    colyseus_room_on_drop_fn on_drop;
    void* on_drop_userdata;

    colyseus_room_on_reconnect_fn on_reconnect;
    void* on_reconnect_userdata;

    /* Message handlers hash map */
    colyseus_message_handler_t* message_handlers;

    /* request/response (ROOM_REQUEST / ROOM_RESPONSE) correlation state */
    colyseus_pending_request_t* pending_requests;
    uint32_t next_request_id;

    /* room-level ping (PING echo) — single in-flight measurement */
    colyseus_room_on_ping_fn ping_callback;
    void* ping_userdata;
    uint64_t ping_started_at_ms;

    /* server-time + RTT estimator (TIMED prefix); always present */
    struct colyseus_room_clock* clock;

    /* input layer — populated from the JOIN_ROOM handshake sections */
    struct colyseus_input_handle* input_handle;
    const colyseus_schema_vtable_t* input_vtable_from_reflection; /* owned (dynamic) */
    bool input_stamp_render;
    bool input_stamp_reckon;
    int input_tick_rate;   /* 0 = not advertised */
    int input_patch_rate;
    int input_sub_steps;

    /* Wildcard message handlers - default (msgpack reader) */
    colyseus_room_on_message_fn on_message_any;
    void* on_message_any_userdata;
    colyseus_room_on_message_with_type_fn on_message_any_with_type;
    void* on_message_any_with_type_userdata;

    /* Wildcard message handlers - encoded (raw msgpack bytes) */
    colyseus_room_on_message_encoded_fn on_message_any_encoded;
    void* on_message_any_encoded_userdata;
    colyseus_room_on_message_with_type_encoded_fn on_message_any_with_type_encoded;
    void* on_message_any_with_type_encoded_userdata;

    /* Wildcard message handlers - bytes (raw bytes, ROOM_DATA_BYTES) */
    colyseus_room_on_message_bytes_fn on_message_any_bytes;
    void* on_message_any_bytes_userdata;
    colyseus_room_on_message_with_type_bytes_fn on_message_any_with_type_bytes;
    void* on_message_any_with_type_bytes_userdata;
};

/* Create and destroy room */
colyseus_room_t* colyseus_room_create(const char* name, colyseus_transport_factory_fn transport_factory);
void colyseus_room_free(colyseus_room_t* room);

/* Set state type - must be called before connect for schema serialization */
void colyseus_room_set_state_type(colyseus_room_t* room, const colyseus_schema_vtable_t* state_vtable);

/* Get current state (returns pointer to schema state, or NULL if not available) */
void* colyseus_room_get_state(colyseus_room_t* room);

/* Connection */
void colyseus_room_connect(
    colyseus_room_t* room,
    const char* endpoint,
    const colyseus_settings_t* settings,
    void (*on_success)(void* userdata),
    void (*on_error)(int code, const char* message, void* userdata),
    void* userdata
);

void colyseus_room_leave(colyseus_room_t* room, bool consented);

/* Getters/Setters */
const char* colyseus_room_get_id(const colyseus_room_t* room);
void colyseus_room_set_id(colyseus_room_t* room, const char* room_id);

const char* colyseus_room_get_session_id(const colyseus_room_t* room);
void colyseus_room_set_session_id(colyseus_room_t* room, const char* session_id);

const char* colyseus_room_get_name(const colyseus_room_t* room);
bool colyseus_room_is_connected(const colyseus_room_t* room);

/*
 * Measure the round-trip time to the room over the LIVE connection (PING echo).
 * The callback fires once with the RTT in whole milliseconds. No-op when the
 * connection is not open; a new call replaces a still-pending measurement.
 */
void colyseus_room_ping(colyseus_room_t* room, colyseus_room_on_ping_fn callback, void* userdata);

/*
 * The room's server-time + RTT estimator (see room_clock.h). Always present;
 * a room whose server never calls defineInput() simply receives no TIMED
 * samples (server_now() == now(), zeros elsewhere).
 */
struct colyseus_room_clock* colyseus_room_get_clock(colyseus_room_t* room);

/*
 * Lazily create (and thereafter return) the per-room input handle (see
 * input_handle.h). Mutate the handle's data instance, then send.
 *
 * `input_vtable` may be a static vtable (schema-codegen output for the
 * server's defineInput() schema) or NULL — NULL synthesizes the schema from
 * the handshake's INPUT_REFLECTION section (dynamic vtable). Returns NULL
 * when neither source yields a schema. Later calls return the same handle
 * (options are ignored — first call wins).
 */
struct colyseus_input_handle* colyseus_room_input(
    colyseus_room_t* room,
    const colyseus_schema_vtable_t* input_vtable,
    const void* options /* colyseus_input_options_t*, NULL = defaults */);

const char* colyseus_room_get_reconnection_token(const colyseus_room_t* room);

/* Event handlers */
void colyseus_room_on_join(colyseus_room_t* room, colyseus_room_on_join_fn callback, void* userdata);
void colyseus_room_on_state_change(colyseus_room_t* room, colyseus_room_on_state_change_fn callback, void* userdata);
void colyseus_room_on_error(colyseus_room_t* room, colyseus_room_on_error_fn callback, void* userdata);
void colyseus_room_on_leave(colyseus_room_t* room, colyseus_room_on_leave_fn callback, void* userdata);
void colyseus_room_on_drop(colyseus_room_t* room, colyseus_room_on_drop_fn callback, void* userdata);
void colyseus_room_on_reconnect(colyseus_room_t* room, colyseus_room_on_reconnect_fn callback, void* userdata);

/* Reconnection options. Pass NULL to read-only fetch via the getter.
 * Setting options replaces all fields atomically. */
void colyseus_room_set_reconnection_options(colyseus_room_t* room, const colyseus_reconnection_options_t* options);
void colyseus_room_get_reconnection_options(const colyseus_room_t* room, colyseus_reconnection_options_t* out_options);
bool colyseus_room_is_reconnecting(const colyseus_room_t* room);

/* Message handlers - default (msgpack reader, auto-decoded) */
void colyseus_room_on_message(colyseus_room_t* room, const char* type, colyseus_room_on_message_fn callback, void* userdata);
void colyseus_room_on_message_int(colyseus_room_t* room, int type, colyseus_room_on_message_fn callback, void* userdata);
void colyseus_room_on_message_any(colyseus_room_t* room, colyseus_room_on_message_fn callback, void* userdata);
void colyseus_room_on_message_any_with_type(colyseus_room_t* room, colyseus_room_on_message_with_type_fn callback, void* userdata);

/* Message handlers - encoded (raw msgpack bytes, platform decodes) */
void colyseus_room_on_message_encoded(colyseus_room_t* room, const char* type, colyseus_room_on_message_encoded_fn callback, void* userdata);
void colyseus_room_on_message_int_encoded(colyseus_room_t* room, int type, colyseus_room_on_message_encoded_fn callback, void* userdata);
void colyseus_room_on_message_any_encoded(colyseus_room_t* room, colyseus_room_on_message_encoded_fn callback, void* userdata);
void colyseus_room_on_message_any_with_type_encoded(colyseus_room_t* room, colyseus_room_on_message_with_type_encoded_fn callback, void* userdata);

/* Message handlers - bytes (raw bytes, ROOM_DATA_BYTES protocol) */
void colyseus_room_on_message_bytes(colyseus_room_t* room, const char* type, colyseus_room_on_message_bytes_fn callback, void* userdata);
void colyseus_room_on_message_int_bytes(colyseus_room_t* room, int type, colyseus_room_on_message_bytes_fn callback, void* userdata);
void colyseus_room_on_message_any_bytes(colyseus_room_t* room, colyseus_room_on_message_bytes_fn callback, void* userdata);
void colyseus_room_on_message_any_with_type_bytes(colyseus_room_t* room, colyseus_room_on_message_with_type_bytes_fn callback, void* userdata);

/* Send messages (colyseus message - default, encodes automatically) */
void colyseus_room_send(colyseus_room_t* room, const char* type, colyseus_message_t* data);
void colyseus_room_send_int(colyseus_room_t* room, int type, colyseus_message_t* data);

/* Send messages (pre-encoded msgpack bytes) */
void colyseus_room_send_encoded(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length);
void colyseus_room_send_int_encoded(colyseus_room_t* room, int type, const uint8_t* message, size_t length);

/* Send raw bytes (ROOM_DATA_BYTES protocol) */
void colyseus_room_send_bytes(colyseus_room_t* room, const char* type, const uint8_t* data, size_t length);
void colyseus_room_send_int_bytes(colyseus_room_t* room, int type, const uint8_t* data, size_t length);

/*
 * Send a message and await the server's reply — the value the server
 * returns from its matching onMessage handler (ROOM_REQUEST/ROOM_RESPONSE).
 *
 * Returns the request id. The callback fires exactly once: on reply, or
 * with an error when the connection closes first. The C core has no timer
 * runtime, so there is NO automatic timeout — platforms wanting one should
 * schedule colyseus_room_cancel_request() with their own timer.
 */
uint32_t colyseus_room_request(colyseus_room_t* room, const char* type, colyseus_message_t* payload,
    colyseus_room_on_response_fn callback, void* userdata);

/* Same, with a pre-encoded msgpack payload (NULL/0 for no payload). */
uint32_t colyseus_room_request_encoded(colyseus_room_t* room, const char* type,
    const uint8_t* payload, size_t payload_length,
    colyseus_room_on_response_fn callback, void* userdata);

/* Drop a pending request (timeout/cancel path). Idempotent; a late
 * ROOM_RESPONSE for a cancelled id is silently ignored. */
void colyseus_room_cancel_request(colyseus_room_t* room, uint32_t request_id);

/* Feed one raw protocol frame through the room's dispatch — for custom
 * transports and tests. Regular transports call this internally. */
void colyseus_room_process_message(colyseus_room_t* room, const uint8_t* data, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_ROOM_H */
