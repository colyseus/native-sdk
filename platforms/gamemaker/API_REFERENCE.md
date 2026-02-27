# Colyseus GameMaker Extension - API Reference

This document provides a complete reference for the Colyseus SDK functions available in GameMaker.

## Quick Start

```gml
// Initialize SDK
colyseus_init();

// Create client
client = external_call(global.colyseus_client_create, "localhost:2567", 0);

// Join room
external_call(global.colyseus_client_join_or_create, client, "my_room", "{}");

// Process events (call in Step event)
colyseus_process_events();

// Cleanup
external_call(global.colyseus_client_free, client);
colyseus_free();
```

---

## Client Management

### colyseus_client_create

Creates a new Colyseus client instance.

**Signature:**
```c
double colyseus_client_create(const char* endpoint, double use_secure);
```

**GML Usage:**
```gml
client = external_call(global.colyseus_client_create, endpoint, use_secure);
```

**Parameters:**
- `endpoint` (string): Server address and port (e.g., "localhost:2567")
- `use_secure` (real): 1.0 for wss:// (secure), 0.0 for ws:// (insecure)

**Returns:** Client handle (double)

**Example:**
```gml
// Insecure connection
client = external_call(global.colyseus_client_create, "localhost:2567", 0);

// Secure connection
client = external_call(global.colyseus_client_create, "myserver.com:443", 1);
```

---

### colyseus_client_free

Destroys a client instance and frees memory.

**Signature:**
```c
void colyseus_client_free(double client_handle);
```

**GML Usage:**
```gml
external_call(global.colyseus_client_free, client);
```

**Parameters:**
- `client_handle` (real): Client handle from colyseus_client_create

**Example:**
```gml
external_call(global.colyseus_client_free, global.client);
```

---

## Room Matchmaking

### colyseus_client_join_or_create

Joins an existing room or creates a new one if none exists.

**Signature:**
```c
double colyseus_client_join_or_create(double client_handle, const char* room_name, const char* options_json);
```

**GML Usage:**
```gml
room = external_call(global.colyseus_client_join_or_create, client, room_name, options_json);
```

**Parameters:**
- `client_handle` (real): Client handle
- `room_name` (string): Name of the room to join/create
- `options_json` (string): JSON string with room options (use "{}" for none)

**Returns:** Room handle (double) - returns 0.0 initially, actual room comes via GM_EVENT_ROOM_JOIN

**Example:**
```gml
// Simple join/create
external_call(global.colyseus_client_join_or_create, client, "lobby", "{}");

// With options
var options = json_stringify({
    map: "desert",
    maxPlayers: 4
});
external_call(global.colyseus_client_join_or_create, client, "game", options);
```

---

### colyseus_client_create_room

Creates a new room.

**Signature:**
```c
double colyseus_client_create_room(double client_handle, const char* room_name, const char* options_json);
```

**GML Usage:**
```gml
room = external_call(global.colyseus_client_create_room, client, room_name, options_json);
```

**Parameters:**
- `client_handle` (real): Client handle
- `room_name` (string): Name of the room to create
- `options_json` (string): JSON string with room options

**Returns:** Room handle (double) - via GM_EVENT_ROOM_JOIN event

---

### colyseus_client_join

Joins an existing room by name.

**Signature:**
```c
double colyseus_client_join(double client_handle, const char* room_name, const char* options_json);
```

**GML Usage:**
```gml
room = external_call(global.colyseus_client_join, client, room_name, options_json);
```

**Parameters:**
- `client_handle` (real): Client handle
- `room_name` (string): Name of the room to join
- `options_json` (string): JSON string with join options

**Returns:** Room handle (double) - via GM_EVENT_ROOM_JOIN event

---

### colyseus_client_join_by_id

Joins a specific room by its unique ID.

**Signature:**
```c
double colyseus_client_join_by_id(double client_handle, const char* room_id, const char* options_json);
```

**GML Usage:**
```gml
room = external_call(global.colyseus_client_join_by_id, client, room_id, options_json);
```

**Parameters:**
- `client_handle` (real): Client handle
- `room_id` (string): Unique ID of the room
- `options_json` (string): JSON string with join options

**Returns:** Room handle (double) - via GM_EVENT_ROOM_JOIN event

---

### colyseus_client_reconnect

Reconnects to a room using a reconnection token.

**Signature:**
```c
double colyseus_client_reconnect(double client_handle, const char* reconnection_token);
```

**GML Usage:**
```gml
room = external_call(global.colyseus_client_reconnect, client, reconnection_token);
```

**Parameters:**
- `client_handle` (real): Client handle
- `reconnection_token` (string): Token from previous connection

