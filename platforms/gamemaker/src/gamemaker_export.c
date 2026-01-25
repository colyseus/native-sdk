#include "../../../include/colyseus/client.h"
#include "../../../include/colyseus/room.h"
#include "../../../include/colyseus/settings.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Export macro for GameMaker DLL functions
#ifndef GM_EXPORT
#ifdef _WIN32
#define GM_EXPORT __declspec(dllexport)
#else
#define GM_EXPORT __attribute__((visibility("default")))
#endif
#endif

// Maximum number of events in the queue
#define MAX_EVENT_QUEUE_SIZE 1024

// Event types for GameMaker polling
typedef enum {
    GM_EVENT_NONE = 0,
    GM_EVENT_ROOM_JOIN = 1,
    GM_EVENT_ROOM_STATE_CHANGE = 2,
    GM_EVENT_ROOM_MESSAGE = 3,
    GM_EVENT_ROOM_ERROR = 4,
    GM_EVENT_ROOM_LEAVE = 5,
    GM_EVENT_CLIENT_ERROR = 6,
} gm_event_type_t;

// Event structure for the queue
typedef struct {
    gm_event_type_t type;
    double room_handle;  // Room pointer as double (for GameMaker)
    int code;
    char message[1024];
    uint8_t data[8192];  // Message data
    size_t data_length;
} gm_event_t;

// Event queue (circular buffer)
typedef struct {
    gm_event_t events[MAX_EVENT_QUEUE_SIZE];
    int head;
    int tail;
    int count;
} gm_event_queue_t;

// Global event queue
static gm_event_queue_t g_event_queue = {0};

// Current event (for event accessors)
static gm_event_t g_current_event = {0};

// Event queue functions
static void event_queue_push(const gm_event_t* event) {
    if (g_event_queue.count >= MAX_EVENT_QUEUE_SIZE) {
        // Queue is full, drop oldest event
        g_event_queue.head = (g_event_queue.head + 1) % MAX_EVENT_QUEUE_SIZE;
        g_event_queue.count--;
    }
    
    g_event_queue.events[g_event_queue.tail] = *event;
    g_event_queue.tail = (g_event_queue.tail + 1) % MAX_EVENT_QUEUE_SIZE;
    g_event_queue.count++;
}

static int event_queue_pop(gm_event_t* event) {
    if (g_event_queue.count == 0) {
        return 0;  // Queue is empty
    }
    
    *event = g_event_queue.events[g_event_queue.head];
    g_event_queue.head = (g_event_queue.head + 1) % MAX_EVENT_QUEUE_SIZE;
    g_event_queue.count--;
    return 1;
}

// Callback adapters - push events to queue instead of calling back
static void on_room_join(void* userdata) {
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_JOIN;
    event.room_handle = (double)(uintptr_t)userdata;
    event_queue_push(&event);
}

static void on_room_state_change(void* userdata) {
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_STATE_CHANGE;
    event.room_handle = (double)(uintptr_t)userdata;
    event_queue_push(&event);
}

static void on_room_message(const uint8_t* data, size_t length, void* userdata) {
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_MESSAGE;
    event.room_handle = (double)(uintptr_t)userdata;
    event.data_length = length < sizeof(event.data) ? length : sizeof(event.data);
    memcpy(event.data, data, event.data_length);
    event_queue_push(&event);
}

static void on_room_error(int code, const char* message, void* userdata) {
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_ERROR;
    event.room_handle = (double)(uintptr_t)userdata;
    event.code = code;
    strncpy(event.message, message ? message : "", sizeof(event.message) - 1);
    event_queue_push(&event);
}

static void on_room_leave(int code, const char* reason, void* userdata) {
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_LEAVE;
    event.room_handle = (double)(uintptr_t)userdata;
    event.code = code;
    strncpy(event.message, reason ? reason : "", sizeof(event.message) - 1);
    event_queue_push(&event);
}

static void on_client_room_success(colyseus_room_t* room, void* userdata) {
    // Set up room callbacks
    colyseus_room_on_join(room, on_room_join, room);
    colyseus_room_on_state_change(room, on_room_state_change, room);
    colyseus_room_on_message_any(room, on_room_message, room);
    colyseus_room_on_error(room, on_room_error, room);
    colyseus_room_on_leave(room, on_room_leave, room);
    
    // Store the room handle in userdata location
    double* room_handle_ptr = (double*)userdata;
    *room_handle_ptr = (double)(uintptr_t)room;
}

