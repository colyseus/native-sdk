#ifndef FLUTTER_COLYSEUS_H
#define FLUTTER_COLYSEUS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Export macro for Flutter FFI.
 *
 * On MinGW the linker exports every global symbol *until* something is marked
 * __declspec(dllexport), at which point only the marked ones ship. Dart looks
 * up the core SDK's symbols (colyseus_predict_*, colyseus_room_input, …)
 * directly, so marking the glue would hide everything else. The Windows build
 * defines FLUTTER_NO_DLLEXPORT to keep the export-all default.
 */
#ifndef FLUTTER_EXPORT
#if defined(_WIN32) && !defined(FLUTTER_NO_DLLEXPORT)
#define FLUTTER_EXPORT __declspec(dllexport)
#elif defined(_WIN32)
#define FLUTTER_EXPORT
#else
#define FLUTTER_EXPORT __attribute__((visibility("default")))
#endif
#endif

// Event type constants
typedef enum {
    FLUTTER_EVENT_NONE = 0,
    FLUTTER_EVENT_ROOM_JOIN = 1,
    FLUTTER_EVENT_ROOM_STATE_CHANGE = 2,
    FLUTTER_EVENT_ROOM_MESSAGE = 3,
    FLUTTER_EVENT_ROOM_ERROR = 4,
    FLUTTER_EVENT_ROOM_LEAVE = 5,
    FLUTTER_EVENT_CLIENT_ERROR = 6,
    FLUTTER_EVENT_PROPERTY_CHANGE = 7,
    FLUTTER_EVENT_ITEM_ADD = 8,
    FLUTTER_EVENT_ITEM_REMOVE = 9,
    FLUTTER_EVENT_ROOM_DROP = 14,
    FLUTTER_EVENT_ROOM_RECONNECT = 15,
} flutter_event_type_t;

// =============================================================================
// Client Functions
// =============================================================================

/**
 * Create a Colyseus client
 * @param endpoint Server endpoint (e.g., "ws://localhost:2567")
 * @return Client handle (0 on failure)
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_client_create(const char* endpoint);

/**
 * Free a Colyseus client
 * @param client_handle Client handle
 */
FLUTTER_EXPORT void colyseus_flutter_client_free(intptr_t client_handle);

/**
 * Join or create a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room reference handle (0 on failure)
 */
FLUTTER_EXPORT int colyseus_flutter_client_join_or_create(intptr_t client_handle, const char* room_name, const char* options_json);

/**
 * Create a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room reference handle (0 on failure)
 */
FLUTTER_EXPORT int colyseus_flutter_client_create_room(intptr_t client_handle, const char* room_name, const char* options_json);

/**
 * Join a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room reference handle (0 on failure)
 */
FLUTTER_EXPORT int colyseus_flutter_client_join(intptr_t client_handle, const char* room_name, const char* options_json);

/**
 * Join a room by ID
 * @param client_handle Client handle
 * @param room_id Room ID
 * @param options_json Options as JSON string (or empty string)
 * @return Room reference handle (0 on failure)
 */
FLUTTER_EXPORT int colyseus_flutter_client_join_by_id(intptr_t client_handle, const char* room_id, const char* options_json);

/**
 * Reconnect to a room
 * @param client_handle Client handle
 * @param reconnection_token Reconnection token
 * @return Room reference handle (0 on failure)
 */
FLUTTER_EXPORT int colyseus_flutter_client_reconnect(intptr_t client_handle, const char* reconnection_token);

/**
 * Toggle inbound-traffic serialization (default on).
 *
 * When on, every room's transport is wrapped at join so inbound frames decode
 * inside colyseus_netdelay_pump() on the calling (Dart) thread rather than on
 * the WebSocket thread. Turn it off only for a client that never touches the
 * predict layer and drives no per-frame pump.
 *
 * Takes effect for rooms joined after the call.
 */
FLUTTER_EXPORT void colyseus_flutter_set_serialized_inbound(int enabled);

