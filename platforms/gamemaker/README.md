# Colyseus Native SDK - Game Maker Extension

> https://manual.gamemaker.io/beta/en/The_Asset_Editors/Extension_Creation/Creating_An_Extension.htm

This directory contains the build configuration for compiling the Colyseus Native SDK as a Game Maker extension.

## Platform Support

- ✅ **Native Platforms**: Windows, macOS, Linux (C implementation)
- ✅ **HTML5/GX.Games**: Web browsers (JavaScript implementation using colyseus.js)
- 🚧 **Mobile**: iOS, Android (coming soon)

## Prerequisites

- [Zig](https://ziglang.org/download/) (0.15.0 or later)
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

### For Native Platforms (Windows/Mac/Linux)

1. Build the native libraries using the commands above
2. Copy the generated libraries from `zig-out/lib/` to your Game Maker extension directory
3. Configure your Game Maker extension to reference these libraries

### For HTML5/GX.Games

HTML5 builds use a **JavaScript implementation** instead of native C code. See [HTML5_SETUP.md](HTML5_SETUP.md) for detailed setup instructions.

**Quick setup:**
1. Add `src/gamemaker_export_html5.js` to your extension (JavaScript file, HTML5 target only)
2. Include colyseus.js in your HTML template: `<script src="https://unpkg.com/colyseus.js@^0.16.0"></script>`
3. Your GML code works the same on all platforms!

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

The extension exposes the Colyseus client API through unified functions that work on both native and HTML5 platforms:

- `colyseus_client_create()` - Create a new Colyseus client
- `colyseus_client_join_or_create()` - Join or create a room
- `colyseus_room_send()` - Send messages to a room
- `colyseus_poll_event()` - Poll for network events
- And more... (see [API_REFERENCE.md](API_REFERENCE.md))

**Implementation:**
- Native platforms: C library compiled from this SDK
- HTML5: JavaScript wrapper using colyseus.js client

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

## Development

The build script (`build.zig`) is located in this directory and references the main SDK source code from the repository root (`../../`).

To modify the build configuration, edit `build.zig`.

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** - Get started in 5 minutes
- **[HTML5_SETUP.md](HTML5_SETUP.md)** - HTML5/GX.Games configuration guide
- **[API_REFERENCE.md](API_REFERENCE.md)** - Complete API documentation
- **[EXAMPLE.md](EXAMPLE.md)** - Full code examples
- **[INTEGRATION.md](INTEGRATION.md)** - Advanced integration patterns
- **[IMPLEMENTATION.md](IMPLEMENTATION.md)** - Technical implementation details

## License

See the main repository LICENSE file.

