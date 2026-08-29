# Changelog

All notable changes to the Colyseus Native SDK (C core / static library) will be documented in this file.
Per-binding changes are tracked in [platforms/godot/CHANGELOG.md](platforms/godot/CHANGELOG.md), [platforms/gamemaker/CHANGELOG.md](platforms/gamemaker/CHANGELOG.md), [platforms/flutter/colyseus/CHANGELOG.md](platforms/flutter/colyseus/CHANGELOG.md) and [platforms/swift/CHANGELOG.md](platforms/swift/CHANGELOG.md).

## 0.18.2

### Added

- `#include <colyseus.h>` is now the whole integration surface — one header for
  the client, room, schema, prediction and auth APIs. Linking the `colyseus`
  artifact from a Zig build carries its header tree, so consumers need no
  `addIncludePath`; for everyone else `-I zig-out/include` is the only include
  path.

### Fixed

- A release archive can be linked. `zig build` installed `libcolyseus.a` alone,
  but a static archive does not absorb what it links against, so every
  documented `-lcolyseus` line failed on mbedTLS, wslay and the Zig
  http/msgpack/URL symbols — the native tarballs were unusable outside a Zig
  build. The whole static closure now installs alongside it, and
  `cc app.c -I include lib/*.a` links and runs.
- The web build links again. `build-wasm.sh` kept its own copy of the source
  list, 13 files behind `build.zig`, so the WASM archive was missing the whole
  prediction layer, `room_clock`, `input_handle`, `net_delay`, the latency probe
  and quantization — it compiled but could not link. It now builds through
  `zig build -Dtarget=wasm32-emscripten`, the way the GameMaker HTML5 script
  already did, so there is no second list to drift. The WASM release archive
  also carries the msgpack and URL-parsing libraries emscripten needs at the
  final link.
- The installed headers now compile. `zig build` shipped a hand-written list of
  20 of the tree's 36 headers, so `#include <colyseus/schema.h>` against a
  release archive failed on the missing `schema/dynamic_schema.h`, and the whole
  prediction API, `room_clock.h`, `input_handle.h` and `net_delay.h` never
  shipped at all.

### Changed

- No public header pulls in a vendored dependency's headers any more. The
  WebSocket transport's own state and the mbedTLS TLS context moved to `src/`,
  and `wslay/wslay.h` and `wslay/wslayver.h` are no longer installed. Code
  reaching `transport->impl_data` as a `colyseus_ws_transport_data_t` was
  reaching into the SDK's internals and will no longer compile.

## 0.18.1

### Added

- A Swift binding — [platforms/swift](platforms/swift), published to
  [colyseus/colyseus-swift](https://github.com/colyseus/colyseus-swift) for
  SwiftPM.
- `colyseus_room_request_encoded_reply()` — a request's reply, undecoded. Every
  binding decodes msgpack in its own language so an `onMessage` payload lands as
  one native value type, and the reply only came out through
  `colyseus_message_reader_t`; that would have made `request()` the one call in
  a binding answering in a second value type. The reader form stays for C
  callers, and the encoded callback carries `colyseus_request_outcome_t` so a
  binding branches on an outcome rather than comparing the error string against
  `"request faulted"`.
- The field-slot walk is public API, in `include/colyseus/schema/` under
  `colyseus_`-prefixed names. Reading a field by name is how a binding turns a
  decoded instance into something its users can touch; it lived under
  `src/predict/`, so every port reached it through `../../../src/` and Flutter
  wrapped each accessor in C glue because Dart cannot call a `static inline`.
- `-Dstrip`, which is what lets the Zig modules target tvOS: 0.15's DWARF
  unwinder has no mcontext layout for the platform, and anything that can panic
  pulls the stack-trace machinery in.

### Fixed

- `colyseus_room_get_state()` handed out freed memory while a room was closing.
  Teardown cleared the ref tracker, destroying the state tree, but left the
  decoder pointing at it — reading state during a failed reconnect read the
  freed tree.
- Encoding a message freed its buffer twice for anyone following the header:
  `colyseus_message_encoded_free()` was published while the builder kept the
  buffer and freed it itself. Encoding now hands back a buffer to free and
  leaves the message intact, so the same message can be sent more than once.
- Request ids start at 1. Every entry point returns 0 for "not sent", so the
  first request in a room minted an id a caller could not tell apart from
  failure.

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
- Leaving a room could crash the process (`malloc_consolidate(): invalid chunk
  size` on Linux) once the state held a `t.ref()` field pointing at something
  also stored in a map or array — the same `Player` as both `players[id]` and
  `host`. Teardown freed that instance twice. The same crash could come from an
  array holding one instance in two slots.
- An `ADD` for an array index that already held that exact instance inserted a
  second slot for it, so the array reported one more entry than the server sent.
- Automatic reconnection could wedge forever: a retry whose `connect()` failed
  before a socket existed (DNS down, typical right after an Android resume)
  reported only `on_error`, so the worker waited for a close that never came.
  `is_reconnecting` stayed true and `on_leave` never fired. Such a retry now
  counts as a failed attempt. Reported by @zahmad12 in [#27](https://github.com/colyseus/native-sdk/issues/27).
- Automatic reconnection only worked once per room: the retry thread exited
  after a successful cycle and the next drop found nothing to act on, leaving
  `is_reconnecting` true forever. The next drop now gets a fresh worker.
- `colyseus_client_reconnect()` never succeeded: the server rejected the
  socket with "bad reconnection token" because the token wasn't forwarded to
  the WebSocket URL. `colyseus_room_get_reconnection_token()` now returns the
  `roomId:token` form `reconnect()` takes, matching the JS SDK, so the round
  trip works as-is. [#26](https://github.com/colyseus/native-sdk/issues/26)
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
- The WebSocket transport freed itself out from under its own tick thread.
  `ws_close_impl` deferred the close whenever `in_tick_thread` was set — but
  that flag meant "a tick thread is running", not "the caller IS the tick
  thread". Any other caller (a room teardown, a latency probe finishing on its
  coordinator thread) therefore took the defer branch, returned WITHOUT
  joining, and `ws_destroy_impl` freed the struct while the loop was still
  reading it. The thread then ran on with a dangling transport, which surfaced
  as `panic: member access within null pointer of type
  'colyseus_ws_transport_data_t'` inside `ws_recv_callback`. The transport now
  records its tick thread's identity and compares against the caller, so only
  the tick thread defers and everyone else joins.

  This is the teardown race the Godot suite hit in `test_latency` and the
  Flutter `netdelay_test` hit roughly one run in three. After the fix: 8
  consecutive clean Godot runs with zero panics, and 8 consecutive clean
  netdelay runs.