static void on_client_error(int code, const char* message, void* userdata) {
    gm_event_t event = {0};
    event.type = GM_EVENT_CLIENT_ERROR;
    event.room_handle = 0;
    event.code = code;
    strncpy(event.message, message ? message : "", sizeof(event.message) - 1);
    event_queue_push(&event);
    
    // Also set error in userdata (negative value indicates error)
    double* room_handle_ptr = (double*)userdata;
    *room_handle_ptr = -1.0;
}

// =============================================================================
// GameMaker Exported Functions
// =============================================================================

/**
 * Create a Colyseus client
 * @param endpoint Server endpoint (e.g., "localhost:2567")
 * @param use_secure 1.0 for wss://, 0.0 for ws://
 * @return Client handle as double
 */
GM_EXPORT double colyseus_gm_client_create(const char* endpoint, double use_secure) {
    colyseus_settings_t* settings = colyseus_settings_create();
    if (!settings) {
        return 0.0;
    }

    // Parse endpoint into address and port
    char* endpoint_copy = strdup(endpoint);
    char* colon = strchr(endpoint_copy, ':');

    if (colon) {
        *colon = '\0';
        colyseus_settings_set_address(settings, endpoint_copy);
        colyseus_settings_set_port(settings, colon + 1);
    } else {
        colyseus_settings_set_address(settings, endpoint_copy);
        colyseus_settings_set_port(settings, use_secure > 0.5 ? "443" : "80");
    }

    colyseus_settings_set_secure(settings, use_secure > 0.5);
    free(endpoint_copy);

    colyseus_client_t* client = colyseus_client_create(settings);
    if (!client) {
        colyseus_settings_free(settings);
        return 0.0;
    }

    printf("Creating client: %s\n", endpoint);
    
    // Note: settings ownership is transferred to client, will be freed with client
    return (double)(uintptr_t)client;
}

/**
 * Free a Colyseus client
 * @param client_handle Client handle
 */
GM_EXPORT void colyseus_gm_client_free(double client_handle) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (client) {
        colyseus_client_free(client);
    }
}

/**
 * Join or create a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_join_or_create(double client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }

    // Use stack allocation for room handle result
    static double room_handle = 0.0;
    room_handle = 0.0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    printf("Joining room: %s\n", room_name);

    colyseus_client_join_or_create(
        client,
        room_name,
        options,
        on_client_room_success,
        on_client_error,
        &room_handle
    );

    return room_handle;
}

/**
 * Create a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_create_room(double client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }
    
    static double room_handle = 0.0;
    room_handle = 0.0;
    
    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";
    
    colyseus_client_create_room(
        client,
        room_name,
        options,
        on_client_room_success,
        on_client_error,
        &room_handle
    );
    
    return room_handle;
}

/**
 * Join a room
 * @param client_handle Client handle
 * @param room_name Room name
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_join(double client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }
    
    static double room_handle = 0.0;
    room_handle = 0.0;
    
    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";
    
    colyseus_client_join(
        client,
        room_name,
        options,
        on_client_room_success,
        on_client_error,
        &room_handle
    );
    
    return room_handle;
}

/**
 * Join a room by ID
 * @param client_handle Client handle
 * @param room_id Room ID
 * @param options_json Options as JSON string (or empty string)
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_join_by_id(double client_handle, const char* room_id, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }
    
    static double room_handle = 0.0;
    room_handle = 0.0;
    
    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";
    
    colyseus_client_join_by_id(
        client,
        room_id,
        options,
        on_client_room_success,
        on_client_error,
        &room_handle
    );
    
    return room_handle;
}

/**
 * Reconnect to a room
 * @param client_handle Client handle
 * @param reconnection_token Reconnection token
 * @return Room handle as double (0.0 if async, check events)
 */
GM_EXPORT double colyseus_gm_client_reconnect(double client_handle, const char* reconnection_token) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }
    
    static double room_handle = 0.0;
    room_handle = 0.0;
    
    colyseus_client_reconnect(
        client,
        reconnection_token,
        on_client_room_success,
        on_client_error,
        &room_handle
    );
    
    return room_handle;
}

