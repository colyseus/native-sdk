# Changelog

All notable changes to the Colyseus Godot SDK will be documented in this file.

## 0.17.11

### Fixed
- Android `wss://` connections could fail with a TLS certificate-bundle load failure on release builds — working for some devices/users and failing for others against the same endpoint. The SDK runs its own mbedTLS handshake and was picking a single CA source in priority order (system store → bundled Mozilla → settings override), so a device's system trust store could shadow the comprehensive bundled roots and abort TLS entirely if it lacked the server's root or failed to parse — hence the device-dependence. All available CA sources are now merged into one trust chain (bundled Mozilla roots always loaded as a device-independent baseline, with the system store and any override layered on top); TLS init only fails if the chain ends up empty. Reported by @pierroo in #24.
- HTTPS matchmaking (`join_or_create`) used a separate trust store from the `wss://` socket and only trusted the OS system store — so it ignored both the bundled Mozilla roots and `network/tls/certificate_bundle_override`, and had the same Android exposure *before* the WebSocket even connected. Matchmaking now shares the same merged trust roots as the WSS transport.
- A failed TLS handshake (e.g. certificate verification failure) spun the connection state machine forever instead of erroring, so the failure surfaced as a silent hang. It now closes with code `1015` and a specific reason (`"TLS certificate verification failed"`).
- `network/tls/certificate_bundle_override` set to a `res://` or `user://` path is now honored: the native extension resolves Godot virtual paths via `ProjectSettings.globalize_path()` before reading (previously a raw `fopen()` couldn't open them, which is why a `user://` override silently fell back to the built-in roots on Android).

### Tests
- `tests/test_tls.zig` — drives the WebSocket transport directly against a self-signed `wss://` echo server (no matchmaking) and asserts a trusted CA supplied via settings is honored, a wrong/absent CA fails verification, and `tls_skip_verification` connects regardless.
- `test_wss.gd` — joins a room over `wss://` end-to-end through a self-signed TLS proxy, exercising the override loader, HTTPS matchmaking trust, and the WSS handshake together.

## 0.17.10

### Fixed
- GDScript schema parsing: `Room.set_state_type()` could crash (SIGTRAP/SIGSEGV) on Android release exports while reading `Field` objects. `parse_field_from_variant()` now reads `name`/`type`/`child_type` through a checked `Object.get()` helper and bails cleanly instead of operating on an unchecked/uninitialized Variant; it also drops a dead zero-argument `get()` call that built a Variant from a mismatched type. Reported by @pierroo in #23.
- `PackedByteArray` message payloads were silently corrupted to all-zero bytes (of the correct length) in both directions:
  - Encoding indexed a `Variant` cast directly to `PackedByteArray*`, so every byte read back as `0`. The concrete `PackedByteArray` is now extracted from the Variant before indexing.
  - Decoding (`bin` → `PackedByteArray`) called `resize()` on a Variant copy but wrote the bytes into the original empty array, leaving every element `0`. Bytes are now written into the resized array, which is then returned.

### Tests
- `test_gdscript_schema.gd` — exercises `set_state_type()` with a user-defined GDScript schema covering every `Field` branch (STRING/NUMBER/BOOLEAN, MAP/ARRAY/REF + child types) and asserts the state decodes into the user's classes.
- `test_msgpack_pba_roundtrip.gd` — echoes a `PackedByteArray` through the server (top-level, dict-nested, array-nested) and asserts the bytes survive the encode → decode round-trip intact.

## 0.17.9

### Added
- Automatic reconnection. After a recoverable WebSocket close (codes 1001, 1005, 1006, 4010 `MAY_TRY_RECONNECT`), the room retries with exponential backoff and replays the original `reconnectionToken` against the same room URL.
- New signals on `Colyseus.Room`:
  - `dropped(code: int, reason: String)` — fires once when the connection drops and reconnection begins.
  - `reconnected()` — fires when reconnection succeeds; any messages buffered while disconnected have already been flushed by this point.
- `room.reconnecting: bool` getter — true while the worker is mid-retry.
- `room.set_reconnection_options(options: Dictionary)` — any subset of `enabled`, `max_retries`, `min_delay_ms`, `max_delay_ms`, `min_uptime_ms`, `delay_ms`, `max_enqueued_messages`; omitted keys keep their current value. Defaults match the @colyseus/sdk TypeScript SDK (enabled, 15 retries, 100–5000 ms backoff, 5000 ms minimum uptime, 10-message queue cap).
- Messages sent via `room.send_message(...)` while the room is dropped are queued (capped at `max_enqueued_messages`) and replayed once the new transport reaches JOIN_ROOM. Unreliable variants still drop when not connected, matching the TS SDK.

### Fixed
- `Colyseus.Room.send_message(type)` (single-argument form) no longer fails with an arity error against the native vararg method; the wrapper now always forwards both `type` and `data` (defaulting `data` to `null`).
- Native build picks up the active macOS SDK via `xcrun --show-sdk-path` instead of the hard-coded Command Line Tools path, which was producing `_kSec*` / `_CF*` undefined-symbol errors when only the full Xcode SDK was available.
- Android: the GDExtension failed to load (`dlopen`: "cannot locate symbol malloc") and matchmaking failed with `TemporaryNameServerFailure`. The Android `.so` now links bionic libc via a generated NDK libc file, which gives it a `NEEDED libc.so` (fixing the loader) and routes `std.net` DNS through bionic `getaddrinfo` instead of the nonexistent `/etc/resolv.conf` (fixing matchmaking). Minimum Android API is now 24. Reported in #22.
- iOS: release build failed to link (`undefined symbol: _colyseus_monotonic_ms`) because `src/utils/time.c`, added for reconnection, was missing from the iOS build's source list.

### Tests
- Added `test_reconnect.gd` covering drop → auto-reconnect, queued-message flush, and disabled-reconnection paths against `sdks-test-server`.

## 0.17.7

### Changed
- Renamed the native GDExtension classes to `_ColyseusClient`, `_ColyseusRoom`, and `_ColyseusCallbacks` so they are hidden from Godot editor autocomplete. Continue using the public `Colyseus.Client`, `Colyseus.Room`, and `Colyseus.Callbacks` entry points — they are unchanged.

### Tests
- Added `test_schema_callbacks.gd` covering `Callbacks.on_change` for both instance and collection targets against `test_room`. Tests await `get_tree().process_frame` so deferred callback dispatch from the WebSocket thread is flushed in headless/GUT mode.
