#ifndef GAMEMAKER_COLYSEUS_H
#define GAMEMAKER_COLYSEUS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Export macro for GameMaker DLL functions
#ifndef GM_EXPORT
#ifdef _WIN32
#define GM_EXPORT __declspec(dllexport)
#else
#define GM_EXPORT __attribute__((visibility("default")))
#endif
#endif

// Event type constants
typedef enum {
    GM_EVENT_NONE = 0,
    GM_EVENT_ROOM_JOIN = 1,
    GM_EVENT_ROOM_STATE_CHANGE = 2,
    GM_EVENT_ROOM_MESSAGE = 3,
    GM_EVENT_ROOM_ERROR = 4,
    GM_EVENT_ROOM_LEAVE = 5,
    GM_EVENT_CLIENT_ERROR = 6,
} gm_event_type_t;

// =============================================================================
// Client Functions
// =============================================================================

/**
 * Create a Colyseus client
 * @param endpoint Server endpoint (e.g., "localhost:2567")
 * @param use_secure 1.0 for wss://, 0.0 for ws://
 * @return Client handle as double
 */
GM_EXPORT double colyseus_gm_client_create(const char* endpoint, double use_secure);

/**
 * Free a Colyseus client
 * @param client_handle Client handle
 */
GM_EXPORT void colyseus_gm_client_free(double client_handle);

/**
 * Join or create a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_join_or_create(double client_handle, const char* room_name, const char* options_json);

/**
 * Create a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_create_room(double client_handle, const char* room_name, const char* options_json);

/**
 * Join a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_join(double client_handle, const char* room_name, const char* options_json);

/**
 * Join a room by ID
 * @param client_handle Client handle
 * @param room_id Room ID
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_join_by_id(double client_handle, const char* room_id, const char* options_json);

/**
 * Reconnect to a room
 * @param client_handle Client handle
 * @param reconnection_token Reconnection token
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_reconnect(double client_handle, const char* reconnection_token);

// =============================================================================
// Room Functions
// =============================================================================

/**
 * Leave a room
 * @param room_handle Room handle
 */
GM_EXPORT void colyseus_gm_room_leave(double room_handle);

/**
 * Free a room (after leaving)
 * @param room_handle Room handle
 */
GM_EXPORT void colyseus_gm_room_free(double room_handle);

/**
 * Send a message to the room (string type)
 * @param room_handle Room handle
 * @param type Message type
 * @param data Message data as string
 */
GM_EXPORT void colyseus_gm_room_send(double room_handle, const char* type, const char* data);

/**
 * Send a message to the room with raw bytes
 * @param room_handle Room handle
 * @param type Message type
 * @param data Message data as bytes
 * @param length Data length
 */
GM_EXPORT void colyseus_gm_room_send_bytes(double room_handle, const char* type, const uint8_t* data, double length);

/**
 * Send a message to the room (integer type)
 * @param room_handle Room handle
 * @param type Message type as integer
 * @param data Message data as string
 */
GM_EXPORT void colyseus_gm_room_send_int(double room_handle, double type, const char* data);

/**
 * Get room ID
 * @param room_handle Room handle
 * @return Room ID (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_room_get_id(double room_handle);

/**
 * Get room session ID
 * @param room_handle Room handle
 * @return Session ID (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_room_get_session_id(double room_handle);

/**
 * Get room name
 * @param room_handle Room handle
 * @return Room name (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_room_get_name(double room_handle);

/**
 * Check if room has joined
 * @param room_handle Room handle
 * @return 1.0 if joined, 0.0 otherwise
 */
GM_EXPORT double colyseus_gm_room_has_joined(double room_handle);

// =============================================================================
// Event Polling Functions
// =============================================================================

/**
 * Poll for next event
 * @return Event type (0 if no events)
 */
GM_EXPORT double colyseus_gm_poll_event(void);

/**
 * Get room handle from last polled event
 * @return Room handle
 */
GM_EXPORT double colyseus_gm_event_get_room(void);

/**
 * Get error/leave code from last polled event
 * @return Code
 */
GM_EXPORT double colyseus_gm_event_get_code(void);

/**
 * Get message/error/reason from last polled event
 * @return Message string (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_event_get_message(void);

/**
 * Get message data from last polled event
 * @return Data pointer (caller must NOT free, valid until next poll)
 */
GM_EXPORT const uint8_t* colyseus_gm_event_get_data(void);

/**
 * Get message data length from last polled event
 * @return Data length
 */
GM_EXPORT double colyseus_gm_event_get_data_length(void);

#ifdef __cplusplus
}
#endif

#endif /* GAMEMAKER_COLYSEUS_H */

