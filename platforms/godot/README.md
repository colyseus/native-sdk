# Colyseus GDExtension for Godot 4.1+

A lightweight GDExtension that wraps the Colyseus Native SDK for use in Godot Engine. Written in pure C for maximum performance and minimal dependencies.

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

1. Copy the entire `platforms/godot` folder to your Godot project
2. Make sure the `bin/` folder contains the compiled library for your platform
3. The extension will be automatically loaded by Godot

## 🚀 Usage

```gdscript
extends Node

var client: ColyseusClient
var room: ColyseusRoom

func _ready():
    # Create and connect client
    client = ColyseusClient.new()
    client.connect_to("ws://localhost:2567")
    
    # Join or create a room
    room = client.join_or_create("my_room")
    
    # Connect signals
    room.joined.connect(_on_room_joined)
    room.state_changed.connect(_on_state_changed)
    room.message_received.connect(_on_message_received)
    room.error.connect(_on_room_error)
    room.left.connect(_on_room_left)

func _on_room_joined():
    print("Joined room: ", room.get_id())
    
    # Send a message
    var data = PackedByteArray()
    data.append_array("Hello".to_utf8_buffer())
    room.send_message("greeting", data)

func _on_state_changed():
    print("Room state changed")

func _on_message_received(data: PackedByteArray):
    print("Message received: ", data.get_string_from_utf8())

func _on_room_error(code: int, message: String):
    print("Room error: ", code, " - ", message)

func _on_room_left(code: int, reason: String):
    print("Left room: ", code, " - ", reason)
```

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
- **Minimal Dependencies** - Only depends on the Colyseus Native SDK and libcurl

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

**Not Yet Implemented:**
- ⏳ Async operations with proper callbacks  
- ⏳ State synchronization (delta patches)  
- ⏳ Reconnection logic  
- ⏳ Complete matchmaking API  
- ⏳ Schema deserialization  

## 📝 License

See LICENSE file in the root directory.