// =============================================================================
// HTTP + Auth (src/flutter_http.c)
// =============================================================================

/** Which verb a queued HTTP task runs. */
typedef enum {
    FLUTTER_HTTP_GET = 0,
    FLUTTER_HTTP_POST = 1,
    FLUTTER_HTTP_PUT = 2,
    FLUTTER_HTTP_DELETE = 3,
    FLUTTER_HTTP_PATCH = 4,
} flutter_http_method_t;

/** Which auth call a queued auth task runs. */
typedef enum {
    FLUTTER_AUTH_GET_USER_DATA = 0,
    FLUTTER_AUTH_REGISTER = 1,
    FLUTTER_AUTH_SIGNIN = 2,
    FLUTTER_AUTH_SIGNIN_ANONYMOUS = 3,
    FLUTTER_AUTH_SEND_PASSWORD_RESET = 4,
} flutter_auth_op_t;

/**
 * Queue an HTTP request on the shared worker thread.
 *
 * `callback` is a NativeCallable.listener of shape
 * `(int64 request_id, int status, char* body, int error_code, char* error_message)`.
 * On success `status`/`body` are set; on failure `status` is 0 and the error
 * pair is. Both strings are heap copies the caller frees with
 * colyseus_flutter_free_string.
 */
FLUTTER_EXPORT void colyseus_flutter_http_request(intptr_t http, int method,
    const char* path, const char* json_body, int64_t request_id, void* callback);

/**
 * Queue an auth call on the same worker.
 *
 * `arg1`/`arg2` are email/password where the op takes them, `options_json` the
 * optional payload for register and anonymous sign-in. `callback` is a
 * listener of shape `(int64 request_id, char* user_json, char* token, char* error)`;
 * a non-NULL `error` means the call failed. Strings are heap copies.
 */
FLUTTER_EXPORT void colyseus_flutter_auth_request(intptr_t auth, int op,
    const char* arg1, const char* arg2, const char* options_json,
    int64_t request_id, void* callback);

/**
 * The current auth token as a heap COPY (the core's own pointer dies on the
 * next set_token/signout). NULL when unset; free with
 * colyseus_flutter_free_string.
 */
FLUTTER_EXPORT char* colyseus_flutter_auth_get_token(intptr_t auth);

/**
 * Subscribe to auth-state changes. `callback` is a listener of shape
 * `(char* user_json, char* token)`, both heap copies.
 */
FLUTTER_EXPORT void colyseus_flutter_auth_on_change(intptr_t auth, void* callback);

// =============================================================================
// Room Functions
// =============================================================================

/**
 * Leave a room
 * @param room_handle Room reference handle
 */
FLUTTER_EXPORT void colyseus_flutter_room_leave(int room_handle);

/**
 * Free a room (after leaving)
 * @param room_handle Room reference handle
 */
FLUTTER_EXPORT void colyseus_flutter_room_free(int room_handle);

/**
 * Get room ID
 * @param room_handle Room reference handle
 * @return Room ID string (caller must NOT free)
 */
FLUTTER_EXPORT const char* colyseus_flutter_room_get_id(int room_handle);

/**
 * Get room session ID
 * @param room_handle Room reference handle
 * @return Session ID string (caller must NOT free)
 */
FLUTTER_EXPORT const char* colyseus_flutter_room_get_session_id(int room_handle);

/**
 * Get room name
 * @param room_handle Room reference handle
 * @return Room name string (caller must NOT free)
 */
FLUTTER_EXPORT const char* colyseus_flutter_room_get_name(int room_handle);

/**
 * Get room reconnection token
 * @param room_handle Room reference handle
 * @return Reconnection token string (caller must NOT free)
 */
FLUTTER_EXPORT const char* colyseus_flutter_room_get_reconnection_token(int room_handle);

/**
 * Check if room is connected
 * @param room_handle Room reference handle
 * @return 1 if connected, 0 otherwise
 */
