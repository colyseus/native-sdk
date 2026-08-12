# Changelog

All notable changes to the Colyseus GameMaker SDK will be documented in this file.

## 0.18.0

### Added
- Auth sign-in flows, alongside the token accessors that already existed:
  - `colyseus_auth_sign_in_anonymously(client, callback, [options])`
  - `colyseus_auth_register_with_email_and_password(client, email, password, callback, [options])`
  - `colyseus_auth_sign_in_with_email_and_password(client, email, password, callback)`
  - `colyseus_auth_get_user_data(client, callback)`
  - `colyseus_auth_send_password_reset_email(client, email, callback)`
  - `colyseus_auth_sign_out(client)` — drops the token here, in the on-disk
    copy, and in the platform's secure storage. `colyseus_auth_clear_token` is
    now an alias for it.
  - Each takes the same `callback(err, data)` an HTTP call does, where a
    successful `data` is the server's own `{ user, token }` reply. The token
    lands on the client, so later `colyseus_http_*` calls are authenticated.
  - The calls block in the core, so they run on the same worker thread HTTP
    uses and answer through the polled event queue — `colyseus_process()` is
    what delivers them. No new event types: an auth call is a request to
    `/auth/*`, so its reply travels as a normal HTTP response.
- `TestAuthApi` script covering the flows against the example server.
- Latency-based endpoint selection:
  - `colyseus_get_latency(client, endpoint, callback, timeout_ms = 0)` — measures the round-trip time to a server; `callback(err, latency_ms)`.
  - `colyseus_select_by_latency(client, endpoints, callback, timeout_ms = 0)` — measures an array of endpoints in parallel; `callback(err, { endpoint, latency_ms })` returns the lowest-latency endpoint.
  - Each measurement always settles — on the pong, a connection error, a server-side close before the pong, or a timeout (default 1500 ms) — so one unreachable/blackholed endpoint can't stall the selection.
  - Event types `COLYSEUS_EVENT_LATENCY_RESPONSE` (16), `COLYSEUS_EVENT_LATENCY_ERROR` (17) and `COLYSEUS_EVENT_LATENCY_SELECTED` (18), plus dispatch cases in `colyseus_process()`.
- `TestLatencyApi` script covering latency event dispatch.

## 0.17.23

### Added
- Automatic reconnection. After a recoverable WebSocket close (codes 1001, 1005, 1006, 4010 `MAY_TRY_RECONNECT`), the SDK retries the room with exponential backoff and replays the original `reconnectionToken` against the same room URL.
- `colyseus_on_drop(room, handler)` — handler `(code, reason)` fires once when the connection drops and reconnection begins.
- `colyseus_on_reconnect(room, handler)` — handler `()` fires when reconnection succeeds; any messages buffered while disconnected have already been flushed by this point.
- `colyseus_room_is_reconnecting(room)` returns 1 while the worker is mid-retry.
- `colyseus_room_set_reconnection_options(room, enabled, max_retries, min_delay_ms, max_delay_ms, min_uptime_ms, delay_ms, max_enqueued_messages)` — pass `-1` for any int parameter to keep its current value; `enabled` accepts `0`/`1`/`-1`. Defaults match the @colyseus/sdk TypeScript SDK (enabled, 15 retries, 100–5000 ms backoff, 5000 ms minimum uptime, 10-message queue cap).
- Event types `COLYSEUS_EVENT_ROOM_DROP` (14) and `COLYSEUS_EVENT_ROOM_RECONNECT` (15) plus dispatch cases in `colyseus_process()`.
- Messages sent via `colyseus_send` while the room is dropped are queued (capped at `max_enqueued_messages`) and replayed once the new transport reaches JOIN_ROOM. `sendUnreliable` variants still drop when not connected, matching the TS SDK.
- `TestReconnect` script covering drop → auto-reconnect, queued-message flush, and disabled-reconnection paths against `sdks-test-server`.

## 0.17.22

### Added
- `colyseus_on_change` GML wrapper exposing instance and collection `onChange` callbacks, matching the TypeScript SDK's `callbacks.onChange(...)` surface.
  - `colyseus_on_change(callbacks, instance, handler)` — fires when any property on the schema instance changes.
  - `colyseus_on_change(callbacks, "field", handler)` — collection change on root state; handler receives `(key, value)`.
  - `colyseus_on_change(callbacks, instance, "field", handler)` — collection change on a child instance.
- Native exports `colyseus_gm_callbacks_on_change_instance` and `colyseus_gm_callbacks_on_change_collection`, wired through the extension's `.yy` bindings for macOS and Android file entries.
- Event types `COLYSEUS_EVENT_INSTANCE_CHANGE` (12) and `COLYSEUS_EVENT_COLLECTION_CHANGE` (13) plus dispatch cases in `colyseus_process()`.
- Test coverage under `Schema onChange Callbacks` in `TestRoomApi` for instance and collection `onChange` flows.