**Returns:** Room handle (double) - via GM_EVENT_ROOM_JOIN event

---

## Room Management

### colyseus_room_leave

Leaves a room and disconnects.

**Signature:**
```c
void colyseus_room_leave(double room_handle);
```

**GML Usage:**
```gml
external_call(global.colyseus_room_leave, room);
```

**Parameters:**
- `room_handle` (real): Room handle

**Example:**
```gml
external_call(global.colyseus_room_leave, global.room);
```

---

### colyseus_room_free

Frees room memory (call after leaving).

**Signature:**
```c
void colyseus_room_free(double room_handle);
```

**GML Usage:**
```gml
external_call(global.colyseus_room_free, room);
```

**Parameters:**
- `room_handle` (real): Room handle

---

## Room Information

### colyseus_room_get_id

Gets the room's unique ID.

**Signature:**
```c
const char* colyseus_room_get_id(double room_handle);
```

**GML Usage:**
```gml
room_id = external_call(global.colyseus_room_get_id, room);
```

**Parameters:**
- `room_handle` (real): Room handle

**Returns:** Room ID string

---

### colyseus_room_get_session_id

Gets the current session ID.

**Signature:**
```c
const char* colyseus_room_get_session_id(double room_handle);
```

**GML Usage:**
```gml
session_id = external_call(global.colyseus_room_get_session_id, room);
```

**Parameters:**
- `room_handle` (real): Room handle

**Returns:** Session ID string

---

### colyseus_room_get_name

Gets the room's name.

**Signature:**
```c
const char* colyseus_room_get_name(double room_handle);
```

**GML Usage:**
```gml
room_name = external_call(global.colyseus_room_get_name, room);
```

**Parameters:**
- `room_handle` (real): Room handle

**Returns:** Room name string

---

### colyseus_room_has_joined

Checks if the room has been successfully joined.

**Signature:**
```c
double colyseus_room_has_joined(double room_handle);
```

**GML Usage:**
```gml
has_joined = external_call(global.colyseus_room_has_joined, room);
```

**Parameters:**
- `room_handle` (real): Room handle

**Returns:** 1.0 if joined, 0.0 otherwise

---

## Messaging

### colyseus_room_send

Sends a message to the room (string message type).

**Signature:**
```c
void colyseus_room_send(double room_handle, const char* type, const char* data);
```

**GML Usage:**
```gml
external_call(global.colyseus_room_send, room, type, data);
```

**Parameters:**
- `room_handle` (real): Room handle
- `type` (string): Message type identifier
- `data` (string): Message data (typically JSON)

**Example:**
```gml
var message = json_stringify({
    x: player.x,
    y: player.y
});
external_call(global.colyseus_room_send, room, "move", message);
```

---

### colyseus_room_send_int

Sends a message to the room (integer message type).

**Signature:**
```c
void colyseus_room_send_int(double room_handle, double type, const char* data);
```

**GML Usage:**
```gml
external_call(global.colyseus_room_send_int, room, type, data);
```

**Parameters:**
- `room_handle` (real): Room handle
- `type` (real): Message type as integer
- `data` (string): Message data

**Example:**
```gml
var MOVE_MESSAGE = 1;
var data = json_stringify({x: 100, y: 200});
external_call(global.colyseus_room_send_int, room, MOVE_MESSAGE, data);
```

---

## Event Polling

The SDK uses an event queue system. Call `colyseus_process_events()` in your Step event, or manually poll with these functions:

### colyseus_poll_event

Polls for the next event in the queue.

**Signature:**
```c
double colyseus_poll_event(void);
```

**GML Usage:**
```gml
event_type = external_call(global.colyseus_poll_event);
```

**Returns:** Event type code (see Event Types below), or 0 if no events

**Example:**
```gml
var event_type = external_call(global.colyseus_poll_event);
if (event_type == global.COLYSEUS_EVENT_ROOM_JOIN) {
    var room = external_call(global.colyseus_event_get_room);
    show_debug_message("Joined room: " + string(room));
}
```

---

### colyseus_event_get_room

Gets the room handle from the last polled event.

**Signature:**
```c
double colyseus_event_get_room(void);
```

**GML Usage:**
```gml
room_handle = external_call(global.colyseus_event_get_room);
```

**Returns:** Room handle (double)

---

### colyseus_event_get_code

Gets the error/leave code from the last polled event.

**Signature:**
```c
double colyseus_event_get_code(void);
```

**GML Usage:**
```gml
code = external_call(global.colyseus_event_get_code);
```

**Returns:** Status code (double)

---

### colyseus_event_get_message

Gets the message/error/reason string from the last polled event.

**Signature:**
```c
const char* colyseus_event_get_message(void);
```

