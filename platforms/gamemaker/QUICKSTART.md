# Quick Start Guide - Colyseus Game Maker Extension

Get up and running with Colyseus in Game Maker in 5 minutes!

## Prerequisites

- [Zig](https://ziglang.org/download/) installed
- libcurl installed on your system
- Game Maker Studio 2 or Game Maker Studio 2023+

## Step 1: Build the Library (2 minutes)

Open a terminal in this directory and run:

```bash
./build.sh
```

Or on Windows:
```cmd
build.bat
```

This creates a library file in `zig-out/lib/` for your platform.

## Step 2: Create Extension in Game Maker (2 minutes)

1. Open your Game Maker project
2. Right-click **Extensions** → **Create Extension**
3. Name it "Colyseus"
4. Click **Add File**
5. Select the library from `zig-out/lib/[your-platform]/[arch]/`
   - macOS: `libcolyseus.0.1.0.dylib`
   - Windows: `colyseus.dll`
   - Linux: `libcolyseus.so.0.1.0`
6. In file properties, check **Export on import**

## Step 3: Add External Functions (1 minute)

In your extension, click **Add Function** and add these:

```gml
// Client
external_define("colyseus", "colyseus_client_create", dll_cdecl, ty_real, 2, ty_string, ty_real);
external_define("colyseus", "colyseus_client_free", dll_cdecl, ty_real, 1, ty_real);

// Room
external_define("colyseus", "colyseus_client_join_or_create", dll_cdecl, ty_real, 3, ty_real, ty_string, ty_string);
external_define("colyseus", "colyseus_room_leave", dll_cdecl, ty_real, 1, ty_real);
external_define("colyseus", "colyseus_room_poll", dll_cdecl, ty_real, 1, ty_real);
external_define("colyseus", "colyseus_room_send", dll_cdecl, ty_real, 3, ty_real, ty_string, ty_string);
```

Or use the shorthand in a script:

```gml
// Save these as global functions in a script asset
global.client_create = external_define("colyseus", "colyseus_client_create", dll_cdecl, ty_real, 2, ty_string, ty_real);
global.client_free = external_define("colyseus", "colyseus_client_free", dll_cdecl, ty_real, 1, ty_real);
global.join_or_create = external_define("colyseus", "colyseus_client_join_or_create", dll_cdecl, ty_real, 3, ty_real, ty_string, ty_string);
global.room_leave = external_define("colyseus", "colyseus_room_leave", dll_cdecl, ty_real, 1, ty_real);
global.room_poll = external_define("colyseus", "colyseus_room_poll", dll_cdecl, ty_real, 1, ty_real);
global.room_send = external_define("colyseus", "colyseus_room_send", dll_cdecl, ty_real, 3, ty_real, ty_string, ty_string);
```

## Step 4: Use in Your Game (< 1 minute)

### In a Game Controller Object

**Create Event:**
```gml
// Connect to server
client = external_call(global.client_create, "ws://localhost:2567", 0);

// Join or create a room
room = external_call(global.join_or_create, client, "my_room", "{}");

// Store room globally
global.current_room = room;
```

**Step Event:**
```gml
// Update the room (call every frame)
if (global.current_room != 0) {
    external_call(global.room_poll, global.current_room);
}
```

**Clean Up Event:**
```gml
// Leave room and disconnect
if (global.current_room != 0) {
    external_call(global.room_leave, global.current_room);
}
if (client != 0) {
    external_call(global.client_free, client);
}
```

### Send a Message (e.g., in a button press)

```gml
// Simple message
external_call(global.room_send, global.current_room, "myEvent", "{}");

// Message with data
var data = json_stringify(ds_map_create());
ds_map_add(data, "x", x);
ds_map_add(data, "y", y);
external_call(global.room_send, global.current_room, "move", data);
ds_map_destroy(data);
```

## That's It!

You're now connected to Colyseus from Game Maker!

## Testing

Make sure you have a Colyseus server running:

```bash
cd ../../example-server
npm install
npm start
```

The server will start on `ws://localhost:2567`.

## Next Steps

- 📖 Read [INTEGRATION.md](INTEGRATION.md) for detailed setup
- 📚 Check [API_REFERENCE.md](API_REFERENCE.md) for all functions
- 🎮 See the example project in `example/`
- 🌐 Visit [docs.colyseus.io](https://docs.colyseus.io) for server docs

## Common Issues

### "Library not found"
- Make sure the library file is in your extension
- Check that platform targets are set correctly
- Verify the file path in the extension properties

### "External function failed"
- Check that you're passing the right number of arguments
- Verify argument types (ty_real for pointers, ty_string for strings)
- Make sure function names match exactly

### "Can't connect to server"
- Verify the server is running: `curl http://localhost:2567/`
- Check the server URL is correct
- Ensure firewall isn't blocking port 2567

## Need Help?

1. Check [INTEGRATION.md](INTEGRATION.md) for detailed instructions
2. Review [API_REFERENCE.md](API_REFERENCE.md) for function details
3. Look at the example project
4. Ask on the Colyseus Discord or GitHub issues

Happy game making! 🎮

