# Changelog

All notable changes to the Colyseus Godot SDK will be documented in this file.

## 0.17.6

### Changed
- Renamed the native GDExtension classes to `_ColyseusClient`, `_ColyseusRoom`, and `_ColyseusCallbacks` so they are hidden from Godot editor autocomplete. Continue using the public `Colyseus.Client`, `Colyseus.Room`, and `Colyseus.Callbacks` entry points — they are unchanged.

### Tests
- Added `test_schema_callbacks.gd` covering `Callbacks.on_change` for both instance and collection targets against `test_room`. Tests await `get_tree().process_frame` so deferred callback dispatch from the WebSocket thread is flushed in headless/GUT mode.