**GML Usage:**
```gml
message = external_call(global.colyseus_event_get_message);
```

**Returns:** Message string

---

### colyseus_event_get_data_length

Gets the length of message data from the last polled event.

**Signature:**
```c
double colyseus_event_get_data_length(void);
```

**GML Usage:**
```gml
data_length = external_call(global.colyseus_event_get_data_length);
```

**Returns:** Data length in bytes (double)

---

## Event Types

These constants are automatically set when you call `colyseus_init()`:

| Constant | Value | Description |
|----------|-------|-------------|
| `global.COLYSEUS_EVENT_NONE` | 0 | No event |
| `global.COLYSEUS_EVENT_ROOM_JOIN` | 1 | Successfully joined a room |
| `global.COLYSEUS_EVENT_ROOM_STATE_CHANGE` | 2 | Room state has changed |
| `global.COLYSEUS_EVENT_ROOM_MESSAGE` | 3 | Received a message from the room |
| `global.COLYSEUS_EVENT_ROOM_ERROR` | 4 | Room error occurred |
| `global.COLYSEUS_EVENT_ROOM_LEAVE` | 5 | Left the room (or was kicked) |
| `global.COLYSEUS_EVENT_CLIENT_ERROR` | 6 | Client/connection error |

---

## GML Helper Functions

### colyseus_init()

Initializes the SDK and defines all external functions.

**Usage:**
```gml
colyseus_init();
```

Call this once at the start of your game (e.g., in a game controller's Create event).

---

### colyseus_free()

Frees the SDK and cleans up external function definitions.

**Usage:**
```gml
colyseus_free();
```

Call this when shutting down (e.g., in Game End event).

---

### colyseus_process_events()

Processes all pending events and dispatches them to your event handlers.

**Usage:**
```gml
colyseus_process_events();
```

Call this in a Step event to process events every frame.

**Event Handlers:**
Set up global event handlers before joining a room:

```gml
global.on_colyseus_room_join = function(room_handle) {
    // Handle room join
};

global.on_colyseus_state_change = function(room_handle) {
    // Handle state change
};

global.on_colyseus_message = function(room_handle, data_length) {
    // Handle message
    var message = external_call(global.colyseus_event_get_message);
};

global.on_colyseus_room_error = function(room_handle, code, message) {
    // Handle error
};

global.on_colyseus_room_leave = function(room_handle, code, reason) {
    // Handle leave
};

global.on_colyseus_client_error = function(code, message) {
    // Handle client error
};
```

---

## Complete Usage Example

```gml
// === CREATE EVENT ===
colyseus_init();

// Create client
global.client = external_call(global.colyseus_client_create, "localhost:2567", 0);
global.room = 0;

// Set up event handlers
global.on_colyseus_room_join = function(room_handle) {
    global.room = room_handle;
    show_debug_message("Joined! Room ID: " + external_call(global.colyseus_room_get_id, room_handle));
};

global.on_colyseus_message = function(room_handle, data_length) {
    var msg = external_call(global.colyseus_event_get_message);
    show_debug_message("Message: " + msg);
};

// Join a room
external_call(global.colyseus_client_join_or_create, global.client, "my_room", "{}");

// === STEP EVENT ===
colyseus_process_events();

// Send message example
if (keyboard_check_pressed(vk_space) && global.room != 0) {
    var data = json_stringify({text: "Hello!"});
    external_call(global.colyseus_room_send, global.room, "chat", data);
}

// === CLEAN UP EVENT ===
if (global.room != 0) {
    external_call(global.colyseus_room_leave, global.room);
    external_call(global.colyseus_room_free, global.room);
}

if (global.client != 0) {
    external_call(global.colyseus_client_free, global.client);
}

colyseus_free();
```

---

## Notes

### Memory Management
- Always call `colyseus_client_free()` when done with a client
- Always call `colyseus_room_leave()` and `colyseus_room_free()` when leaving a room
- Handles (client, room) are pointers stored as doubles

### String Lifetime
- Returned strings are valid until the next call or next event poll
- Copy strings in GML if you need to persist them

### Thread Safety
- The SDK is designed for single-threaded use
- Always call functions from the main thread
- Call `colyseus_process_events()` in Step event, not Async events

### Event Queue
- Maximum 1024 events can be queued
- Older events are dropped if queue fills
- Each message is limited to 8192 bytes

---

## See Also

- [EXAMPLE.md](EXAMPLE.md) - Complete working examples
- [IMPLEMENTATION.md](IMPLEMENTATION.md) - Technical implementation details
- [INTEGRATION.md](INTEGRATION.md) - Integration guide
- [Colyseus Documentation](https://docs.colyseus.io/) - Server documentation
