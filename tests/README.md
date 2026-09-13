# Colyseus Native SDK Test Suite

Zig test suites for the C core, run from the repository root with **zig 0.15.x**
(CI uses 0.15.2; 0.16 is not supported yet).

## Running

```bash
zig build test -Dskip-integration=true   # offline suites only, no server needed
zig build test                           # everything; see "Integration suites" below
zig build test_transport                 # one suite, by name
zig build --help                         # lists every test_* step
```

A fresh checkout needs its submodules first: `git submodule update --init --recursive`.

## Offline suites

Byte fixtures and in-process peers, no network: `test_suite`, `test_http`,
`test_auth`, `test_room`, `test_storage`, `test_schema`, `test_schema_arrayops`,
`test_schema_resync`, `test_room_protocol`, `test_quantized`, `test_input`,
`test_predict`, `test_netdelay`, `test_msgpack_builder`, `test_transport`,
`test_poll`, `test_gamemaker_predict`, `test_gamemaker_schema`.

`test_transport` drives the native WebSocket transport against a loopback
WebSocket peer it runs itself (`tests/ws_peer.zig`): `localhost` served on
`::1` only, a refused connection, a peer that resets mid-connection (it
restores SIGPIPE's default action, so a raised SIGPIPE kills the test binary
exactly as it kills an app), and threaded vs polled delivery. POSIX only;
skipped on Windows.

`test_poll` covers `colyseus_set_polled(true)` + `colyseus_poll()` with the
same peer and a refused port: a matchmaking result and a latency probe arrive
on the polling thread and only inside the poll, a nested `colyseus_poll()` is a
no-op, and a send from the polling thread reaches the peer without another
poll (from any other thread it waits for one). POSIX only.

## Integration suites

These talk to a real server on `localhost`:

| Server | Port | Suites | Start it (from the repo root) |
|--------|------|--------|-------------------------------|
| example-server | 2567 | `test_integration` `test_schema_callbacks` `test_schema_reflection` `test_messages` `test_request` `test_view_callbacks` `test_reconnect` `test_poll_integration` `test_gamemaker_net` | `cd example-server && npm install && npx tsx src/index.ts` |
| wss echo server | 2569 | `test_tls` (not on Windows) | `bash tests/tls/gen-certs.sh && node tests/tls/wss-echo-server.mjs --port 2569` |

`build.zig` probes each port while it configures the build. When a server is
down:

- `zig build test_messages` (a suite by name) fails at once, naming the server
  and the command above, instead of failing inside the suite on
  `waitForJoin` or `ConnectionRefused`.
- `zig build test` skips that server's suites and prints a `SKIPPED` warning
  after the rest have run. The offline suites still gate the result.
- With `CI` set (GitHub Actions sets it), nothing is skipped: those suites fail
  with the same message, so a server that failed to start fails the run.
- `-Dskip-integration=true` leaves the integration suites out without a warning.

`tests/dev-servers.sh` starts example-server only when it isn't already up, and
stops only what it started:

```bash
source tests/dev-servers.sh
servers_ensure --room my_room --room view_test_room example-server 2567 example-server npx tsx src/index.ts
zig build test
servers_stop
```

Another project's server can hold :2567. The probe only checks that the port
answers, so `--room` is what catches a server that lacks these rooms.

## Adding a suite

1. Create `tests/test_<name>.zig`.
2. Register it in the `zig_test_files` list in `build.zig`:

   ```zig
   .{ .name = "test_myfeature", .file = "tests/test_myfeature.zig", .description = "Run my feature tests" },
   ```

   Add `.server = .example` (or `.wss_echo`) when it needs a running server;
   that is what `-Dskip-integration` and the probe key on.

Test executables link `libcolyseus` and have `include/`, `src/` and `tests/` on
the include path, so a suite can `@cInclude` internal headers when it has to
reach into implementation state (`test_tls` and `test_transport` do).
