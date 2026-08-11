# Changelog

All notable changes to the Colyseus Native SDK (C core / static library) will be documented in this file.
Per-binding changes are tracked in [platforms/godot/CHANGELOG.md](platforms/godot/CHANGELOG.md), [platforms/gamemaker/CHANGELOG.md](platforms/gamemaker/CHANGELOG.md) and [platforms/flutter/CHANGELOG.md](platforms/flutter/CHANGELOG.md).

## 0.18.0

### Added
- Latency measurement and endpoint selection (`include/colyseus/latency.h`):
  - `colyseus_get_latency(endpoint, options, cb)` — opens a WebSocket, sends a protocol PING, and reports the round-trip time in milliseconds.
  - `colyseus_select_by_latency(endpoints, count, options, cb)` — measures multiple endpoints in parallel and returns the lowest-latency one (`best_endpoint == NULL` when every endpoint failed).
  - `colyseus_client_get_latency(client, options, cb)` — convenience wrapper that measures the client's configured endpoint and derives TLS settings from it.
  - `colyseus_latency_options_t` (`ping_count`, `timeout_ms` default 1500, TLS fields) and `colyseus_latency_result_t`.
  - Each measurement always settles exactly once — on the pong(s), a connection error, a server-side close before the pong, or the timeout — so an unreachable/blackholed endpoint can never stall a selection (ports the JS SDK fix for [#941](https://github.com/colyseus/colyseus/issues/941)).
  - Native (pthreads/Win32) and Emscripten/WASM implementations.
- `COLYSEUS_PROTOCOL_PING` (18) and `COLYSEUS_PROTOCOL_PONG` (19) in `protocol.h`.
- `examples/latency_example.c` smoke test exercising the healthy, timeout, and selection paths.
