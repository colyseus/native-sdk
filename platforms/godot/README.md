# Colyseus GDExtension for Godot 4.1+

A lightweight GDExtension that wraps the Colyseus Native SDK for use in Godot Engine. Written in pure C for maximum performance and minimal dependencies.

**Supports:** Windows, macOS, Linux, and **Web** (via JavaScript SDK bridge).

## 🏗️ Building

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

That's it! The extension will be built and placed in the `bin/` directory.

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
```

## 📦 Installation

1. Copy the `addons/colyseus` folder to your Godot project's `addons/` directory
2. Make sure the `bin/` folder contains the compiled library for your platform
3. The extension will be automatically loaded by Godot

### For Cross-Platform Support (including Web)

To support both native and web platforms seamlessly:

1. Add `ColyseusFactory` as an autoload in your project (Project → Project Settings → Autoload)
   - Path: `res://addons/colyseus/colyseus_factory.gd`
   - Name: `Colyseus`

2. Use the factory to create clients:
```gdscript
# Works on all platforms (native + web)
var client = Colyseus.create_client()
client.set_endpoint("ws://localhost:2567")
var room = client.join_or_create("my_room")

# Get callbacks using factory
var callbacks = Colyseus.get_callbacks(room)
```

## 🌐 Web Export

The addon includes a JavaScript SDK bridge that enables web exports without requiring WASM compilation.

### Setup for Web Export

1. In the Godot Export dialog, create or select a "Web" export preset

2. Under "HTML" → "Custom HTML Shell", select:
   ```
   res://addons/colyseus/web/colyseus.html
   ```

3. When exporting, copy these files to your export directory alongside the HTML:
   - `addons/colyseus/web/colyseus.js` (the Colyseus SDK)
   - `addons/colyseus/web/colyseus_bridge.js` (the Godot bridge)

4. Export your project

### How It Works

On web platform, the addon uses:
- **colyseus.js** - The official Colyseus JavaScript SDK (embedded, no CDN required)
- **colyseus_bridge.js** - A thin wrapper exposing the SDK to Godot's `JavaScriptBridge`
- **GDScript web classes** - Pure GDScript implementations that mirror the native API

```
┌─────────────────────────────────────────┐
│         Godot Engine (GDScript)         │
│   var client = Colyseus.create_client() │
└─────────────────┬───────────────────────┘
                  │ Platform Detection
                  ▼
    ┌─────────────────────────────────┐
    │ Native (Windows/macOS/Linux)    │
    │   → GDExtension C Library       │
    └─────────────────────────────────┘
    ┌─────────────────────────────────┐
    │ Web (Browser)                   │
    │   → JavaScriptBridge            │
    │   → colyseus_bridge.js          │
    │   → colyseus.js (SDK)           │
    └─────────────────────────────────┘
```

### Web-Specific Classes

When running on web, these classes are used automatically:
- `ColyseusWebClient` - Web implementation of ColyseusClient
- `ColyseusWebRoom` - Web implementation of ColyseusRoom  
- `ColyseusWebCallbacks` - Web implementation of ColyseusCallbacks

You don't need to use these directly if you use the `ColyseusFactory` autoload.

## 🚀 Usage

See [example.gd](example.gd)

## 📋 API Reference

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

## 🔧 Architecture

This extension is built with:
- **Pure C** - No C++ dependencies, direct use of GDExtension C API
- **Zig Build System** - Simple, fast, and supports easy cross-compilation
- **Minimal Dependencies** - Only depends on the Colyseus Native SDK 

```
┌─────────────────────────────────────────┐
│         Godot Engine (GDScript)         │
│   var client = ColyseusClient.new()    │
└─────────────────┬───────────────────────┘
                  │ GDExtension C API
                  │
┌─────────────────▼───────────────────────┐
│      Pure C Wrapper (this extension)    │
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
└─────────────────────────────────────────┘
```

## 🎯 Design Choices

### Why C instead of C++?

1. **Lighter** - No need for the large godot-cpp dependency
2. **Simpler** - Direct use of GDExtension C API
3. **Faster builds** - C compiles faster than C++
4. **Smaller binaries** - No C++ standard library overhead
5. **Better interop** - Native C API matches the Colyseus SDK

### Why Zig for building?

1. **Simple** - Just `zig build` with no external dependencies
2. **Cross-compilation** - Easy to build for any platform
3. **Fast** - Built-in caching and parallel compilation
4. **No build tool dependencies** - Zig includes everything
5. **Consistent** - Same build system as the main Colyseus SDK

## ⚠️ Status

This is a barebones implementation providing the foundation for Colyseus integration. 

**Working:**
- ✅ Basic class structure  
- ✅ Connection to Colyseus server  
- ✅ Send/receive messages  
- ✅ Room lifecycle (join/leave)  
- ✅ Godot signals for events  
- ✅ Pure C implementation
- ✅ Zig build system
- ✅ Web export support (JavaScript SDK bridge)
- ✅ Platform-aware factory for cross-platform code

**Not Yet Implemented:**
- ⏳ Async operations with proper callbacks  
- ⏳ State synchronization (delta patches)  
- ⏳ Reconnection logic  
- ⏳ Complete matchmaking API  
- ⏳ Schema deserialization  

## 📝 License

See LICENSE file in the root directory.