FLUTTER_EXPORT int colyseus_flutter_room_is_connected(int room_handle);

/**
 * Whether the room is currently inside an automatic reconnection cycle
 * (after a recoverable drop, before the worker has given up or succeeded).
 * @param room_handle Room reference handle
 * @return 1 if reconnecting, 0 otherwise
 */
FLUTTER_EXPORT int colyseus_flutter_room_is_reconnecting(int room_handle);

/**
 * Configure automatic reconnection. Pass -1 for any int parameter to keep
 * its current value; `enabled` accepts 0 (off), 1 (on), or -1 (keep).
 * Defaults match the @colyseus/sdk TypeScript SDK.
 */
FLUTTER_EXPORT void colyseus_flutter_room_set_reconnection_options(int room_handle,
    int enabled,
    int max_retries,
    int min_delay_ms,
    int max_delay_ms,
    int min_uptime_ms,
    int delay_ms,
    int max_enqueued_messages);

// =============================================================================
// Room Send Functions
// =============================================================================

/**
 * Send a message using a pre-built message handle (string type)
 * @param room_handle Room reference handle
 * @param type Message type string
 * @param msg_handle Message builder handle (freed automatically)
 */
FLUTTER_EXPORT void colyseus_flutter_room_send_message(int room_handle, const char* type, intptr_t msg_handle);

/**
 * Send a message using a pre-built message handle (integer type)
 * @param room_handle Room reference handle
 * @param type Message type integer
 * @param msg_handle Message builder handle (freed automatically)
 */
FLUTTER_EXPORT void colyseus_flutter_room_send_message_int(int room_handle, int type, intptr_t msg_handle);

/**
 * Send raw bytes (ROOM_DATA_BYTES protocol)
 * @param room_handle Room reference handle
 * @param type Message type string
 * @param data Raw byte data
 * @param length Data length
 */
FLUTTER_EXPORT void colyseus_flutter_room_send_bytes(int room_handle, const char* type, const uint8_t* data, int length);

// =============================================================================
// Message Builder Functions
// =============================================================================

/**
 * Create a map message builder
 * @return Message handle
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_map(void);

/**
 * Create an array message builder
 * @return Message handle
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_array(void);

/**
 * Create a string message
 * @return Message handle
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_string(const char* value);

/**
 * Create an integer message
 * @return Message handle
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_int(int64_t value);

/**
 * Create a float message
 * @return Message handle
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_float(double value);

/**
 * Create a boolean message
 * @return Message handle
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_bool(int value);

/**
 * Create a nil message
 * @return Message handle
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_nil(void);

/**
 * Put a string value into a map message
 */
FLUTTER_EXPORT void colyseus_flutter_message_map_put_str(intptr_t msg_handle, const char* key, const char* value);

/**
 * Put an integer value into a map message
 */
FLUTTER_EXPORT void colyseus_flutter_message_map_put_int(intptr_t msg_handle, const char* key, int64_t value);

/**
 * Put a float value into a map message
 */
FLUTTER_EXPORT void colyseus_flutter_message_map_put_float(intptr_t msg_handle, const char* key, double value);

/**
 * Put a boolean value into a map message
 */
FLUTTER_EXPORT void colyseus_flutter_message_map_put_bool(intptr_t msg_handle, const char* key, int value);

/**
 * Put a nil value into a map message
 */
FLUTTER_EXPORT void colyseus_flutter_message_map_put_nil(intptr_t msg_handle, const char* key);

/**
 * Put a nested message into a map message
 */
FLUTTER_EXPORT void colyseus_flutter_message_map_put(intptr_t msg_handle, const char* key, intptr_t value_handle);

/**
 * Push a string value into an array message
 */
FLUTTER_EXPORT void colyseus_flutter_message_array_push_str(intptr_t msg_handle, const char* value);

/**
 * Push an integer value into an array message
 */
FLUTTER_EXPORT void colyseus_flutter_message_array_push_int(intptr_t msg_handle, int64_t value);

