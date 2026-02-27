# Game Maker Integration Guide

This guide explains how to integrate the compiled Colyseus Native SDK libraries into your Game Maker project.

## Step 1: Build the Libraries

First, build the native libraries for the platforms you want to support:

```bash
# Build for current platform only
./build.sh

# Or build for all platforms
./build.sh --all
```

The libraries will be generated in the `zig-out/lib/` directory.

## Step 2: Create a Game Maker Extension

1. Open your Game Maker project
2. Right-click on **Extensions** in the Asset Browser
3. Select **Create Extension**
4. Name it "ColyseusSDK"

## Step 3: Add the Native Libraries

In your extension settings:

1. Click **Add File** for each platform you want to support:
   - **Windows**: Add `zig-out/lib/windows/x64/colyseus.dll`
   - **macOS (Intel)**: Add `zig-out/lib/macos/x64/libcolyseus.0.1.0.dylib`
   - **macOS (Apple Silicon)**: Add `zig-out/lib/macos/arm64/libcolyseus.0.1.0.dylib`
   - **Linux**: Add `zig-out/lib/linux/x64/libcolyseus.so.0.1.0`

2. For each file, configure the following in the extension properties:
   - Set **Copy to** to the appropriate target(s)
   - Make sure **Export on import** is checked

## Step 4: Define External Functions

In your extension, you need to define the external functions that Game Maker will call. Here's how to define the main functions:

### Client Creation

```gml
// External function definition in extension
colyseus_client_create = external_define(
    "colyseus",  // Library name (without extension)
    "colyseus_client_create",  // Function name
    dll_cdecl,   // Calling convention
    ty_real,     // Return type (pointer as real)
    2,           // Number of arguments
    ty_string,   // Argument 1: server URL
    ty_real      // Argument 2: settings (can be 0 for defaults)
);
```

### Join Room

```gml
colyseus_client_join_or_create = external_define(
    "colyseus",
    "colyseus_client_join_or_create",
    dll_cdecl,
    ty_real,     // Returns room pointer
    3,
    ty_real,     // Client pointer
    ty_string,   // Room name
    ty_string    // Options (JSON string or empty)
);
```

### Send Messages

```gml
colyseus_room_send = external_define(
    "colyseus",
    "colyseus_room_send",
    dll_cdecl,
    ty_real,
    3,
    ty_real,     // Room pointer
    ty_string,   // Message type
    ty_string    // Message data (JSON string)
);
```

## Step 5: Usage Example

Here's a complete example of how to use the Colyseus SDK in Game Maker:

### Create Event

```gml
// Initialize the client
client = external_call(colyseus_client_create, "ws://localhost:2567", 0);

// Join or create a room
room = external_call(colyseus_client_join_or_create, client, "my_room", "{}");

// Store room reference for later use
global.colyseus_room = room;
```

### Step Event

```gml
// Poll for updates (call this every frame)
if (global.colyseus_room != 0) {
    external_call(colyseus_room_poll, global.colyseus_room);
}
```

### Send Message (e.g., in a button press event)

```gml
// Send a message to the room
var message_data = json_stringify(ds_map_create());
ds_map_add(message_data, "action", "move");
ds_map_add(message_data, "x", x);
ds_map_add(message_data, "y", y);

external_call(colyseus_room_send, global.colyseus_room, "playerMove", message_data);

ds_map_destroy(message_data);
```

### Clean Up Event

```gml
// Clean up when leaving the room or closing the game
if (global.colyseus_room != 0) {
    external_call(colyseus_room_leave, global.colyseus_room);
    global.colyseus_room = 0;
}

if (client != 0) {
    external_call(colyseus_client_free, client);
    client = 0;
}
```

## Step 6: Handling Callbacks

The Colyseus SDK uses callbacks for events. You'll need to set up callback functions:

```gml
// Define callback function
colyseus_room_on_message_callback = external_define(
    "colyseus",
    "colyseus_room_on_message",
    dll_cdecl,
    ty_real,
    3,
    ty_real,     // Room pointer
    ty_string,   // Message type filter
    ty_real      // Callback function pointer
);

// Create a callback function
function on_room_message(message_type, message_data) {
    show_debug_message("Received message: " + message_type);
    show_debug_message("Data: " + message_data);
}
```

## Important Notes

### Memory Management

- Always clean up Colyseus objects when you're done with them
- Call `colyseus_client_free()` when closing the connection
- Call `colyseus_room_leave()` before destroying room references

### Threading

The Colyseus SDK handles network operations on background threads. Make sure to:
- Call `colyseus_room_poll()` regularly (ideally every frame) to process updates
- Don't block the main thread with long-running operations

### Platform-Specific Considerations

#### Windows
- Ensure the DLL is in the same directory as your game executable or in the system PATH
- You may need to include additional runtime dependencies (like vcruntime)

#### macOS
- The dylib must be code-signed for distribution
- Use `install_name_tool` to adjust library paths if needed

#### Linux
- Ensure libcurl and other dependencies are installed on the target system
- You may need to set `LD_LIBRARY_PATH` to include the library directory

## Advanced Usage

For advanced features like authentication, see the main SDK documentation and the C header files in `../../include/colyseus/`.

## Troubleshooting

### Library Not Found

If Game Maker can't find the library:
1. Check that the library file is correctly added to the extension
2. Verify the platform target is correctly set
3. Ensure the library is in the exported game directory

### External Function Errors

If you get errors calling external functions:
1. Verify the function signature matches the C API
2. Check that you're passing the correct number and types of arguments
3. Use `show_debug_message()` to log parameter values

### Connection Issues

If you can't connect to the server:
1. Verify the server is running and accessible
2. Check firewall settings
3. Ensure the WebSocket URL is correct (ws:// or wss://)
4. Check the server logs for connection errors

## Example Project

See the `example/` directory for a complete working example of a Game Maker project using the Colyseus SDK.

## Further Reading

- [Colyseus Documentation](https://docs.colyseus.io/)
- [Game Maker Extensions Documentation](https://manual.yoyogames.com/The_Asset_Editors/Extensions.htm)
- [Colyseus C API Reference](../../include/colyseus/)

