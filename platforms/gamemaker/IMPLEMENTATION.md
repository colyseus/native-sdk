# GameMaker Platform Implementation

This document explains how the Colyseus Native SDK is exported for GameMaker, similar to how it's done for Godot.

## Architecture

The GameMaker platform implementation consists of several key components:

### 1. Export Layer (`src/gamemaker_export.c`)

This is the main export layer that wraps the Colyseus C API and exposes it to GameMaker. It's similar to Godot's `register_types.c` but adapted for GameMaker's FFI system.

**Key Features:**

- **DLL Export Macros**: Functions are exported with proper visibility for Windows (`.dll`) and Unix (`.dylib`/`.so`)
- **Double-based Handle System**: GameMaker works with doubles (`ty_real`), so all pointers are cast to/from `double`
- **Event Queue System**: Since GameMaker cannot handle C callbacks directly, we use an event queue that GameMaker polls

### 2. Event Queue System

GameMaker's FFI doesn't support function pointer callbacks, so we implemented a polling-based event system:

```c
// Event types
typedef enum {
    GM_EVENT_NONE = 0,
    GM_EVENT_ROOM_JOIN = 1,
    GM_EVENT_ROOM_STATE_CHANGE = 2,
    GM_EVENT_ROOM_MESSAGE = 3,
    GM_EVENT_ROOM_ERROR = 4,
    GM_EVENT_ROOM_LEAVE = 5,
    GM_EVENT_CLIENT_ERROR = 6,
} gm_event_type_t;
```

**How it works:**

1. When Colyseus C callbacks are triggered, they push events to a circular buffer queue
2. GameMaker polls for events using `colyseus_poll_event()`
3. Event details are retrieved with accessor functions like `colyseus_event_get_room()`, `colyseus_event_get_message()`, etc.

### 3. GML Integration (`colyseus_sdk.gml`)

The GML file provides:

- **Initialization**: `colyseus_init()` - Sets up all external function definitions
- **Cleanup**: `colyseus_free()` - Frees external function resources
- **Event Processing**: `colyseus_process_events()` - Polls and dispatches events to user handlers

## Key Differences from Godot Implementation

### Godot (register_types.c)
- Uses GDExtension API
- Registers classes with methods and signals
- Direct callback support via Godot's signal system
- Complex type system with variants

### GameMaker (gamemaker_export.c)
- Uses simple C FFI (external_define)
- Exports flat C functions
- Event queue for callbacks (no direct callback support)
- Simple type system (doubles, strings, buffers)

## API Design

### Client Functions

```c
double colyseus_client_create(const char* endpoint, double use_secure);
void colyseus_client_free(double client_handle);
double colyseus_client_join_or_create(double client, const char* room_name, const char* options_json);
double colyseus_client_create_room(double client, const char* room_name, const char* options_json);
double colyseus_client_join(double client, const char* room_name, const char* options_json);
double colyseus_client_join_by_id(double client, const char* room_id, const char* options_json);
double colyseus_client_reconnect(double client, const char* reconnection_token);
```

### Room Functions

```c
void colyseus_room_leave(double room_handle);
void colyseus_room_free(double room_handle);
void colyseus_room_send(double room_handle, const char* type, const char* data);
void colyseus_room_send_int(double room_handle, double type, const char* data);
const char* colyseus_room_get_id(double room_handle);
const char* colyseus_room_get_session_id(double room_handle);
const char* colyseus_room_get_name(double room_handle);
double colyseus_room_has_joined(double room_handle);
```

### Event Polling Functions

```c
double colyseus_poll_event(void);
double colyseus_event_get_room(void);
double colyseus_event_get_code(void);
const char* colyseus_event_get_message(void);
const uint8_t* colyseus_event_get_data(void);
double colyseus_event_get_data_length(void);
```

## Usage Example

```gml
// Create event
colyseus_init();
global.client = external_call(global.colyseus_client_create, "localhost:2567", 0);
global.room = 0;

// Set up event handlers
global.on_colyseus_room_join = function(room_handle) {
    show_debug_message("Joined room!");
    global.room = room_handle;
};

global.on_colyseus_message = function(room_handle, data_length) {
    show_debug_message("Received message: " + string(data_length) + " bytes");
};

// Join a room
external_call(global.colyseus_client_join_or_create, global.client, "my_room", "{}");

// Step event - process events every frame
colyseus_process_events();

// Send a message
if (global.room != 0) {
    var message = json_stringify({
        type: "chat",
        text: "Hello from GameMaker!"
    });
    external_call(global.colyseus_room_send, global.room, "chat", message);
}

// Clean up event
if (global.room != 0) {
    external_call(global.colyseus_room_leave, global.room);
    external_call(global.colyseus_room_free, global.room);
}
external_call(global.colyseus_client_free, global.client);
colyseus_free();
```

## Building

The build is handled by `build.zig`, which:

1. Compiles wslay (WebSocket library)
2. Compiles Colyseus core (client, room, networking, etc.)
3. Compiles the GameMaker export layer (`src/gamemaker_export.c`)
4. Links everything into a shared library (`.dll`/`.dylib`/`.so`)
5. Outputs to platform-specific directories:
   - `lib/windows/x64/colyseus.dll`
   - `lib/macos/x64/libcolyseus.0.1.0.dylib`
   - `lib/macos/arm64/libcolyseus.0.1.0.dylib`
   - `lib/linux/x64/libcolyseus.so.0.1.0`

### Build Commands

```bash
# Build for current platform
zig build

# Build for all GameMaker platforms
zig build -Dall=true

# Build with optimization
zig build -Doptimize=ReleaseFast -Dall=true
```

## Thread Safety Considerations

The event queue is **not thread-safe** by design. GameMaker is single-threaded, and all Colyseus operations should happen on the main thread. The event queue is only accessed from:

1. Colyseus callbacks (which run on the same thread as network operations)
2. GameMaker's polling function (which runs on the main thread)

If thread-safety becomes a concern, a mutex should be added around `event_queue_push` and `event_queue_pop`.

## Memory Management

### Handles
- Client and room handles are raw pointers cast to doubles
- GameMaker is responsible for freeing them by calling `colyseus_client_free()` and `colyseus_room_free()`

### Strings
- String returns from `colyseus_room_get_*()` functions are **not copied** - they point to internal memory
- Do not free these strings from GameMaker
- Copy the string in GML if you need to persist it

### Events
- Event data is copied into the event queue
- Limited to 8192 bytes per message
- Events are automatically freed when polled

## Limitations

1. **Message Size**: Messages are limited to 8192 bytes in the event queue
2. **Event Queue Size**: Maximum 1024 events can be queued (older events are dropped)
3. **No Binary Data**: GameMaker's FFI makes it difficult to pass arbitrary binary data efficiently
4. **Synchronous Room Creation**: While room creation is async in C, the handle is returned immediately (0.0) and the actual room is provided via events

## Future Improvements

1. Add support for GameMaker buffers to handle larger binary messages
2. Implement thread-safe event queue with mutex
3. Add more detailed error codes and messages
4. Provide helper GML functions for common patterns (reconnection, state management)
5. Add authentication support

