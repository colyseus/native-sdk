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

var client: Colyseus.Client
var room: Colyseus.Room
var callbacks: Colyseus.Callbacks

func _ready():
    client = Colyseus.Client.new("ws://localhost:2567")
    room = client.join_or_create("my_room")
    room.set_state_type(MyState)  # optional, and only before the room joins

    # Register right away: these go live as soon as the room joins
    callbacks = Colyseus.Callbacks.of(room)
    callbacks.on_add("players", func(player, key): print("player added: ", key))
    callbacks.listen("currentTurn", func(value, _previous): print("turn: ", value))

    room.joined.connect(func(): print("Joined!"))
    room.message_received.connect(func(type, data): print("Message: ", type, " ", data))

func _process(_delta):
    # typed root: the same object every frame, maps/arrays kept current
    if room.state:
        $Label.text = "%d players" % room.state.players.size()

func send_greeting():
    room.send_message("greet", {"text": "Hello"})
```

Callbacks and signals fire synchronously inside `Colyseus.poll()`, which the
addon runs every frame: `joined`, then the first state's `on_add`/`listen`,
then `state_changed`.

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

### Colyseus.Client
```gdscript
var client = Colyseus.Client.new("ws://localhost:2567")

# Join/Create rooms
var room = client.join_or_create("room_name")
var room = client.join("room_name")
var room = client.join_by_id("room_id")
var room = client.create("room_name")
```

### Colyseus.Room
```gdscript
# Send messages
room.send_message("type", data)
room.send_message_int(123, data)

# State
room.set_state_type(MyState)   # before the room joins
room.state                     # typed root (or a Dictionary snapshot when untyped)

# Leave room (consented: the server runs onLeave right away)
room.leave()

# Signals
room.joined.connect(on_joined)
room.state_changed.connect(on_state_changed)
room.message_received.connect(on_message)
room.error.connect(on_error)
room.left.connect(on_left)
```

### Colyseus.Callbacks
```gdscript
var callbacks = Colyseus.Callbacks.of(room)
var handle = callbacks.on_add("players", func(player, key): pass)
callbacks.on_remove("players", func(player, key): pass)
callbacks.listen("currentTurn", func(value, previous): pass)
callbacks.listen(player, "x", func(value, previous): pass)   # nested instance
callbacks.remove(handle)                                     # -1 means the registration failed
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
