# Colyseus Raylib Example

A simple raylib application demonstrating the Colyseus Native SDK. Players are displayed as colored rectangles that can be moved around with keyboard input.

## Prerequisites

- [Zig](https://ziglang.org/download/) (0.13.0 or later)
- Colyseus server running with the test room (see `example-server/`)

## Building

### Native Build

```bash
cd platforms/raylib

# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast
```

The executable will be located at `zig-out/bin/raylib_colyseus`.

### Web Build (Emscripten)

The web build requires two steps: first build the WASM library, then build the raylib application.

**Step 1: Build the colyseus WASM library**

From the native-sdk root directory, run the build script (requires `emcc` in your PATH):

```bash
# From native-sdk root
./build-wasm.sh
```

Or download pre-built WASM binaries from [GitHub Releases](https://github.com/colyseus/native-sdk/releases).

**Step 2: Build the raylib web application**

```bash
cd platforms/raylib

# Build for web (use ReleaseSmall or ReleaseFast for web builds)
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
```

> If `emcc` fails, you may need to run `emsdk_env.sh` from the module fetched by Zig. Use the following command to execute it `source $(find ~/.cache/zig/* -name emsdk_env.sh | head -n 1)`

The output will be in `zig-out/web/`. Serve it with a local HTTP server:

```bash
cd zig-out/web
python3 -m http.server 8080
```

Then open `http://localhost:8080` in your browser.

**Note:** The first build may take a while as it downloads the Emscripten SDK (~300MB).

**Web-specific implementation details:**
- HTTP requests use `emscripten_fetch` (browser's Fetch API)
- WebSocket uses `emscripten_websocket` (browser's WebSocket API)
- Secure storage is not available on web (returns null/error)
- Memory is fixed at 64MB (no dynamic growth to avoid ArrayBuffer detachment)

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
