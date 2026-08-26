# Changelog

All notable changes to the Colyseus Swift SDK will be documented in this file.

## 0.18.1

Initial release: Swift over the native C SDK, as a Swift package, for macOS,
iOS and tvOS.

### Added

- `Colyseus.Client` — `joinOrCreate`, `join`, `create`, `joinById` and
  `reconnect`, plus `latency` and `fastestEndpoint` for picking a region.
  `client.http` is the REST surface and `client.auth` the auth module
  (`register`, `signIn`, `signInAnonymously`, `userData`, `sendPasswordReset`,
  `signOut`, and `onChange` for the token).
- `Colyseus.Room<State>` — typed state, `onMessage`/`send` (and the `Bytes`
  pair), `onJoin`/`onLeave`/`onError`/`onDrop`/`onReconnect`/`onStateChange`,
  automatic reconnection with a tunable policy, `setLatency` for injected
  latency and `dropConnection` for testing what a lost network does.
- `room.request()` — a message that carries a reply, awaited. A handler that
  rejects gives you the reason it authored; one that throws faults rather than
  posing as a rejection, and a timeout gives up without leaving the reply to
  arrive later as a surprise.
- Typed state from `schema-codegen --swift`: `SchemaRef` / `SchemaView` façades
  over the decoded tree, with `MapSchema` and `ArraySchema` read live from the
  decoder. Decoding never depends on generated code — the handshake's
  reflection is enough — so codegen is a typed way to read what was decoded,
  and input schemas need nothing generated at all.
- `Colyseus.Callbacks` — `listen`, `onAdd`, `onRemove`, `onChange`, registered
  against the field to observe so a replaced collection does not silently
  unsubscribe you.
- The prediction layer: `Colyseus.Predict` for smoothing, dead reckoning and
  the frame tick; `reconciler()` for rollback prediction and `sim()` for a
  world you only partly control; `defineEvent()` for optimistic events that
  the server confirms or retracts; and `spawns()` for entities you create
  before the server does, handed off in place so the sprite keeps its identity.
- `Colyseus.InputHandle` for the channel a room's `defineInput()` declares, and
  `Colyseus.RoomClock` for local, server and render time, round trip and jitter.
- `Colyseus.pump()`. The transport runs on its own thread and inbound traffic
  is released inside the pump, so decoding, input acks and prediction writes
  all happen on the thread that reads them. An app with a frame loop sets
  `Colyseus.autoPump = false` and owns the call; anything else is pumped at
  60 Hz.
- Swift 6 language mode throughout, with no concurrency warnings.
- Shipped as a pre-built `Colyseus.xcframework` — macOS (arm64, x86_64), iOS,
  the iOS simulator (arm64, x86_64), tvOS and the tvOS simulator. The core is
  Zig as much as it is C (msgpack, HTTP and the certificate store are Zig
  modules), so SwiftPM cannot compile it from source.

### Known gaps

- Unreliable input needs a datagram transport the core does not have yet.
- `SetSchema` and `CollectionSchema` do not exist in the core.
