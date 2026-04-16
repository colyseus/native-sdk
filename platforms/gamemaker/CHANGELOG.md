# Changelog

All notable changes to the Colyseus GameMaker SDK will be documented in this file.

## 0.17.22

### Added
- `colyseus_on_change` GML wrapper exposing instance and collection `onChange` callbacks, matching the TypeScript SDK's `callbacks.onChange(...)` surface.
  - `colyseus_on_change(callbacks, instance, handler)` — fires when any property on the schema instance changes.
  - `colyseus_on_change(callbacks, "field", handler)` — collection change on root state; handler receives `(key, value)`.
  - `colyseus_on_change(callbacks, instance, "field", handler)` — collection change on a child instance.
- Native exports `colyseus_gm_callbacks_on_change_instance` and `colyseus_gm_callbacks_on_change_collection`, wired through the extension's `.yy` bindings for macOS and Android file entries.
- Event types `COLYSEUS_EVENT_INSTANCE_CHANGE` (12) and `COLYSEUS_EVENT_COLLECTION_CHANGE` (13) plus dispatch cases in `colyseus_process()`.
- Test coverage under `Schema onChange Callbacks` in `TestRoomApi` for instance and collection `onChange` flows.
