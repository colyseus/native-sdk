# Colyseus GDExtension for Godot 4.1+

A lightweight GDExtension that wraps the Colyseus Native SDK for use in Godot Engine. Written in pure C for maximum performance and minimal dependencies.

**Supports:** Windows, macOS, Linux, iOS, Android, and **Web** (WASM).

## Building

### Prerequisites

**Build the Colyseus Native SDK first**:
```bash
cd ../..
zig build
```

### Build the Extension

```bash
cd platforms/godot
zig build
```

That's it! The extension will be built and placed in the `addons/colyseus/bin/` directory.

#### Build Options

```bash
# Debug build (default)
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Cross-compile for other platforms
zig build -Dtarget=x86_64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos

# Build for Web (WASM)
zig build -Dtarget=wasm32-emscripten
```

## Installation

1. Copy the `addons/colyseus` folder to your Godot project's `addons/` directory
2. Make sure the `bin/` folder contains the compiled library for your platform
3. The extension will be automatically loaded by Godot

### Using the Factory (Recommended)

Add `Colyseus` as an autoload in your project (Project → Project Settings → Autoload):
- Path: `res://addons/colyseus/colyseus.gd`
- Name: `Colyseus`

Then use the factory to create clients:

```gdscript
var client = Colyseus.create_client()
client.set_endpoint("ws://localhost:2567")
var room = client.join_or_create("my_room")

# Get callbacks
var callbacks = Colyseus.callbacks(room)
```

## Web Export

The GDExtension supports web exports via WebAssembly (WASM). This requires **dlink-enabled export templates**.

### Requirements

Godot's default web export templates do **not** include GDExtension support. You need custom templates compiled with dynamic linking enabled.

#### Option 1: Build Custom Templates

Compile Godot export templates with GDExtension support:

```bash
scons platform=web dlink_enabled=yes target=template_release
scons platform=web dlink_enabled=yes target=template_debug
```

Rename the resulting files to `web_dlink_release.zip` and `web_dlink_debug.zip`, then configure them in Godot's Export dialog under "Custom Templates".

#### Option 2: Use Community Templates

Look for community-provided dlink-enabled templates that support GDExtension on web.

### Building the WASM Library

```bash
cd platforms/godot

# Debug build
zig build -Dtarget=wasm32-emscripten

# Release build  
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast
```

The WASM file will be placed in `addons/colyseus/bin/`.

### Emscripten Compatibility

- Requires Emscripten 3.1.74+ for Godot 4.3+ compatibility
- The build system will automatically download and set up the emsdk if needed

## Usage

See [example.gd](example.gd)

## API Reference

### ColyseusClient

#### Methods
- `connect_to(endpoint: String)` - Connect to a Colyseus server
- `join_or_create(room_name: String, options: Dictionary = {}) -> ColyseusRoom`
- `create_room(room_name: String, options: Dictionary = {}) -> ColyseusRoom`
- `join(room_name: String, options: Dictionary = {}) -> ColyseusRoom`
- `join_by_id(room_id: String, options: Dictionary = {}) -> ColyseusRoom`
- `get_endpoint() -> String`

### ColyseusRoom

#### Methods
- `send_message(type: String, data: PackedByteArray)` - Send a string-typed message
- `send_message_int(type: int, data: PackedByteArray)` - Send an integer-typed message
- `leave(consented: bool = true)` - Leave the room
- `get_id() -> String` - Get the room ID
- `get_session_id() -> String` - Get the session ID
- `get_name() -> String` - Get the room name
- `has_joined() -> bool` - Check if successfully joined

#### Signals
- `joined()` - Emitted when successfully joined the room
- `state_changed()` - Emitted when room state changes
- `message_received(data: PackedByteArray)` - Emitted when a message is received
- `error(code: int, message: String)` - Emitted on error
- `left(code: int, reason: String)` - Emitted when leaving the room

## Architecture

This extension is built with:
- **Pure C** - No C++ dependencies, direct use of GDExtension C API
- **Zig Build System** - Simple, fast, and supports easy cross-compilation
- **Unified Codebase** - Same GDExtension works on all platforms including web

```
┌─────────────────────────────────────────┐
│         Godot Engine (GDScript)         │
│   var client = Colyseus.create_client() │
└─────────────────┬───────────────────────┘
                  │ GDExtension C API
                  │
┌─────────────────▼───────────────────────┐
│      GDExtension (Pure C)               │
│  - register_types.c                     │
│  - colyseus_client.c                    │
│  - colyseus_room.c                      │
└─────────────────┬───────────────────────┘
                  │ C API calls
                  │
┌─────────────────▼───────────────────────┐
│       Colyseus Native SDK (C)           │
│  - colyseus_client_t                    │
│  - colyseus_room_t                      │
│  - WebSocket, HTTP, JSON handling       │
└─────────────────┬───────────────────────┘
                  │
    ┌─────────────┴─────────────┐
    │                           │
┌───▼───┐                   ┌───▼───┐
│Native │                   │ Web   │
│.dylib │                   │.wasm  │
│.so    │                   │       │
│.dll   │                   │       │
└───────┘                   └───────┘
```

## Design Choices

### Why C instead of C++?

1. **Lighter** - No need for the large godot-cpp dependency
2. **Simpler** - Direct use of GDExtension C API
3. **Faster builds** - C compiles faster than C++
4. **Smaller binaries** - No C++ standard library overhead
5. **Better interop** - Native C API matches the Colyseus SDK

### Why Zig for building?

1. **Simple** - Just `zig build` with no external dependencies
2. **Cross-compilation** - Easy to build for any platform including WASM
3. **Fast** - Built-in caching and parallel compilation
4. **No build tool dependencies** - Zig includes everything
5. **Consistent** - Same build system as the main Colyseus SDK

### Why WASM instead of JavaScript Bridge?

1. **Unified codebase** - Same C code runs on all platforms
2. **No dual maintenance** - No separate JavaScript implementation needed
3. **Consistent behavior** - Identical SDK behavior across platforms
4. **Better debugging** - Same debugging experience everywhere

## Status

**Working:**
- ✅ Basic class structure  
- ✅ Connection to Colyseus server  
- ✅ Send/receive messages  
- ✅ Room lifecycle (join/leave)  
- ✅ Godot signals for events  
- ✅ Pure C implementation
- ✅ Zig build system
- ✅ Web export support (WASM with dlink templates)
- ✅ Cross-platform factory

**Not Yet Implemented:**
- ⏳ Async operations with proper callbacks  
- ⏳ State synchronization (delta patches)  
- ⏳ Reconnection logic  
- ⏳ Complete matchmaking API  
- ⏳ Schema deserialization  

## License

See LICENSE file in the root directory.
