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

### Changed
- `colyseus_netdelay_set(room, delay_ms, jitter_ms)` now takes a ROUND TRIP and
  splits it evenly across the two directions, matching the JS SDK's `__net()`;
  jitter is symmetric (`±jitter/2` per direction) rather than one-sided. Both
  numbers previously applied to each direction, so the same figure produced
  roughly twice the RTT here as on the web — enough at a "200 ms" preset to push
  a lag-comp rewind past a server's `maxRewindMs`, which clamps the rewind and
  lands it ahead of the pose the client drew. Every binding that exposes this
  (Godot `room.set_latency`, GameMaker `colyseus_netdelay_set`, Flutter
  `room.setLatency`) inherits the new meaning; halve any value calibrated
  against the old one.
- `extrapolate` mode projected by a fixed `max_extrapolate` instead of the
  snapshot's age. The sample ring is stamped on the server axis once the clock
  syncs, but `compute_extrapolate` measured `ahead` against `render_time` (the
  frame clock the caller ticks with — machine uptime, natively). Differencing
  those puts `ahead` in the thousands, so it saturated at the cap every frame
  and the entity rendered a constant cap-sized lead along its current heading,
  most visible as a wrong position on a curving path. It now measures the age
  on the ring's own axis, matching `lerp` and the reckon path. The same
  expression exists in the JS SDK's `Predictor.computeExtrapolate`.
- `extrapolate` also held a stale slope forever once a field stopped changing.
  Samples land on CHANGE, so a field that goes still stops feeding the ring
  while patches keep arriving, and the projection stayed pinned at
  `newest + slope * max_extrapolate` indefinitely — parking the entity at a
  fixed offset, spectacularly after a teleport, whose slope is a discontinuity
  rather than a velocity. The slope window now extends to the newest patch,
  which the absent callback proves the value still held at, so it decays as the
  field stays quiet.

### Fixed
- Auth's `stored_token` is a process-wide pointer that every response rewrites,
  with no lock. A host that runs HTTP on a worker thread (the Flutter binding
  does, because `colyseus_http_*` blocks) races it against a client being
  constructed on the main thread and frees the string mid-`strdup`. Now guarded,
  compiled away on Emscripten like net_delay.c's.
- The auth callbacks handed the result to the app BEFORE settling their own
  state, so a binding that resolves a future from `on_success` gave the app the
  thread back while the core still had to touch `auth` — disposing the client
  there freed it under `auth_emit_change`. They now emit first and hand out
  second, which is also the JS SDK's order (`emitChange(data)` precedes the
  promise resolving).
- A successful `colyseus_auth_get_user_data` cleared the token that authorised
  it: `/auth/userdata` answers with the user and no token, and emitting that
  verbatim took `auth_emit_change`'s no-token branch, wiping both the header and
  the stored copy. It now carries the current token through, matching the JS
  SDK's `{...userData, token: this.token}`.
