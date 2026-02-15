# Colyseus GDExtension - Quick Start

## 🚀 3-Step Setup

### 1. Build the Native SDK
```bash
cd ../..
zig build
```

### 2. Build the Extension
```bash
cd platforms/godot
zig build
```

### 3. Use in Your Godot Project

Copy the `godot` folder to your Godot project, then create a script:

```gdscript
extends Node

var client: ColyseusClient
var room: ColyseusRoom

func _ready():
    # Connect to server
    client = ColyseusClient.new()
    client.connect_to("ws://localhost:2567")

    # Join a room
    room = client.join_or_create("my_room")

    # Handle events
    room.joined.connect(func(): print("Joined!"))
    room.message_received.connect(func(data): print("Message: ", data))

func send_greeting():
    var data = "Hello".to_utf8_buffer()
    room.send_message("greet", data)
```

## 🔧 Build Options

```bash
# Debug build (default)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Cross-compile for Windows from macOS/Linux
zig build -Dtarget=x86_64-windows

# Cross-compile for Linux from macOS/Windows
zig build -Dtarget=x86_64-linux
```

## 📚 API Overview

### ColyseusClient
```gdscript
# Connection
client.connect_to("ws://localhost:2567")

# Join/Create rooms
var room = client.join_or_create("room_name")
var room = client.join("room_name")
var room = client.join_by_id("room_id")
var room = client.create_room("room_name")
```

### ColyseusRoom
```gdscript
# Send messages
room.send_message("type", data)
room.send_message_int(123, data)

# Leave room
room.leave()

# Signals
room.joined.connect(on_joined)
room.state_changed.connect(on_state_changed)
room.message_received.connect(on_message)
room.error.connect(on_error)
room.left.connect(on_left)
```

## 🎮 Running the Example Server

```bash
cd ../../example-server
npm install
npm start
```

Now you can test the extension with the example server!

## ⚠️ Troubleshooting

### "colyseus library not found"
Build the native SDK first: `cd ../.. && zig build`

### "curl not found"
- **macOS**: `brew install curl`
- **Linux**: `sudo apt install libcurl4-openssl-dev`
- **Windows**: Install from https://curl.se/windows/

### Extension not loading in Godot
1. Check that `colyseus.gdextension` is in the extension folder
2. Ensure the `.so`/`.dll`/`.dylib` file is in the `bin/` directory
3. Check Godot's Output tab for error messages
4. Verify the library name matches your platform in `colyseus.gdextension`

## 💡 Why This Is Different

This GDExtension is:
- **Pure C** - No C++ or godot-cpp dependency
- **Zig-built** - Simple `zig build` with easy cross-compilation
- **Lightweight** - Minimal overhead, direct GDExtension C API usage
- **Fast** - C is fast, Zig builds are cached and parallel

## 📖 Full Documentation

See [README.md](README.md) for complete API reference and architecture details.
