# Changelog

All notable changes to the Colyseus Godot SDK will be documented in this file.

## 0.17.8

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

### Tests
- Added `test_reconnect.gd` covering drop → auto-reconnect, queued-message flush, and disabled-reconnection paths against `sdks-test-server`.

## 0.17.7

### Changed
- Renamed the native GDExtension classes to `_ColyseusClient`, `_ColyseusRoom`, and `_ColyseusCallbacks` so they are hidden from Godot editor autocomplete. Continue using the public `Colyseus.Client`, `Colyseus.Room`, and `Colyseus.Callbacks` entry points — they are unchanged.

### Tests
- Added `test_schema_callbacks.gd` covering `Callbacks.on_change` for both instance and collection targets against `test_room`. Tests await `get_tree().process_frame` so deferred callback dispatch from the WebSocket thread is flushed in headless/GUT mode.