/**
 * Leave a room
 * @param room_handle Room handle
 */
GM_EXPORT void colyseus_gm_room_leave(double room_handle) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room) {
        colyseus_room_leave(room, true);
    }
}

/**
 * Free a room (after leaving)
 * @param room_handle Room handle
 */
GM_EXPORT void colyseus_gm_room_free(double room_handle) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room) {
        colyseus_room_free(room);
    }
}

/**
 * Send a message to the room (string type)
 * @param room_handle Room handle
 * @param type Message type
 * @param data Message data as string
 */
GM_EXPORT void colyseus_gm_room_send(double room_handle, const char* type, const char* data) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room && data) {
        colyseus_room_send_str(room, type, (const uint8_t*)data, strlen(data));
    }
}

/**
 * Send a message to the room with raw bytes
 * @param room_handle Room handle
 * @param type Message type
 * @param data Message data as bytes
 * @param length Data length
 */
GM_EXPORT void colyseus_gm_room_send_bytes(double room_handle, const char* type, const uint8_t* data, double length) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room && data) {
        colyseus_room_send_str(room, type, data, (size_t)length);
    }
}

/**
 * Send a message to the room (integer type)
 * @param room_handle Room handle
 * @param type Message type as integer
 * @param data Message data as string
 */
GM_EXPORT void colyseus_gm_room_send_int(double room_handle, double type, const char* data) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room && data) {
        colyseus_room_send_int(room, (int)type, (const uint8_t*)data, strlen(data));
    }
}

/**
 * Get room ID
 * @param room_handle Room handle
 * @return Room ID (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_room_get_id(double room_handle) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room) {
        const char* id = colyseus_room_get_id(room);
        return id ? id : "";
    }
    return "";
}

/**
 * Get room session ID
 * @param room_handle Room handle
 * @return Session ID (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_room_get_session_id(double room_handle) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room) {
        const char* id = colyseus_room_get_session_id(room);
        return id ? id : "";
    }
    return "";
}

/**
 * Get room name
 * @param room_handle Room handle
 * @return Room name (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_room_get_name(double room_handle) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room) {
        const char* name = colyseus_room_get_name(room);
        return name ? name : "";
    }
    return "";
}

/**
 * Check if room has joined
 * @param room_handle Room handle
 * @return 1.0 if joined, 0.0 otherwise
 */
GM_EXPORT double colyseus_gm_room_has_joined(double room_handle) {
    colyseus_room_t* room = (colyseus_room_t*)(uintptr_t)room_handle;
    if (room) {
        return colyseus_room_has_joined(room) ? 1.0 : 0.0;
    }
    return 0.0;
}

// =============================================================================
// Event Polling Functions
// =============================================================================

/**
 * Poll for next event
 * @return Event type (0 if no events)
 */
GM_EXPORT double colyseus_gm_poll_event(void) {
    if (event_queue_pop(&g_current_event)) {
        return (double)g_current_event.type;
    }
    // Clear current event when no more events
    memset(&g_current_event, 0, sizeof(g_current_event));
    return 0.0;
}

/**
 * Get room handle from last polled event
 * @return Room handle
 */
GM_EXPORT double colyseus_gm_event_get_room(void) {
    return g_current_event.room_handle;
}

/**
 * Get error/leave code from last polled event
 * @return Code
 */
GM_EXPORT double colyseus_gm_event_get_code(void) {
    return (double)g_current_event.code;
}

/**
 * Get message/error/reason from last polled event
 * @return Message string (caller must NOT free)
 */
GM_EXPORT const char* colyseus_gm_event_get_message(void) {
    return g_current_event.message;
}

/**
 * Get message data from last polled event
 * @return Data pointer (caller must NOT free, valid until next poll)
 */
GM_EXPORT const uint8_t* colyseus_gm_event_get_data(void) {
    return g_current_event.data;
}

/**
 * Get message data length from last polled event
 * @return Data length
 */
GM_EXPORT double colyseus_gm_event_get_data_length(void) {
    return (double)g_current_event.data_length;
}

