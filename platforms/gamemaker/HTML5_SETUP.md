# Colyseus GameMaker Extension — HTML5 Setup

HTML5 builds run the **same C SDK compiled to WebAssembly** — there is no
separate JavaScript implementation. The extension ships one file for the web
target:

- `colyseus_wasm.js` — the Emscripten-compiled SDK (WASM embedded via
  `SINGLE_FILE`) concatenated with a thin shim that exposes every extension
  function as `window.colyseus_gm_*`, the calling convention GameMaker's
  HTML5 runner uses.

## How it works

1. `build-wasm.sh` compiles the SDK sources for `wasm32-emscripten` (Zig,
   stage 1) and links them with `src/gamemaker_export.c` +
   `src/gamemaker_predict.c` via `emcc` (stage 2), producing
   `wasm-out/colyseus_wasm.js`.
2. The shim (`src/gamemaker_wasm_shim.js`) is appended to the module. Its
   binding block is **generated** by `gen-bindings.mjs` from the C sources —
   run `node gen-bindings.mjs` after adding or changing any `GM_EXPORT`, and
   `node gen-bindings.mjs --check` runs in CI to catch drift.
3. GameMaker's HTML5 runner loads the file itself: the export packs it as
   `html5game/uph_colyseus_wasm.js` and lists it in the game's extension
   manifest, and the runner appends the `<script>` and waits for it before
   entering the main loop. (The extension carries no `HTML5CodeInjection`
   for this reason: a `<script src>` of its own would 404 at the page root
   or instantiate the module twice.)
4. The WASM module compiles **synchronously** (`-sWASM_ASYNC_COMPILATION=0`),
   and the fetch library skips its IndexedDB setup
   (`-sFETCH_SUPPORT_INDEXEDDB=0`, the SDK never persists responses), so the
   module is up by the time the runner enters its main loop.

## Using it in a project

Nothing extra: the extension asset already carries `colyseus_wasm.js` with
`copyToTargets` set for HTML5. Export for HTML5/GX.Games and the same GML
API works unchanged — including the prediction layer (input handles,
predict, reconciler pump, spawns, events, netdelay).

### Creating the client

Create it in a Create event, as on native:

```gml
// Create
client = colyseus_client_create("https://example.com");
room = colyseus_client_join_or_create(client, "my_room", {});
// register handlers...

// Step
colyseus_process();
```

The synchronous compile needs a browser that allows one this size on the
main thread. Chrome before roughly version 115 (mid-2023) does not, and the
extension fails to load there: `colyseus_is_ready()` stays false, and
`colyseus_client_create()` returns 0 and logs that the extension is not
ready.

Platform notes:

- The browser is single-threaded: all callbacks land on the JS event loop
  and are drained by `colyseus_process()` exactly like on native.
- Reconnection is **polled** on web — the wrapper calls
  `colyseus_gm_reconnect_poll()` from `colyseus_process()`, so automatic
  reconnection works without threads.
- HTTP requests are performed by the shim via `fetch()` and pushed back into
  the event queue (`colyseus_gm_http_push_response/error`).

## Rebuilding

```bash
# prerequisites: zig, emsdk (emcc on PATH)
cd platforms/gamemaker
./build-wasm.sh        # writes wasm-out/colyseus_wasm.js and copies it
                       # into example/BlankProject's extension folder
```

## Validating

`tests-web/` drives the wasm bundle headlessly, calling
`window.colyseus_gm_*` exactly as GML would, against the prediction-tools
playground server:

```bash
# terminal 1: cd demos/prediction-tools && pnpm dev --host 0.0.0.0
cd platforms/gamemaker
./tests-web/run-web-tests.sh
```
