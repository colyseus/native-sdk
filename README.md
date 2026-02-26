# Colyseus Native SDK

> This repository is under active development. Not currently at a usable state. Contributions are welcome.

Cross-platform Native SDK for [Colyseus](https://colyseus.io/). Aimed to be used for all native targets, such as Godot, Unreal Engine, Game Maker, and more.

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