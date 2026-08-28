# Colyseus Native SDK

> This project is under active development! We may introduce breaking changes at any time.

Cross-platform Native SDK for [Colyseus](https://colyseus.io/). Aimed to be used for all native targets, such as Godot, Unreal Engine, Game Maker, and more.

## Releases

| Release | Description | Platforms |
|---------|-------------|-----------|
| [Godot](https://github.com/colyseus/native-sdk/releases?q=%22Godot+SDK%22&expanded=true) | GDExtension plugin for Godot 4.x | Windows, macOS, Linux, iOS, Android, Web |
| [GameMaker](https://github.com/colyseus/native-sdk/releases?q=%22GameMaker+SDK%22&expanded=true) | Native extension for GameMaker | Windows, macOS, Linux, iOS, Android, HTML5 (WASM) |
| [Static Binaries](https://github.com/colyseus/native-sdk/releases?q=%22Colyseus+Native+SDK+-+Static+Library%22&expanded=true) | Pre-built static libraries (C API) | Windows, macOS, Linux, iOS, WebAssembly |
| [Swift](https://github.com/colyseus/colyseus-swift) | Swift package (SwiftPM) | macOS, iOS, tvOS |

## Building

```bash
git submodule update --init --recursive
zig build

# Run example
zig build run-example
```

## Using the C API

The whole public API is behind one header, and `zig-out/include` is the only
include path it needs:

```c
#include <colyseus.h>
```

A static build ships the libraries it links against as separate archives —
mbedTLS, wslay and the Zig modules — because an archive does not absorb its
dependencies. Pass the whole directory and let the linker sort it out:

```bash
cc app.c -I zig-out/include zig-out/lib/*.a -lpthread \
   -framework CoreFoundation -framework Security   # macOS/iOS
```

On Linux add `-lm`; on Windows link `ws2_32`, `crypt32` and `bcrypt`. A shared
build (`-Dshared=true`) has already absorbed the closure, so `-lcolyseus` alone
is enough there.

From a Zig project, linking the artifact carries both its header tree and the
whole closure — no `addIncludePath`, nothing else to name:

```zig
const colyseus = b.dependency("colyseus", .{ .target = target, .optimize = optimize });
exe.linkLibrary(colyseus.artifact("colyseus"));
```

## Project Structure

```
native-sdk/
├── build.zig              # Build configuration
├── include/               # Public API headers
├── src/                   # Implementation
├── examples/              # Example programs
├── docs/                  # Documentation
└── third_party/           # Dependencies (cJSON, sds, uthash, wslay)
```

## Dependencies

- **cJSON** - JSON parser (included)
- **sds** - String library (included)
- **uthash** - Hash table library (included)
- **wslay** - WebSocket library (included)
- **mbedTLS** - TLS library (system install required)

## Documentation

- [Building with Zig](docs/BUILD_WITH_ZIG.md)
- [TLS/WSS Support](docs/TLS_SUPPORT.md)
- [Colyseus Documentation](https://docs.colyseus.io/)

## Status

Work in progress. API is subject to change.

## License

See LICENSE file for details.
