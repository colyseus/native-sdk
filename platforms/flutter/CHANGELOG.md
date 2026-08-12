# Changelog

All notable changes to the Colyseus Flutter SDK will be documented in this file.

## 0.18.0

### Added

- Client-side prediction, the 0.18 headline feature, with ordinary Dart
  closures for every step function:
  - `Predict.of(room)` with `attach` / `attachAll` taking the same declarative
    per-field config as the TypeScript SDK (`{'x': PredictMode.damped}`), plus
    `attachAllReckon` for entities the client can simulate itself. Modes:
    `lerp`, `extrapolate`, `damped`, `reckon`, `raw`.
  - `predict.tick(now)` returns the fixed input steps due this frame;
    `predict.value(instance, field)` is the one read idiom, falling back to the
    raw decoded value for untracked fields.
  - `predict.reconciler(...)` for the locally-controlled entity: predicts each
    input immediately, rewinds and replays on server correction, and exposes
    `value` / `state` / `pendingCount` / `reconcileSeq` / `lastCorrection` /
    `drift` / `reset`.
  - `predict.sim(...)` for entities that interact, where rolling one back means
    rolling back what it collided with. Parts are either bound to a decoded
    instance or opaque — an entity the client simulates itself, carried
    through untouched and restored by the world's `adopt`.
  - `predict.defineEvent(...)` for optimistic events, predicted from the
    simulation with `ctx.predict` (replay-safe) or from UI code with
    `channel.predict`, settled with `confirm` / `reject`.
  - `predict.spawns(...)` for optimistically created entities, correlated with
    the authoritative entity when it arrives so the handoff is invisible.
  - `StepContext` with `dt` / `tick` / `isReplay` / `reckonTime`, plus `memo`
    and `memoVec` for values a replay could not re-derive.
  - `classifyDrift(drift)` telemetry.
- `room.input()` — the typed input channel. Its schema comes from the server
  handshake, so field names match the room's `defineInput()` with no generated
  classes.
- `room.clock` — `now`, `serverNow`, `renderNow`, `rtt`, `smoothedRtt`,
  `jitter`, `lastServerTime`, `patchInterval`.
- `SchemaView` — name-resolved field access for the per-frame paths. One leaf
  FFI call per read, against `SchemaInstance`'s lookup per access.
- `room.setLatency()` and `room.dropConnection()` — inject latency and jitter
  at the transport seam, or drop the connection to exercise reconnection.
  The delay is a round trip, split evenly across the two directions, so a
  given number means the same `clock.smoothedRtt` here as in the JS SDK.
- `room.ping()` — an active round-trip measurement, which is the only one
  available to rooms that declare no inputs.
- `Colyseus.selectByLatency(endpoints)` — measure several endpoints and take
  the fastest.
- `Colyseus.pump()` and `Colyseus.autoPoll` — drive the SDK from the app's own
  frame callback instead of its internal timer, so decoding, prediction and
  rendering all happen on one thread inside one frame.

### Changed

- Inbound traffic is serialized onto the pumping thread. Rooms wrap their
  transport at join, so frames are decoded inside the pump rather than on the
  WebSocket thread, and the event queue is filled and drained within a frame.
- The 0.18 surface binds directly to the core's C API through generated
  bindings (`dart run ffigen`) rather than through hand-written glue.
- Apple builds pin a deployment minimum instead of inheriting the build
  machine's OS version, and the two macOS slices are fused into one universal
  dylib rather than overwriting each other.
- iOS force-loads the static archive. Dart resolves symbols at runtime, so
  nothing kept them from being stripped.

### Fixed

- `MapSchema` and `ArraySchema` were handle-only shells. They now have
  `length`, `keys`, `values`, `entries`, `forEach` and `operator[]`. Arrays
  iterate in decoded-index order; the native storage prepends, so raw
  iteration order is reversed.
- Received messages lost every nested map and array — the native reader cannot
  recurse and returned null for them. Decoding moved to a Dart msgpack decoder
  over the raw payload.
- Message payloads were truncated at 8 KB by a fixed buffer.
- Primitive collection items surfaced as raw pointers cast to integers.
- Schema callbacks leaked: each subscription built its own wrapper, the fifth
  was silently dropped, and cancelling a `StreamSubscription` left the native
  callback registered.
- Windows: cJSON's `dllexport` suppressed MinGW's export-all, leaving a DLL
  that exported nothing else. The core build takes `-Dhide-cjson-exports`
  (off by default) and the Flutter build sets it.

### Known gaps

- `room.request()` / response is not bound. The reply arrives as a message
  reader with no accessor for the underlying bytes, so there is nothing for
  the Dart decoder to read; it needs a small addition to the core reader.
- `client.http` and `client.auth` are not bound.
- On Windows the predict layer's objects are still dead-stripped out of the
  DLL. Every other platform links them through the anchor table in
  `src/flutter_extras.c`.
- Auto-reconnect works exactly once per room. This is a core defect, not a
  binding one: `room_reconnect_worker_spawn()` in `src/room.c` guards on a
  `thread_started` flag it never clears, and the worker thread returns once a
  reconnect succeeds, so a second drop leaves the room reconnecting forever
  with nothing running to service it. `test/integration/teardown_stress_test.dart`
  pins it (skipped, with the reason). Every other binding shares the defect.