/**
 * Push a float value into an array message
 */
FLUTTER_EXPORT void colyseus_flutter_message_array_push_float(intptr_t msg_handle, double value);

/**
 * Push a boolean value into an array message
 */
FLUTTER_EXPORT void colyseus_flutter_message_array_push_bool(intptr_t msg_handle, int value);

/**
 * Push a nil value into an array message
 */
FLUTTER_EXPORT void colyseus_flutter_message_array_push_nil(intptr_t msg_handle);

/**
 * Push a nested message into an array message
 */
FLUTTER_EXPORT void colyseus_flutter_message_array_push(intptr_t msg_handle, intptr_t value_handle);

/**
 * Free a message builder
 */
FLUTTER_EXPORT void colyseus_flutter_message_free(intptr_t msg_handle);

// =============================================================================
// Event Polling Functions
// =============================================================================

/**
 * Poll for next event
 * @return Event type (0 if no events)
 */
FLUTTER_EXPORT int colyseus_flutter_poll_event(void);

/**
 * Get room handle from last polled event
 * @return Room reference handle
 */
FLUTTER_EXPORT int colyseus_flutter_event_get_room(void);

/**
 * Get error/leave code from last polled event
 * @return Code
 */
FLUTTER_EXPORT int colyseus_flutter_event_get_code(void);

/**
 * Get message/error string from last polled event
 * @return Message string (valid until next poll)
 */
FLUTTER_EXPORT const char* colyseus_flutter_event_get_message(void);

/**
 * Get message data from last polled event
 * @return Data pointer (valid until next poll)
 */
FLUTTER_EXPORT const uint8_t* colyseus_flutter_event_get_data(void);

/**
 * Get message data length from last polled event
 * @return Data length
 */
FLUTTER_EXPORT int colyseus_flutter_event_get_data_length(void);

// =============================================================================
// Message Reader Functions (for reading received messages)
// =============================================================================

/**
 * Get the message type string from current event
 * @return Message type string (valid until next poll)
 */
FLUTTER_EXPORT const char* colyseus_flutter_message_get_type_str(void);

/**
 * Get msgpack reader type of current message
 * @return colyseus_message_type_t value
 */
FLUTTER_EXPORT int colyseus_flutter_message_get_type(void);

/**
 * Read a string field from the current message (map access)
 * @return String value (valid until next poll)
 */
FLUTTER_EXPORT const char* colyseus_flutter_message_read_string(const char* key);

/**
 * Read a number field from the current message (map access)
 */
FLUTTER_EXPORT double colyseus_flutter_message_read_number(const char* key);

/**
 * Read a boolean field from the current message (map access)
 */
FLUTTER_EXPORT int colyseus_flutter_message_read_bool(const char* key);

/**
 * Read the message as a scalar string value
 */
FLUTTER_EXPORT const char* colyseus_flutter_message_read_string_value(void);

/**
 * Read the message as a scalar number value
 */
FLUTTER_EXPORT double colyseus_flutter_message_read_number_value(void);

/**
 * Get map size of current message
 */
FLUTTER_EXPORT int colyseus_flutter_message_map_size(void);

/**
 * Begin iterating map entries
 */
FLUTTER_EXPORT void colyseus_flutter_message_iter_begin(void);

/**
 * Get next map entry
 * @return 1 if entry available, 0 if done
 */
FLUTTER_EXPORT int colyseus_flutter_message_iter_next(void);

/**
 * Get current iterator key string
 */
FLUTTER_EXPORT const char* colyseus_flutter_message_iter_key(void);

/**
 * Get current iterator value type
 */
FLUTTER_EXPORT int colyseus_flutter_message_iter_value_type(void);

/**
 * Get current iterator value as string
 */
FLUTTER_EXPORT const char* colyseus_flutter_message_iter_value_string(void);

/**
 * Get current iterator value as number
 */
FLUTTER_EXPORT double colyseus_flutter_message_iter_value_number(void);

