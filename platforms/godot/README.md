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

Then create a client and join:

```gdscript
var client = Colyseus.Client.new("ws://localhost:2567")
var room = client.join_or_create("my_room")
room.set_state_type(MyState)            # optional: decode into your Colyseus.Schema classes

var callbacks = Colyseus.Callbacks.of(room)
callbacks.on_add("players", func(player, key): print("joined: ", key))
```

## State and callbacks

- **Register whenever.** `Colyseus.Callbacks.of(room)` works right after
  `join_or_create()` returns, from `joined`, or later. Root registrations made
  before the room joins go live right after `joined`, replaying what is already
  there: `listen` fires with the current value, `on_add` once per existing item.
  `of()` returns the same registry every time for a room.
- **Delivery is synchronous**, inside `Colyseus.poll()` (the addon polls every
  frame), in the order the server sent it: `joined`, the first state's
  `on_add`/`listen`, then `state_changed`; after that each patch fires its
  callbacks, then `state_changed`. Web exports defer callbacks to the end of
  the frame instead, since socket events arrive outside `poll()` there.
- Every registration returns a handle for `remove(handle)`, which is safe from
  inside the callback itself. A registration that can't work (unknown field, a
  target that was removed) returns `-1` and prints an error.
- **Typed state.** With `set_state_type(MyState)` (call it before the room
  joins), `room.state` / `room.get_state()` is your root instance: the same
  object every time, kept current. Its map and array fields are live
  Dictionaries/Arrays, primitive collections (`array<uint8>`) included. Keep a
  reference and it stays up to date. Without a schema class, `get_state()`
  returns a Dictionary snapshot.
- When an entity is removed, its instance's `__ref_id` goes back to `-1` once
  the SDK lets go of it. Ids are reused by the server for later entities.
- `predict.value(instance, field)` is safe on anything: the smoothed value of an
  attached field, the decoded value otherwise, and the last received value once
  the entity is gone. NAN only means `instance` has no such numeric field.

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
- `reconnect(reconnection_token: String) -> ColyseusRoom` - Re-take a seat the server is holding via `allowReconnection()`
- `get_endpoint() -> String`

### ColyseusRoom

#### Methods
- `send_message(type: String, data)` - Send a string-typed message (any Variant payload)
- `send_message_int(type: int, data)` - Send an integer-typed message
- `leave()` - Leave the room (consented: the server runs `onLeave` right away, `left` reports 4000)
- `get_id() -> String` - Get the room ID
- `get_session_id() -> String` - Get the session ID
- `get_reconnection_token() -> String` - Token for `client.reconnect()`; persist it to survive a process kill
- `get_name() -> String` - Get the room name
- `set_state_type(schema_class)` - Decode into your `Colyseus.Schema` classes; call before the room joins
- `get_state()` / `state` - The typed root (with `set_state_type`), else a Dictionary snapshot
- `connected: bool` - Joined and the WebSocket is open

#### Signals
- `joined()` - Emitted when successfully joined the room
- `state_changed()` - Emitted after each state patch, once its callbacks have run
- `message_received(type, data)` - Emitted when a message is received
- `error(code: int, message: String)` - Emitted on error
- `left(code: int, reason: String)` - Emitted when leaving the room
- `dropped(code: int, reason: String)` / `reconnected()` - Automatic reconnection

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
