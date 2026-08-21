# Colyseus Native SDK - Game Maker Extension

> https://manual.gamemaker.io/beta/en/The_Asset_Editors/Extension_Creation/Creating_An_Extension.htm

This directory contains the build configuration for compiling the Colyseus Native SDK as a Game Maker extension.

## Platform Support

- ✅ **Native Platforms**: Windows, macOS, Linux (C implementation)
- ✅ **HTML5/GX.Games**: Web browsers (the same C SDK compiled to WebAssembly)
- 🚧 **Mobile**: iOS, Android (coming soon)

## Prerequisites

- [Zig](https://ziglang.org/download/) (0.15.2 or later)
- System dependencies:
  - **macOS**: Xcode Command Line Tools
  - **Linux**: libcurl development headers (`libcurl4-openssl-dev` on Ubuntu/Debian)
  - **Windows**: libcurl (when cross-compiling)

## Building

### Build for Native Platform

To build the extension for your current platform:

```bash
zig build
```

This will create a shared library in the appropriate platform-specific directory under `zig-out/lib/`:
- **macOS**: `zig-out/lib/macos/arm64/` or `zig-out/lib/macos/x64/`
- **Linux**: `zig-out/lib/linux/x64/`
- **Windows**: `zig-out/lib/windows/x64/`

### Build for All Game Maker Platforms

To cross-compile for all supported Game Maker platforms:

```bash
zig build -Dall=true
```

This will build:
- Windows x64 (`.dll`)
- macOS x64 (`.dylib`)
- macOS ARM64 (`.dylib`)
- Linux x64 (`.so`)

### Build Options

- `-Doptimize=ReleaseFast`: Optimize for speed
- `-Doptimize=ReleaseSmall`: Optimize for size
- `-Doptimize=ReleaseSafe`: Optimize with safety checks
- `-Dall=true`: Build for all Game Maker platforms

Example:

```bash
zig build -Doptimize=ReleaseSmall -Dall=true
```

## Using in Game Maker

### Install

1. Download `colyseus-gamemaker-<version>.yymps` from the
   [releases](https://github.com/colyseus/native-sdk/releases) (or build one
   with `./package-yymps.sh`).
2. In GameMaker: **Tools → Import Local Package**, select every resource,
   **Import**. You get the `Colyseus_SDK` extension plus two scripts,
   `Colyseus` and `ColyseusPredict`. They ship together and both are
   required.
3. On macOS/Linux run `./build.sh` once: the package lists `colyseus.dll`
   first, and GameMaker loads only the first native entry (see the packaging
   notes below).

HTML5/GX.Games needs nothing extra: the extension carries the same SDK
compiled to WebAssembly. See [HTML5_SETUP.md](HTML5_SETUP.md).

### Developing against a checkout

A project that lives next to this repository can link the SDK instead of
importing a package:

```bash
path/to/native-sdk/platforms/gamemaker/link-sdk.sh  <project-dir> <Project.yyp>
path/to/native-sdk/platforms/gamemaker/link-sdk.sh --check <project-dir> <Project.yyp>
```

It symlinks `Colyseus.gml`, `ColyseusPredict.gml` and the built binaries
into the project and generates `Colyseus_SDK.yy` from this checkout's copy,
retargeted at the project. The `.gml` and the `.yy` are a matched pair (the
`.yy` declares the bindings the `.gml` calls), so generating one from the
other is what keeps a consumer from drifting; `--check` fails when anything
is missing or behind the checkout. Gitignore the linked files; the demos'
GameMaker clients (`demos/air-hockey`, `demos/prediction-tools`) are wired
this way.

### Quick start

```gml
// Create
client = 0;
room = 0;

// Step
if (client == 0) {
    // HTML5 instantiates the WASM module after the game starts; native is
    // ready at once, so the same gate works everywhere
    if (!colyseus_is_ready()) exit;

    client = colyseus_client_create("http://localhost:2567");
    room = colyseus_client_join_or_create(client, "my_room", { name: "guest" });

    colyseus_on_join(room, function(_room) {
        show_debug_message("joined " + colyseus_room_get_id(_room));
    });
    colyseus_on_state_change(room, function(_room) {
        var _state = colyseus_room_get_state(_room);   // refreshed on every call
        show_debug_message("turn: " + string(_state.currentTurn));
        var _me = colyseus_map_get(_state, "players", colyseus_room_get_session_id(_room));
        if (_me != undefined) show_debug_message("me at " + string(_me.x) + "," + string(_me.y));
    });
    colyseus_on_message(room, function(_room, _type, _data) {
        show_debug_message(_type + ": " + json_stringify(_data));
    });
    colyseus_on_leave(room, function(_code, _reason) {
        show_debug_message("left: " + _reason);
    });
}
colyseus_process();   // delivers every event and callback; call once per Step

// anywhere: send a message (structs, strings, numbers, booleans)
colyseus_send(room, "move", { x: mouse_x, y: mouse_y });

// Clean Up
if (room != 0)   { colyseus_room_leave(room); colyseus_room_free(room); }
if (client != 0) colyseus_client_free(client);
```

Field-level callbacks (`colyseus_listen`, `colyseus_on_add`,
`colyseus_on_remove`, `colyseus_on_change`) hang off a
`colyseus_callbacks_create(room)` handle; collection reads go through
`colyseus_map_get` / `colyseus_map_keys` / `colyseus_array_get`. The
prediction layer (`ColyseusInput`, `ColyseusPredict`, reconcilers, optimistic
events, predicted spawns, the netdelay injector) is documented in the header
of `ColyseusPredict.gml`.

### Directory Structure

The build system organizes libraries by platform:

```
zig-out/lib/
├── windows/
│   └── x64/
│       └── colyseus.dll
├── macos/
│   ├── x64/
│   │   └── libcolyseus.0.1.0.dylib
│   └── arm64/
│       └── libcolyseus.0.1.0.dylib
└── linux/
    └── x64/
        └── libcolyseus.so.0.1.0
```

## Extension API

The API is the two GML scripts, and their `///` doc comments are the
reference (there is no hand-maintained copy to drift):

| script | what it covers |
|---|---|
| [`Colyseus.gml`](example/BlankProject/scripts/Colyseus/Colyseus.gml) | client + matchmaking, room events, schema callbacks, state structs and collection reads, messages, HTTP, auth, latency, `colyseus_process()` |
| [`ColyseusPredict.gml`](example/BlankProject/scripts/ColyseusPredict/ColyseusPredict.gml) | input handle, clock, netdelay injector, manual-pump reconciler (flat + composite sim), optimistic events, predicted spawns |

Everything prefixed `__colyseus_gm_` is an extension binding the scripts
wrap; the list is generated from the C sources by `gen-bindings.mjs` and the
same calls work on native and HTML5 (the WASM shim exposes them under the
same names).

## Auth Tokens

Auth tokens are persisted automatically between sessions using GameMaker's `ds_map_secure_save`. When you set a token, it's saved to disk. When you create a new client, the saved token is restored automatically.

```gml
// Set token — automatically saved to disk
colyseus_auth_set_token(client, "my-jwt-token");

// On next game launch, the token is restored automatically:
client = colyseus_client_create("http://localhost:2567");
var token = colyseus_auth_get_token(client); // "my-jwt-token"

// Clear token on logout — removes the persisted file
colyseus_auth_clear_token(client);
```

The token is stored in `colyseus_auth.dat` in the game's save directory using GameMaker's encrypted format.

## Cross-Compilation Notes

### From macOS

You can cross-compile to all platforms from macOS:

```bash
# All platforms
zig build -Dall=true
```

### From Linux

Cross-compilation to Windows and macOS requires additional setup:
- For Windows: libcurl Windows binaries
- For macOS: macOS SDK (using tools like [osxcross](https://github.com/tpoechtrager/osxcross))

### From Windows

Similar to Linux, cross-compilation requires the target platform's SDK and libraries.

## Extension Packaging Notes

The `.yymps` package and extension `.yy` file must follow specific rules due to undocumented GameMaker behaviors:

### GameMaker loads only the FIRST native file entry

GameMaker ignores `copyToTargets` at runtime for native extensions (`kind:1`). It always loads the **first** `kind:1` file entry in the `.files` array. The packaged `.yymps` puts `colyseus.dll` first (Windows is the most common import target). After importing, macOS/Linux developers must run `./build.sh` to reconfigure the extension for their platform.

### Do NOT use ProxyFiles

ProxyFiles cause GameMaker to load the wrong binary on macOS (it tries to dlopen the proxy file instead of the main file). Use separate file entries per platform instead, each with their own function declarations.

### Every file entry needs its own function declarations

Each native file entry AND the WASM entry must have the full list of function declarations duplicated. GameMaker only binds functions declared on the file entry it loads. If a file entry has `"functions":[]`, none of its extension functions will be available.

### .yyp filename must match .yymps filename

GameMaker's ProjectTool on Windows renames the `.yyp` to match the `.yymps` package filename during import. All `parent.path` references in `.yy` files must use the same name. The packaging script uses `colyseus-gamemaker-{VERSION}` for both. Spaces in the `.yyp` filename cause `FileNotFoundException` on Windows.

### Platform copyToTargets flags

`Windows=1, macOS=2, Linux=4, HTML5=8, iOS=16, Android=32`. These flags are only respected by the build tool (Igor/asset compiler) for file copying, NOT by the runtime runner for native extension loading.

## Troubleshooting

### Missing libcurl

If you get errors about missing libcurl:

- **macOS**: `brew install curl`
- **Linux**: `sudo apt-get install libcurl4-openssl-dev` (Ubuntu/Debian) or `sudo yum install libcurl-devel` (RHEL/CentOS)
- **Windows**: Download from [curl.se](https://curl.se/windows/)

### Linker Errors

If you encounter linker errors during cross-compilation, you may need to install the target platform's development libraries or use a cross-compilation toolchain.

## Running Tests

The test suite runs the example GameMaker project via Igor (GameMaker's CLI build tool) and validates the extension against a live Colyseus server.

### Prerequisites

- **GameMaker IDE** installed and built at least once (to install the runtime with Igor)
- **Colyseus `sdks-test-server`** running locally on port 2567
- Native library already built (`zig build`)

### Running

Start the test server, then run:

```bash
./run-tests.sh
```

The script will:
1. Locate Igor and the GameMaker runtime automatically
2. Copy the latest `libcolyseus.dylib` into the example project's extension
3. Build and launch the example project via Igor
4. Wait for test output (90s timeout)
5. Report pass/fail results

### Test Suites

Tests are GML scripts in `example/BlankProject/scripts/` using the GMTL test framework:

- **TestRoomApi**: readiness, room connection, state access, structs and collections, schema callbacks, messages, leave
- **TestViewCallbacks**, **TestReconnect**, **TestLatencyApi**: StateView callbacks, drop/reconnect, latency selection
- **TestHttpApi**, **TestHttpHelpers**, **TestAuthApi**: HTTP and auth flows
- **TestPredictCore**, **TestPredictAdvanced**, **TestPredictNet**: the prediction layer, against the prediction-tools playground

`COLYSEUS_TEST_FILTER=<substring>` runs only the matching `describe` blocks;
`COLYSEUS_PLAYGROUND_PORT` relocates the playground server. The HTML5 build is
covered separately by `tests-web/run-web-tests.sh`.

## Development

The build script (`build.zig`) is located in this directory and references the main SDK source code from the repository root (`../../`).

To modify the build configuration, edit `build.zig`.

## Documentation

- **[HTML5_SETUP.md](HTML5_SETUP.md)**: HTML5/GX.Games, how the WASM build loads and the `colyseus_is_ready()` gate
- **[PORTING_NOTES.md](PORTING_NOTES.md)**: GML and GameMaker behaviours that bite a multiplayer port (closures, built-in names, HTML5 numeric and struct traps, Igor)
- **[SUMMARY.md](SUMMARY.md)**: the build system (zig build, cross-compilation, output layout)
- **[CHANGELOG.md](CHANGELOG.md)**

## License

See the main repository LICENSE file.

