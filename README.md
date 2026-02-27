# Colyseus Native SDK

> This project is under active development! We may introduce breaking changes at any time.

Cross-platform Native SDK for [Colyseus](https://colyseus.io/). Aimed to be used for all native targets, such as Godot, Unreal Engine, Game Maker, and more.

## Releases

| Release | Description | Platforms |
|---------|-------------|-----------|
| [Godot](https://github.com/colyseus/native-sdk/releases?q=godot) | GDExtension plugin for Godot 4.x | Windows, macOS, Linux, iOS, Android, Web |
| [GameMaker](https://github.com/colyseus/native-sdk/releases?q=gamemaker) | Native extension for GameMaker | Windows, macOS, Linux, iOS, Android, HTML5 (WASM) |
| [Static Binaries](https://github.com/colyseus/native-sdk/releases?q=v) | Pre-built static libraries (C API) | Windows, macOS, Linux, iOS, WebAssembly |

## Building

```bash
git submodule update --init --recursive
zig build

# Run example
zig build run-example
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