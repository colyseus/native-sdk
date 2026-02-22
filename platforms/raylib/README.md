# Colyseus Raylib Example

A simple raylib application demonstrating the Colyseus Native SDK. Players are displayed as colored rectangles that can be moved around with keyboard input.

## Prerequisites

- [Zig](https://ziglang.org/download/) (0.13.0 or later)
- Colyseus server running with the test room (see `example-server/`)

## Building

```bash
cd platforms/raylib

# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast
```

The executable will be located at `zig-out/bin/raylib_colyseus`.

## Running

1. Start the example server:
   ```bash
   cd example-server
   npm install
   npm start
   ```

2. Run the raylib client:
   ```bash
   cd platforms/raylib
   zig build run
   ```

## Controls

- **WASD** or **Arrow Keys**: Move your player
- **ESC**: Exit the application

## Features

- Connects to `localhost:2567` and joins `test_room`
- Displays all players as colored rectangles
- Local player has a white border
- Disconnected players appear gray
- Bot players show "BOT" label
- Session ID displayed below each player

## Architecture

- Uses the Colyseus Native SDK's callback system for state synchronization
- Schema types are imported from `tests/schema/test_room_state.h`
- Messages are encoded using msgpack via zig-msgpack
- Network I/O runs on a background thread (automatic polling)