/**
 * Get array size of current message
 */
FLUTTER_EXPORT int colyseus_flutter_message_array_size(void);

/**
 * Get array element type at index
 */
FLUTTER_EXPORT int colyseus_flutter_message_array_element_type(int index);

/**
 * Get array element as string
 */
FLUTTER_EXPORT const char* colyseus_flutter_message_array_element_string(int index);

/**
 * Get array element as number
 */
FLUTTER_EXPORT double colyseus_flutter_message_array_element_number(int index);

// =============================================================================
// State / Schema Access Functions
// =============================================================================

/**
 * Get the root state pointer for a room
 * @return State instance handle (0 if not available)
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_room_get_state(int room_handle);

/**
 * Get a string field from a schema instance
 */
FLUTTER_EXPORT const char* colyseus_flutter_schema_get_string(intptr_t instance_handle, const char* field_name);

/**
 * Get a numeric field from a schema instance
 */
FLUTTER_EXPORT double colyseus_flutter_schema_get_number(intptr_t instance_handle, const char* field_name);

/**
 * Get the field type of a schema field
 * @return Field type enum value, or -1 if not found
 */
FLUTTER_EXPORT int colyseus_flutter_schema_get_field_type(intptr_t instance_handle, const char* field_name);

/**
 * Get a map value by key from a schema map field
 * @return Instance handle of the map item (0 if not found)
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_map_get(intptr_t instance_handle, const char* field_name, const char* key);

// =============================================================================
// Callbacks Functions (Schema state change listeners)
// =============================================================================

/**
 * Create a callbacks manager for a room
 * @param room_handle Room reference handle
 * @return Callbacks handle (0 on failure)
 */
FLUTTER_EXPORT intptr_t colyseus_flutter_callbacks_create(int room_handle);

/**
 * Free a callbacks manager
 */
FLUTTER_EXPORT void colyseus_flutter_callbacks_free(intptr_t callbacks_handle);

/**
 * Remove a specific callback by handle
 */
FLUTTER_EXPORT void colyseus_flutter_callbacks_remove_handle(intptr_t callbacks_handle, int callback_handle);

/**
 * Listen to property changes on a schema instance
 * @param callbacks_handle Callbacks manager handle
 * @param instance_handle Schema instance (0 for root state)
 * @param property Property name
 * @return Callback handle for unsubscription, or -1 on failure
 */
FLUTTER_EXPORT int colyseus_flutter_callbacks_listen(intptr_t callbacks_handle, intptr_t instance_handle, const char* property);

/**
 * Listen to collection item additions
 * @return Callback handle, or -1 on failure
 */
FLUTTER_EXPORT int colyseus_flutter_callbacks_on_add(intptr_t callbacks_handle, intptr_t instance_handle, const char* property);

/**
 * Listen to collection item removals
 * @return Callback handle, or -1 on failure
 */
FLUTTER_EXPORT int colyseus_flutter_callbacks_on_remove(intptr_t callbacks_handle, intptr_t instance_handle, const char* property);

// Schema event accessors (for PROPERTY_CHANGE, ITEM_ADD, ITEM_REMOVE events)

FLUTTER_EXPORT int colyseus_flutter_event_get_callback_handle(void);
FLUTTER_EXPORT intptr_t colyseus_flutter_event_get_instance(void);
FLUTTER_EXPORT double colyseus_flutter_event_get_value_number(void);
FLUTTER_EXPORT const char* colyseus_flutter_event_get_value_string(void);
FLUTTER_EXPORT double colyseus_flutter_event_get_prev_value_number(void);
FLUTTER_EXPORT const char* colyseus_flutter_event_get_prev_value_string(void);
FLUTTER_EXPORT const char* colyseus_flutter_event_get_key_string(void);
FLUTTER_EXPORT int colyseus_flutter_event_get_value_type(void);

#ifdef __cplusplus
}
#endif

#endif /* FLUTTER_COLYSEUS_H */
