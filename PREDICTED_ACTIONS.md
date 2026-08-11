# Predicted actions for the Native SDK (C core) + GameMaker (GML)

> Port of `colyseus-0.18` **brief 18 — Predicted actions + server-driven rollback**
> (`predict.action` / Rune-style `invalidAction()`) to the shared **C core** and the
> **GameMaker** binding. The server stays the *exact* TypeScript room from brief 18 —
> this doc is **client-only**: it designs the native client surface so the same mental
> model ("an action is a send that predicts and rolls back if the server says no")
> reads identically in TS, GML, C, GDScript and Dart.

- **Status:** Design — not started. Depends on a foundational gap (below).
- **Source brief:** `colyseus-0.18/TODO/18-predicted-actions-server-rollback.md`
- **Area:** `src/room.c` + `include/colyseus/room.h` (core), `platforms/gamemaker` (binding).

---

## 0. The one-line mental model (this is the whole port)

```
colyseus_send(room, "fire", payload)     // fire-and-forget. Server return ignored.
colyseus_action(room, "fire", { ... })   // SAME send — but predict NOW, and the
                                          // server's reply is an accept/reject verdict.
                                          // Reject → roll back immediately (not at TTL).
```

An **action targets the same server `messages.fire` handler** a `send` does. Nothing new
to declare server-side; the client just *chose* the "predict + await verdict" mode. That
parallel — `send` vs `action` — is the entire user-facing idea, and it survives every
language because it's a runtime behaviour, not a type trick.

---

## 1. What ports, and what doesn't (be honest)

Brief 18 leans on three TS-only luxuries. Two of them do **not** survive to C/GML, and
pretending otherwise would make the port ugly. The *runtime semantics* port 1:1; the
*compile-time* guarantees are TS-only.

| Brief-18 pillar | Ports to C/GML? | Native form |
|---|---|---|
| Optimistic predict → immediate server reject | ✅ 1:1 | The core's verdict registry + TTL backstop |
| Reuse `ROOM_REQUEST`/`ROOM_RESPONSE` (21/22), zero new opcodes | ✅ but **must be added to the core first** (§2) | `COLYSEUS_PROTOCOL_ROOM_REQUEST/RESPONSE` |
| `ResponseStatus.REJECTED` carries a typed reason | ✅ runtime | Reason delivered as a `colyseus_message_reader_t*` (like `on_message`) |
| `id` doubles as the tag-echo `predictId` | ✅ 1:1 | `uint32_t id`, stamped on your entity |
| TTL backstop (`max(2×rtt, 600ms)`) | ✅ 1:1 | Core-side pruning |
| `rollback` optional, transport inferred from `input` | ✅ conceptually | `rollback == NULL` / `input == NULL` flags (vs a TS closure-or-not) |
| Graceful degradation (old server → accept) | ✅ 1:1 | It's wire-level, language-agnostic |
| **Full-stack types** (`Rejection<R>`, `ExtractRejectReason`, payload inference) | ❌ **does not port** | C/GML are dynamically typed: payload is a runtime struct / `colyseus_message_t*`, reason is a reader. No `satisfies Messages<this>` on the client. |
| **`fire(payload)` as a returned closure** | ⚠️ reshaped | Returns a **handle** + `colyseus_action_fire(handle, payload)` — consistent with the SDK's handle idiom (`room`, `callbacks`). GML may also return a callable `method`. |

**Takeaway:** the port is a faithful copy of the *behaviour* and the *vocabulary*
(`action` / `fire` / `predict` / `rollback` / `reason` / `id`). The type safety simply
isn't claimed where the language can't back it — that honesty keeps the C/GML API clean
instead of bolting on a fake-typed ceremony.

---

## 2. Foundational gap — the core has no request/response yet

`predict.action` is, on the wire, *a request whose response is the verdict*. The TS SDK
already has `room.request`; **the C core does not**. Today the core's opcodes stop at
`PONG = 19` (`include/colyseus/protocol.h`) — there is no `ROOM_REQUEST (21)` /
`ROOM_RESPONSE (22)`, no `requestId` minting, no pending-correlation. So step zero of this
port is to add request/response to the core — which is **independently worth having**
(`room.request` is a documented TS feature with no native equivalent).

Prerequisites, in order:

1. **`COLYSEUS_PROTOCOL_ROOM_REQUEST = 21` / `COLYSEUS_PROTOCOL_ROOM_RESPONSE = 22`** in
   `protocol.h`; a `uint32_t` monotonic request-id counter on `colyseus_room`.
2. **`colyseus_response_status_t`** — `OK = 0`, `ERROR = 1`, `REJECTED = 2` (the new arm).
3. A core **id → pending-verdict registry** (uthash, like `message_handlers`) with a
   per-entry TTL. `predict.action`, the low-level `colyseus_room_request`, and (later)
   in-frame actions all share this one registry.

Only once that exists does the action layer become a thin thing on top. **The standalone
transport needs nothing else** — which is why standalone is the portable MVP and in-frame
(which needs a native input system that also doesn't exist yet) is deferred to §7.

---

## 3. The C core API

The native SDK's architecture is "one shared C core, thin per-engine bindings." So the
real design lives in `room.h`; GML/Godot/Flutter are sugar over it. C has no closures and
no generics, so config is **function pointers + `void* userdata`**, and the call returns
an opaque **action handle**.

```c
/* ── include/colyseus/action.h ───────────────────────────────────────────── */
typedef struct colyseus_action colyseus_action_t;

/* predict() runs SYNCHRONOUSLY inside colyseus_action_fire() — instant local
 * feedback. Return an opaque handle (your spawned entity, a malloc'd struct,
 * anything); the core stores it and hands it back to rollback/on_accept. `ctx`
 * is the per-fire pointer you passed to _fire, borrowed for THIS call only. */
typedef void* (*colyseus_action_predict_fn)(uint32_t id, void* ctx, void* userdata);

/* Server rejected (REJECTED) or the handler threw (ERROR), or the TTL expired.
 * `reason` is the raw typed reason for REJECTED (a reader over msgpack — may be
 * a string, int, or map), or NULL for ERROR/TTL. Undo your prediction here. */
typedef void  (*colyseus_action_rollback_fn)(void* handle, colyseus_message_reader_t* reason, void* userdata);

/* Server accepted (OK, or in-frame: input-ack past the seq with no reject).
 * Optional — only needed to confirm an effect-less action (a cosmetic emote). */
typedef void  (*colyseus_action_accept_fn)(void* handle, void* userdata);

typedef struct {
    colyseus_action_predict_fn   predict;     /* required */
    colyseus_action_rollback_fn  rollback;    /* optional (see note) */
    colyseus_action_accept_fn    on_accept;   /* optional */
    void*    userdata;

    /* Transport. input == NULL ⇒ standalone request/response (Phase 1).
     * input != NULL ⇒ ride the input frame, tick-aligned (Phase 2, §7). */
    colyseus_input_t* input;
    bool     unreliable;   /* standalone only: send over the unreliable channel  */
    uint32_t ttl_ms;       /* 0 ⇒ default max(2×rtt, 600ms) safety net           */
} colyseus_action_options_t;

/* Bind an action to a server message `type` (the same name colyseus_send uses). */
colyseus_action_t* colyseus_action_create(colyseus_room_t* room, const char* type,
                                          const colyseus_action_options_t* options);

/* Predict NOW + transmit. Returns the minted id (== tag-echo predictId), so you
 * can stamp it onto your entity for spawn-correlation. `payload` is the wire
 * message — caller RETAINS ownership and frees it after _fire returns (mirrors
 * colyseus_room_send). `ctx` is forwarded to predict() and not retained. */
uint32_t colyseus_action_fire(colyseus_action_t* action, colyseus_message_t* payload, void* ctx);

void colyseus_action_free(colyseus_action_t* action);  /* cancels any in-flight verdicts */
```

### Worked example — the shooter "fire" in C

```c
typedef struct { float x, y; } fire_ctx_t;

static void* predict_bullet(uint32_t id, void* ctx, void* userdata) {
    fire_ctx_t* f = (fire_ctx_t*)ctx;
    bullet_t* b = spawn_local_bullet(f->x, f->y);  /* renders instantly */
    b->predict_id = id;                            /* tag-echo: correlate the server's copy */
    return b;                                      /* handle → rollback/on_accept */
}
static void rollback_bullet(void* handle, colyseus_message_reader_t* reason, void* userdata) {
    bullet_t* b = (bullet_t*)handle;
    const char* why = reason ? colyseus_message_reader_get_str(reason, NULL) : "timeout";
    log_info("shot rejected: %s", why);            /* "cooldown" / "dead" */
    despawn_bullet(b);                             /* the ghost vanishes NOW, not at 2×RTT */
}

colyseus_action_options_t opts = {
    .predict  = predict_bullet,
    .rollback = rollback_bullet,
};
colyseus_action_t* fire = colyseus_action_create(room, "fire", &opts);

/* ...each time the player shoots: */
fire_ctx_t fctx = { .x = aim_x, .y = aim_y };
colyseus_message_t* p = colyseus_message_map_create();
colyseus_message_map_put(p, "x", aim_x);           /* C11 _Generic: auto-detects float */
colyseus_message_map_put(p, "y", aim_y);
uint32_t id = colyseus_action_fire(fire, p, &fctx);
colyseus_message_free(p);                           /* caller owns the payload */
```

Notes that keep this clean and honest:

- **`predict` is synchronous inside `_fire`**, so `ctx` can be a stack pointer (`&fctx`) —
  no allocation, no lifetime puzzle. This sidesteps C's lack of closures: instead of a
  captured `payload`, you thread a borrowed `ctx`. (You reference your data twice — once
  to build the wire `payload`, once via `ctx` — which is just normal C, not a wart.)
- **`rollback == NULL` is allowed only when the handle can self-cancel** — i.e. when
  `predict` returned a `colyseus_spawn_handle_t` from the predicted-spawns store (§6); the
  core then calls its `cancel()`. For a hand-rolled handle the core can't know how to undo
  it, so `rollback` is required. This mirrors brief 18's "default cleanup is `H.cancel()`,
  present only for custom undo."
- **Low-level escape hatch (the `room.action` analog).** Omit `predict` entirely and use
  the returned `id` to do the optimistic spawn inline at the call site, keeping your own
  `id → entity` map; the core then calls `rollback(NULL-handle-keyed-by-id, …)`. This is
  the C-native style for programmers who'd rather own their data structures than register a
  callback. Both styles share the same id-correlation + TTL primitive.

---

## 4. The GameMaker (GML) API

GML has what C lacks — **anonymous functions (closures) and live structs** — so the port
lands almost exactly on the TS shape. Payloads are GML structs (the same ones
`colyseus_send` already takes), and `predict`/`rollback` are GML functions. No `ctx`
threading, no round-trip: the closure captures, and `payload` is a live struct.

```gml
// Create event — bind the action to the server's "fire" handler.
shoot = colyseus_action(colyseus_room, "fire", {
    predict: function(payload, id) {
        // optimistic: spawn a local-only bullet, tag it for correlation
        var b = instance_create_layer(payload.x, payload.y, "Bullets", obj_bullet);
        b.predict_id = id;
        return b;                       // handle → rollback / on_accept
    },
    rollback: function(handle, reason) {
        // server said no (reason == "cooldown" / "dead") — undo immediately
        if (instance_exists(handle)) instance_destroy(handle);
        show_debug_message("shot rejected: " + string(reason));
    },
    // on_accept: function(handle) { ... }   // optional — confirm an effect-less action
    // unreliable: true                      // optional — standalone unreliable send
});

// anywhere — fire it. Predicts NOW, sends, awaits the verdict.
if (mouse_check_button_pressed(mb_left)) {
    colyseus_action_fire(shoot, { x: mouse_x, y: mouse_y });
}
```

GML conventions this respects (verified against the existing extension):

- **Snake-case `colyseus_*`**, callbacks as `function(...) {}`, handles as opaque values,
  one `colyseus_process()` pump per Step — identical to `colyseus_on_message`,
  `colyseus_listen`, `colyseus_on_add`. An action is just another registration.
- **`colyseus_action_fire(shoot, { ... })`** mirrors `colyseus_send(room, "fire", { ... })`
  exactly — same struct-as-payload, one extra word (`action_fire` vs `send`) and you've
  upgraded fire-and-forget to predicted-with-rollback. That symmetry is the pitch.
- **`reason` arrives decoded** (string/real/struct), like the `_data` in
  `colyseus_on_message(room, fn(_room, _type, _data))` — no reader API surfaced to GML.
- **GC handles memory** — the `handle` you return from `predict` is whatever you want
  (instance id, struct); the binding never frees it, it only passes it back.

Optional sugar (decide during impl): `colyseus_action` could return a **callable method**
so `shoot({ x, y })` works directly. The handle form is recommended as the default for
consistency with the rest of the SDK; the method form is a nicety, not the contract.

---

## 5. Side-by-side: the same action in three languages

```
TS    const fire = predict.action(room, "fire", { predict: (p,id)=>spawn(p,id), rollback: undo });
      fire({ x, y });

GML   shoot = colyseus_action(room, "fire", { predict: function(p,id){...}, rollback: function(h,r){...} });
      colyseus_action_fire(shoot, { x, y });

C     colyseus_action_t* fire = colyseus_action_create(room, "fire",
          &(colyseus_action_options_t){ .predict = predict_bullet, .rollback = rollback_bullet });
      colyseus_action_fire(fire, payload, &ctx);
```

Same five nouns everywhere: **action · fire · predict · rollback · reason/id.** A developer
who learned it in one engine reads it in any other. Godot (`Colyseus.action(room, "fire",
{...})` with GDScript `Callable`s) and Flutter (`room.action("fire", predict: ..., rollback:
...)`) fall out of the same C core with no new design — they're just thinner or thicker
sugar over `colyseus_action_create` / `_fire`.

---

## 6. Predicted-spawns store (makes `rollback` optional, adds handoff)

The TS port returns a `SpawnHandle { id, cancel() }` from `predict.spawns(...).spawn()`,
which is what makes brief-18 `rollback` *optional* (default = `handle.cancel()`) and gives
seamless predicted→authoritative **handoff** via the `predictId` tag-echo. The native core
gets the same primitive so the two tiers match:

```c
/* Mirrors PredictedSpawns<S,L,D> — correlates the server's entity (matched by
 * the predictId your action stamped) onto your local prediction, same stable id. */
colyseus_spawns_t*       colyseus_predict_spawns(colyseus_room_t* room, const char* collection_key,
                                                 const colyseus_spawns_options_t* options);
colyseus_spawn_handle_t* colyseus_spawns_spawn(colyseus_spawns_t* store, void* local);
void                     colyseus_spawn_handle_cancel(colyseus_spawn_handle_t* h);  /* the default rollback */
```

With a spawn store, `predict` returns the spawn handle and you may leave `rollback`
**NULL** — the core cancels the handle on a reject and disarms the TTL on an accept,
keeping the legitimate-but-slow spawn alive until its `onAdd` patch lands (brief 18's
"accept protects a legitimate spawn" rule). In GML the store is `colyseus_predict_spawns`
and the spawn handle exposes `.cancel()` the same way.

This is a **separate, larger** piece of work than the standalone action — it presupposes
the native callbacks/collection layer can stream `onAdd`/`onRemove` to a store (it can:
`colyseus_on_add` / `colyseus_on_remove` already exist). Treat it as Phase 1.5: ship the
explicit-`rollback` action first, add the store when predicted *entities* (not just
effects) are needed.

---

## 7. Transport tiers — standalone now, in-frame later

Brief 18 infers transport from whether you pass an `input` handle. Native mirrors the knob
(`opts.input`) but the realistic rollout is gated by what the core has:

- **Phase 1 — standalone (`input == NULL`).** Needs only request/response (§2). Sent at
  `_fire()`. This is the portable MVP and the default. `unreliable` selects the unreliable
  channel where present, else falls back to reliable (same as TS).
- **Phase 2 — in-frame (`input != NULL`).** The action rides the input packet's trailing
  section, tick-aligned and batched, accept-implicit. This **requires a native input /
  reconciler system that does not exist in the C core yet** (no `colyseus_input_t`, no
  reconciliation — confirmed absent). It only becomes designable once the input handle is
  ported. Until then `opts.input` is reserved; passing it is a no-op-falls-back-to-standalone,
  exactly the graceful-degradation path brief 18 already specifies for a server without the
  in-frame capability flag.

So the native field exists from day one (forward-compatible), but in-frame is explicitly a
later epic. Don't block standalone on it.

---

## 8. Lifecycle (identical to brief 18, language-independent)

```
colyseus_action_fire(payload, ctx) ─► PENDING  (handle stored in core registry, TTL armed)
                                          │
   ┌───────────────────────────────────────┼─────────────────────────────────────┐
   ▼                                       ▼                                      ▼
REJECTED(id) / ERROR(id)                 ACCEPT (OK)                           TTL expiry
   │                                     • disarm TTL                          (verdict lost)
 rollback(handle, reason)                • release / keep awaiting onAdd          │
   else spawn_handle.cancel()              (spawn store)                       rollback(handle, NULL)
 drop mapping (IMMEDIATE)                                                       drop mapping
```

- All transitions **idempotent** — a late/duplicate verdict for a gone id is a no-op
  (matters under the unreliable transport, where UDP can duplicate).
- **Reconnection:** drop every pending action→verdict mapping on disconnect (the core's
  reconnection path already resets buffered state — hook the registry into it). Verdicts
  for the dead connection won't arrive.

---

## 9. Memory & gotchas (the native-specific footnotes)

- **Payload ownership (C):** `colyseus_action_fire` does **not** take the `colyseus_message_t*`
  — caller frees it after the call, mirroring `colyseus_room_send` (verified: send encodes
  but never frees its payload). GML/GC handles this invisibly.
- **`handle` ownership:** always the user's. The core stores the pointer and passes it back
  to `rollback`/`on_accept`; it never frees it. (GML: GC; C: you free it inside `rollback`,
  or on `on_accept`/remove.)
- **`reason` lifetime (C):** the `colyseus_message_reader_t*` and any string it yields are
  valid only for the duration of the `rollback` callback (same rule as `on_message`
  readers). Copy out anything you keep.
- **`ctx` lifetime (C):** borrowed for the synchronous `predict` call only — a stack
  pointer is fine; do not retain it.
- **id wrap-around:** `uint32_t`, monotonic; tag-echo correlation is equality-based so wrap
  is moot in practice (same call as brief 18).
- **Thread model:** in the **raw C core**, `rollback`/`on_accept` fire on the **transport
  worker thread** — same as `on_message` today (the core has no main-thread pump). Keep them
  minimal: flip a flag and let your frame loop reap it (Appendix A does exactly this).
  **Engine bindings** (GameMaker `colyseus_process()`, Godot's poller, Flutter's event loop)
  already marshal core callbacks onto the main thread, so GML/GDScript/Dart `rollback` can
  mutate the scene directly (Appendix B). `predict` always runs on the **caller's** thread,
  synchronously inside `_fire`.

---

## 10. Graceful degradation (free — it's wire-level)

An old server already routes `ROOM_REQUEST("fire")` to its `messages.fire` handler and
always replies. So a standalone native action against a server that predates brief 18
degrades to "optimistic prediction, always confirmed via `OK`, no fast `REJECTED` rollback"
— strictly better than TTL-only, with **no handshake bit** and no unknown-opcode hazard.
Identical guarantee to the TS client, because degradation lives in the protocol, not the
language.

---

## 11. Phased rollout

1. **Core request/response (§2)** — `ROOM_REQUEST/RESPONSE` opcodes, id counter, pending
   registry, `colyseus_response_status_t`, `REJECTED`. Ship `colyseus_room_request` as the
   first consumer (closes the native gap vs `room.request`).
2. **Standalone `colyseus_action` (§3)** — predict + explicit rollback + TTL + tag-echo id,
   on top of (1). The portable MVP.
3. **GameMaker binding (§4)** — `colyseus_action` / `colyseus_action_fire` sugar; struct
   payloads, closure callbacks, decoded `reason`. Godot/Flutter bindings follow the same
   shape.
4. **Predicted-spawns store (§6)** — makes `rollback` optional, adds handoff/correlation.
5. **In-frame transport (§7)** — only after a native input/reconciler system exists.

---

## 12. Open questions

- **`colyseus_room_request` shape.** Async by nature; the core has no promises. Likely a
  `(on_ok, on_error, userdata)` callback trio sharing the action registry — settle this
  when building §2, since `predict.action` is layered on it.
- **Spawn-store handoff without a shared object.** TS keeps `id` stable across the
  predicted→authoritative swap. The native store does the same, but the render layer must
  key sprites on `entry.id` and read `server ?? local` — document this as the one contract,
  same as TS.
- **GML `method` sugar** (`shoot({x,y})` vs `colyseus_action_fire(shoot,{x,y})`) — pick one
  default; don't ship both as "the way."
- **Effect-less actions need reliable delivery** to guarantee the confirming `OK` — surface
  that in docs (an emote on the unreliable channel can silently never-confirm).
```

---

## Appendix A — Full C example (raylib-style game loop)

A top-down shooter. The player moves with a plain `colyseus_send("move")`; clicking
**fires a predicted bullet** via `colyseus_action("fire")`. The server's `messages.fire`
handler rejects on cooldown / dead shooter — and the predicted bullet then vanishes on the
`REJECTED` reply, not after a 2×RTT TTL. Uses the existing native client/state APIs
(grounded in `platforms/raylib/src/main.c`) plus the proposed `<colyseus/action.h>`.

```c
/* shooter.c — predicted "fire" with server-driven rollback.
 * Server is the brief-18 ArenaRoom (messages.fire → ctx.reject("cooldown"|"dead")). */
#include <colyseus/client.h>
#include <colyseus/schema.h>
#include <colyseus/schema/callbacks.h>
#include <colyseus/messages.h>
#include <colyseus/action.h>          /* PROPOSED — see §3 */
#include "raylib.h"
#include "arena_state.h"              /* generated: ArenaState { players, bullets } */

#include <string.h>
#include <stdio.h>

#define MAX_BULLETS 256
#define BULLET_SPEED 9.0f

typedef struct {
    float    x, y, vx, vy;
    uint32_t predict_id;   /* tag-echo: == server bullet.predictId once correlated */
    bool     active;       /* slot in use            */
    bool     confirmed;    /* server accepted (OK)   */
    bool     rejected;     /* server said no — reap  */
} bullet_t;

static colyseus_client_t*    client;
static colyseus_room_t*      room;
static colyseus_callbacks_t* callbacks;
static colyseus_action_t*    fire_action;
static bullet_t              bullets[MAX_BULLETS];
static char                  my_session_id[64];
static bool                  joined;

/* ── prediction bookkeeping ─────────────────────────────────────────────── */

static bullet_t* alloc_bullet(void) {
    for (int i = 0; i < MAX_BULLETS; i++)
        if (!bullets[i].active) { bullets[i] = (bullet_t){0}; bullets[i].active = true; return &bullets[i]; }
    return NULL;
}

/* The per-fire context (borrowed, stack-allocated at the call site). */
typedef struct { float x, y, vx, vy; } fire_ctx_t;

/* predict(): runs SYNCHRONOUSLY inside colyseus_action_fire() on the GAME thread.
 * Spawn the optimistic bullet NOW and tag it with the minted id. */
static void* predict_fire(uint32_t id, void* ctx, void* userdata) {
    fire_ctx_t* f = (fire_ctx_t*)ctx;
    bullet_t* b = alloc_bullet();
    if (!b) return NULL;
    b->x = f->x; b->y = f->y; b->vx = f->vx; b->vy = f->vy;
    b->predict_id = id;
    return b;                          /* handle → rollback / on_accept */
}

/* rollback(): server REJECTED (cooldown/dead) or the verdict timed out.
 * Raw C → this fires on the TRANSPORT thread, so just flag it; the frame loop reaps. */
static void rollback_fire(void* handle, colyseus_message_reader_t* reason, void* userdata) {
    bullet_t* b = (bullet_t*)handle;
    if (!b) return;
    b->rejected = true;
    const char* why = reason ? colyseus_message_reader_get_str(reason, NULL) : "timeout";
    printf("[fire] rejected: %s\n", why);
}

/* on_accept(): server confirmed (OK). Disarms the TTL; the authoritative bullet
 * handoff (if any) lands later via on_bullet_add, matched by predict_id. */
static void accept_fire(void* handle, void* userdata) {
    bullet_t* b = (bullet_t*)handle;
    if (b) b->confirmed = true;
}

/* ── server-authoritative bullets (hand-rolled correlation; the predicted-spawns
 *    store of §6 would automate this) ───────────────────────────────────────── */

static void on_bullet_add(void* value, void* key, void* userdata) {
    bullet_t_schema* sb = (bullet_t_schema*)value;        /* server schema instance */
    /* If it's the confirmation of one of MY predictions, drop the local copy and
     * let the authoritative one render — same id, seamless handoff. */
    for (int i = 0; i < MAX_BULLETS; i++) {
        if (bullets[i].active && bullets[i].predict_id == sb->predictId) {
            bullets[i].active = false;                    /* server copy takes over */
            return;
        }
    }
    /* else: a remote player's bullet — spawn a render-only local for it. */
    bullet_t* b = alloc_bullet();
    if (b) { b->x = sb->x; b->y = sb->y; b->vx = sb->vx; b->vy = sb->vy; b->confirmed = true; }
}

/* ── connection / setup ─────────────────────────────────────────────────── */

static void on_join(void* ud) {
    joined = true;
    strncpy(my_session_id, colyseus_room_get_session_id(room), sizeof(my_session_id) - 1);
}

static void on_room_success(colyseus_room_t* r, void* ud) {
    room = r;
    colyseus_room_set_state_type(room, &arena_state_vtable);
    colyseus_room_on_join(room, on_join, NULL);

    /* Bind the predicted "fire" action to the server's messages.fire handler. */
    colyseus_action_options_t opts = {
        .predict   = predict_fire,
        .rollback  = rollback_fire,
        .on_accept = accept_fire,
        /* .unreliable = true,  // optional: ride the unreliable channel        */
        /* .input = NULL,       // standalone request/response (Phase 1)         */
    };
    fire_action = colyseus_action_create(room, "fire", &opts);

    /* Correlate authoritative bullets with our predictions. */
    arena_state_t* state = (arena_state_t*)colyseus_room_get_state(room);
    callbacks = colyseus_callbacks_create(room->serializer->decoder);
    colyseus_callbacks_on_add(callbacks, state, "bullets", on_bullet_add, NULL, true);
}

static void on_error(int code, const char* msg, void* ud) {
    printf("connect error %d: %s\n", code, msg);
}

/* ── input ──────────────────────────────────────────────────────────────── */

static void handle_input(player_t* me) {
    if (!joined || !me) return;

    /* movement → plain fire-and-forget send */
    float nx = me->x, ny = me->y;
    if (IsKeyDown(KEY_W)) ny -= 4; if (IsKeyDown(KEY_S)) ny += 4;
    if (IsKeyDown(KEY_A)) nx -= 4; if (IsKeyDown(KEY_D)) nx += 4;
    if (nx != me->x || ny != me->y) {
        colyseus_message_t* m = colyseus_message_map_create();
        colyseus_message_map_put(m, "x", nx);
        colyseus_message_map_put(m, "y", ny);
        colyseus_room_send(room, "move", m);
        colyseus_message_free(m);                         /* caller owns the payload */
    }

    /* click → predicted "fire" action */
    if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT)) {
        Vector2 mp = GetMousePosition();
        float dx = mp.x - me->x, dy = mp.y - me->y;
        float len = (float)sqrt(dx*dx + dy*dy); if (len < 0.001f) len = 1;
        fire_ctx_t ctx = { me->x, me->y, dx/len*BULLET_SPEED, dy/len*BULLET_SPEED };

        colyseus_message_t* p = colyseus_message_map_create();
        colyseus_message_map_put(p, "x",  ctx.x);  colyseus_message_map_put(p, "y",  ctx.y);
        colyseus_message_map_put(p, "vx", ctx.vx); colyseus_message_map_put(p, "vy", ctx.vy);
        uint32_t id = colyseus_action_fire(fire_action, p, &ctx);   /* predicts NOW + sends */
        colyseus_message_free(p);                                   /* caller owns the payload */
        (void)id;                                                   /* == predict_id, if needed */
    }
}

/* ── main ───────────────────────────────────────────────────────────────── */

int main(void) {
    colyseus_settings_t* settings = colyseus_settings_create();
    colyseus_settings_set_address(settings, "localhost");
    colyseus_settings_set_port(settings, "2567");
    client = colyseus_client_create(settings);
    colyseus_client_join_or_create(client, "arena", "{}", on_room_success, on_error, NULL);

    InitWindow(800, 600, "Colyseus — predicted fire");
    SetTargetFPS(60);

    while (!WindowShouldClose()) {
        player_t* me = joined
            ? (player_t*)colyseus_map_get(colyseus_room_get_state(room), "players", my_session_id)
            : NULL;
        handle_input(me);

        /* advance + reap predicted bullets (verdict flags were set on the net thread) */
        for (int i = 0; i < MAX_BULLETS; i++) {
            bullet_t* b = &bullets[i];
            if (!b->active) continue;
            if (b->rejected) { b->active = false; continue; } /* reap the rolled-back ghost */
            b->x += b->vx; b->y += b->vy;
            if (b->x < 0 || b->x > 800 || b->y < 0 || b->y > 600) b->active = false;
        }

        BeginDrawing();
        ClearBackground(BLACK);
        for (int i = 0; i < MAX_BULLETS; i++)
            if (bullets[i].active)
                DrawCircle((int)bullets[i].x, (int)bullets[i].y, 4,
                           bullets[i].confirmed ? YELLOW : Fade(YELLOW, 0.5f)); /* dim = unconfirmed */
        EndDrawing();
    }

    if (room) { colyseus_room_leave(room, true); colyseus_room_free(room); }
    colyseus_action_free(fire_action);
    colyseus_client_free(client);
    colyseus_settings_free(settings);
    return 0;
}
```

What to notice: the predicted bullet renders **dim** until `accept_fire` flips `confirmed`,
and a rejected shot is reaped the very next frame (no TTL wait). `predict`/`fire` run on the
game thread; `rollback`/`accept` run on the net thread and only flip a `bool` — the safe raw-C
pattern. Swapping in the §6 spawn store would delete `on_bullet_add` and the hand-rolled
`predict_id` matching entirely.

---

## Appendix B — Full GameMaker (GML) example

The same shooter. Three object events on a `Networking` controller, plus a tiny `obj_bullet`.
GML's closures + live structs land it almost exactly on the TS shape, and because the binding
marshals callbacks through `colyseus_process()`, `rollback` runs on the game thread and can
`instance_destroy` directly — no flag-and-reap dance.

```gml
/// Networking — Create event
client        = colyseus_client_create("http://localhost:2567");
colyseus_room = colyseus_client_join_or_create(client, "arena", "{}");
my_session_id = "";
fire_action   = -1;
callbacks     = -1;

colyseus_on_join(colyseus_room, function(_room) {
    my_session_id = colyseus_room_get_session_id(_room);

    // Predicted "fire" — same handler the server's messages.fire reads.
    fire_action = colyseus_action(_room, "fire", {
        predict: function(payload, id) {
            // optimistic local bullet, tagged for correlation. Renders instantly.
            var b = instance_create_layer(payload.x, payload.y, "Bullets", obj_bullet);
            b.vx = payload.vx;
            b.vy = payload.vy;
            b.predict_id = id;
            b.confirmed  = false;
            return b;                              // handle → rollback / on_accept
        },
        rollback: function(handle, reason) {
            // server said no (reason == "cooldown" / "dead") — vanish NOW
            if (instance_exists(handle)) instance_destroy(handle);
            show_debug_message("shot rejected: " + string(reason));
        },
        on_accept: function(handle) {
            if (instance_exists(handle)) handle.confirmed = true;  // disarms the TTL
        }
        // unreliable: true        // optional — standalone unreliable send
    });

    // Correlate authoritative bullets with our predictions (the predicted-spawns
    // store would automate this; shown by hand for Phase 1).
    callbacks = colyseus_callbacks_create(_room);
    colyseus_on_add(callbacks, 0, "bullets", function(server_bullet, key) {
        // is this the confirmation of one of MY predictions? drop the local twin.
        with (obj_bullet) {
            if (predict_id == server_bullet.predictId) { instance_destroy(); break; }
        }
        // (a remote player's bullet would be spawned here instead)
    });
});

colyseus_on_error(colyseus_room, function(code, msg) {
    show_debug_message("error [" + string(code) + "]: " + msg);
});
```

```gml
/// Networking — Step event
colyseus_process();                                 // pumps callbacks + verdicts onto this thread

if (colyseus_room == -1 || !colyseus_room_is_connected(colyseus_room)) exit;

// movement → plain fire-and-forget send
var _dx = keyboard_check(vk_right) - keyboard_check(vk_left);
var _dy = keyboard_check(vk_down)  - keyboard_check(vk_up);
if (_dx != 0 || _dy != 0) {
    x += _dx * 4; y += _dy * 4;
    colyseus_send(colyseus_room, "move", { x: x, y: y });
}

// click → predicted "fire" action
if (mouse_check_button_pressed(mb_left)) {
    var _dir = point_direction(x, y, mouse_x, mouse_y);
    colyseus_action_fire(fire_action, {
        x:  x,
        y:  y,
        vx: lengthdir_x(9, _dir),
        vy: lengthdir_y(9, _dir),
    });                                             // predicts NOW, sends, awaits verdict
}
```

```gml
/// Networking — Clean Up event
if (colyseus_room != -1) colyseus_room_leave(colyseus_room);
// fire_action + callbacks are torn down with the room.
```

```gml
/// obj_bullet — Create event
vx = 0; vy = 0; predict_id = 0; confirmed = false;

/// obj_bullet — Step event
x += vx; y += vy;
if (x < 0 || x > room_width || y < 0 || y > room_height) instance_destroy();

/// obj_bullet — Draw event
draw_set_alpha(confirmed ? 1.0 : 0.5);              // dim until the server confirms
draw_circle(x, y, 4, false);
draw_set_alpha(1.0);
```

The GML and C listings are the *same program* — same five nouns (`action` / `fire` /
`predict` / `rollback` / `reason` / `id`), same lifecycle — differing only where the
language genuinely differs: GML captures in closures and mutates instances inline; C threads
a borrowed `ctx` and flags-then-reaps across the net thread.

---

## 13. Tying into `room.input()` — the continuous lane (and the dangling `opts.input`)

§3's `colyseus_action_options.input` was a **forward reference**: there is no native
`room.input()` to point it at yet. This section designs that handle and shows exactly how an
action *rides* it. The relationship is the spine of the whole prediction stack, so it's worth
stating plainly:

> **Two lanes, one channel.** Continuous per-tick intent (movement, `vx`/`vy`) flows through
> a **reconciled input handle** that the server replays. Discrete one-shot intent (fire, cast)
> is a **`colyseus_action`**. An action either goes **standalone** (its own request) or
> **rides the input handle's packet** — and when it rides, the input handle's *ack* is what
> accepts it. The input handle is the shared spine: the reconciler reads acks off it, the
> in-frame action ships on it and is confirmed by it.

This is the native mirror of brief 18's "`input` present ⇒ ride the input frame; absent ⇒
standalone," and of why the TS SDK puts the same handle on both `predict.reconciler({ input })`
and `predict.action({ input })`.

### 13.1 The native input handle (`room.input()` equivalent)

Faithful to `packages/sdk/src/input/InputHandle.ts`: a delta-encoded input schema instance you
mutate then `send()`, plus the reconciliation reads (`last_processed`, `at`, `reckon_time_at`)
and the handshake-advertised fixed-timestep facts (the one source of truth for `dt`).

```c
/* ── include/colyseus/input.h (PROPOSED) ─────────────────────────────────── */
typedef struct colyseus_input colyseus_input_t;
typedef enum { COLYSEUS_INPUT_RELIABLE = 0, COLYSEUS_INPUT_UNRELIABLE = 1 } colyseus_input_mode_t;

typedef struct {
    const colyseus_schema_vtable_t* type;     /* generated input schema (codegen, like state) */
    colyseus_input_mode_t           mode;     /* default RELIABLE                              */
    uint32_t                        history_size;  /* unreliable redundancy (default 4)        */
    float                           render_delay;  /* interp buffer ms — usually 0; a reconciler binds it */
} colyseus_input_options_t;

colyseus_input_t* colyseus_room_input(colyseus_room_t* room, const colyseus_input_options_t* opts);

void*    colyseus_input_data(colyseus_input_t* in);   /* the staged input struct — set fields, then send */
void     colyseus_input_send(colyseus_input_t* in);   /* encode delta + transmit + record replay snapshot */

/* Reconciliation reads. */
uint32_t    colyseus_input_last_processed(colyseus_input_t* in);   /* server-acked seq (rollback ack)   */
uint32_t    colyseus_input_sent_count(colyseus_input_t* in);
uint32_t    colyseus_input_pending_count(colyseus_input_t* in);    /* sent − acked = in-flight to replay */
const void* colyseus_input_at(colyseus_input_t* in, uint32_t seq); /* buffered snapshot for replay, or NULL */
double      colyseus_input_reckon_time_at(colyseus_input_t* in, uint32_t seq);

/* Handshake-advertised fixed timestep — predict at EXACTLY this dt for determinism. */
double colyseus_input_step_seconds(colyseus_input_t* in);          /* 1/tickRate                         */
int    colyseus_input_sub_steps(colyseus_input_t* in);
double colyseus_input_sub_step_seconds(colyseus_input_t* in);      /* stepSeconds / subSteps             */
int    colyseus_input_patch_rate(colyseus_input_t* in);            /* reconcile cadence (ms)             */

void colyseus_input_reset(colyseus_input_t* in);   /* on reconnect / scene change */
void colyseus_input_free(colyseus_input_t* in);
```

The matching reconciler (the input handle's primary consumer — predicts your inputs, rewinds
to server truth + replays the unacked ones, smoothly correcting):

```c
typedef struct {
    double   dt, sub_dt;     /* SECONDS — bit-identical to the server's StepContext */
    int      sub_steps;
    uint32_t tick;
    bool     is_replay;      /* true while replaying unacked inputs after a rewind */
    double   reckon_time;    /* server-clock ms to hit-test remotes at (lag-comp)  */
} colyseus_step_ctx_t;

/* The SAME pure function the server runs — apply `input` to `state` over ctx->dt. */
typedef void (*colyseus_reconciler_step_fn)(const colyseus_step_ctx_t* ctx, void* state,
                                            const void* input, void* userdata);

typedef struct {
    colyseus_input_t*           input;        /* the channel that knows what's acked */
    colyseus_reconciler_step_fn step;
    const char* const*          fields;       /* numeric fields to reconcile + smooth */
    size_t                      field_count;
    float                       smoothing;    /* correction-smoothing spring k        */
    void*                       userdata;
} colyseus_reconciler_options_t;

colyseus_reconciler_t* colyseus_predict_reconciler(colyseus_room_t* room, void* instance,
                                                   const colyseus_reconciler_options_t* opts);
void   colyseus_reconciler_tick(colyseus_reconciler_t* r, double now_ms);   /* reconcile + decay */
double colyseus_reconciler_value(colyseus_reconciler_t* r, const char* field);  /* smoothed render pose */
void*  colyseus_reconciler_state(colyseus_reconciler_t* r);                      /* logic state          */
```

(GML: `colyseus_room_input(room, { type, mode })` → handle; `colyseus_input_data(handle)`
returns a persistent struct you mutate; `colyseus_predict_reconciler(room, inst, { input, fields,
step })` with a `function(ctx, state, input)` step. Same five reconciler reads.)

### 13.2 The tie-in — how an action rides the input frame

Passing `.input` to `colyseus_action_create` flips the action from standalone to **in-frame**.
The mechanism, made concrete (brief 18's "trailing section" + "InputHandle pending-actions
queue"):

| Step | Standalone (`.input == NULL`) | In-frame (`.input == handle`) |
|---|---|---|
| `colyseus_action_fire()` | `predict()` **then send** a `ROOM_REQUEST` now | `predict()` **then enqueue** onto the input handle's pending-actions queue (does **not** transmit) |
| transmission | immediate, off-tick | at the **next `colyseus_input_send()`** — appended as the packet's trailing section: `[input delta][actions: count, (id,type,len,payload)…]` |
| channel | own reliable/unreliable | inherits the input's mode + the **same reckon stamp** |
| server dispatch | on packet arrival, off-tick | **tick-aligned** — consumed at the tick the input is, so the spawn aligns with the movement state at that tick |
| accept | explicit `OK` | **implicit** — the input ack (`last_processed`) advancing past the seq with no reject = accepted |
| reject | `REJECTED(id)` | `REJECTED(id)` (same) |
| rollback on replay | n/a | **replay-safe for free** — the queue is NOT in the input replay ring (`colyseus_input_at`), so a reconciler rewind never re-fires the action |

So the only new plumbing the input handle needs is a **pending-actions queue + trailing-section
framing in `colyseus_input_send`**; the action layer pushes onto it, `send` flushes it. Batching
falls out: multiple `fire()`s between two `send()`s ride the same frame (the count covers them).

**Why ride the input at all?** For a shot that must align with the *exact* movement tick (lag-comp
"what you see is what you hit"), in-frame gives native tick-alignment with no reckon reconstruction,
batches with the movement packet, and is replay-excluded automatically. For everything else,
standalone is simpler and needs no input system. Same decision as brief 18 — standalone is the
default; reach for in-frame only for high-rate / hard-tick-aligned actions.

### 13.3 Worked example — reconciled movement + in-frame fire (GML)

```gml
/// Create — after join
move_input = colyseus_room_input(colyseus_room, { type: MoveInput, mode: "unreliable" });

// reconcile MY player against the server (continuous lane)
recon = colyseus_predict_reconciler(colyseus_room, my_player, {
    input:  move_input,
    fields: ["x", "y"],
    step:   function(ctx, state, input) {        // the SAME step the server runs
        state.x += input.vx * ctx.dt;
        state.y += input.vy * ctx.dt;
    },
});

// fire rides the SAME input frame (discrete lane, in-frame transport)
fire_action = colyseus_action(colyseus_room, "fire", {
    input:   move_input,                          // ← THE TIE-IN: rides move_input's packets
    predict: function(payload, id) {
        var b = instance_create_layer(payload.x, payload.y, "Bullets", obj_bullet);
        b.vx = payload.vx; b.vy = payload.vy; b.predict_id = id;
        return b;
    },
    rollback: function(handle, reason) {
        if (instance_exists(handle)) instance_destroy(handle);
    },
});

/// Step — one fixed tick
colyseus_process();

var d = colyseus_input_data(move_input);          // stage this tick's movement
d.vx = (keyboard_check(vk_right) - keyboard_check(vk_left)) * 200;
d.vy = (keyboard_check(vk_down)  - keyboard_check(vk_up))   * 200;

if (mouse_check_button_pressed(mb_left)) {
    var dir = point_direction(my_player.x, my_player.y, mouse_x, mouse_y);
    colyseus_action_fire(fire_action, {           // predicts NOW, ENQUEUES onto move_input
        x: my_player.x, y: my_player.y,
        vx: lengthdir_x(9, dir), vy: lengthdir_y(9, dir),
    });
}

colyseus_input_send(move_input);                  // ONE packet: movement delta + queued fire(s)
colyseus_reconciler_tick(recon, current_time);

// render at the smoothed, server-reconciled pose
draw_sprite(spr_player, 0,
    colyseus_reconciler_value(recon, "x"),
    colyseus_reconciler_value(recon, "y"));
```

The payoff line: **`colyseus_action_fire` no longer transmits** — it predicts and queues, and
`colyseus_input_send` ships movement + fire in one tick-aligned packet. The shot is consumed at
the exact tick its movement was.

### 13.4 Worked example — the same in C

```c
/* one fixed tick (call from your fixed-step accumulator) */
static void net_tick(void) {
    move_input_t* d = (move_input_t*)colyseus_input_data(move_input);
    d->vx = (held(KEY_D) - held(KEY_A)) * 200.0f;
    d->vy = (held(KEY_S) - held(KEY_W)) * 200.0f;

    if (mouse_pressed(MOUSE_LEFT)) {
        fire_ctx_t ctx = aim_from_cursor();
        colyseus_message_t* p = colyseus_message_map_create();
        colyseus_message_map_put(p, "x",  ctx.x);  colyseus_message_map_put(p, "y",  ctx.y);
        colyseus_message_map_put(p, "vx", ctx.vx); colyseus_message_map_put(p, "vy", ctx.vy);
        colyseus_action_fire(fire_action, p, &ctx);   /* predicts NOW, enqueues onto move_input */
        colyseus_message_free(p);
    }

    colyseus_input_send(move_input);                  /* movement delta + queued fire(s), one packet */
    colyseus_reconciler_tick(recon, now_ms());
}

/* setup (in on_room_success, after set_state_type): */
colyseus_input_options_t in_opts = { .type = &move_input_vtable, .mode = COLYSEUS_INPUT_UNRELIABLE };
move_input = colyseus_room_input(room, &in_opts);

colyseus_reconciler_options_t r_opts = {
    .input = move_input, .step = step_player,
    .fields = (const char*[]){ "x", "y" }, .field_count = 2, .smoothing = 20.0f,
};
recon = colyseus_predict_reconciler(room, my_player, &r_opts);

colyseus_action_options_t a_opts = {
    .predict = predict_fire, .rollback = rollback_fire,
    .input   = move_input,        /* ← in-frame: ride the reconciled movement packet */
};
fire_action = colyseus_action_create(room, "fire", &a_opts);
```

`step_player` is the shared step function (`void step_player(const colyseus_step_ctx_t* ctx,
void* state, const void* input, void* ud)`), bit-identical to the server's, integrating with
`ctx->dt` — the same determinism contract `InputHandle.stepSeconds` enforces in TS.

### 13.5 Honest dependency note

This whole section presupposes a native **input encoder + reconciler + input-schema codegen** —
none of which exists in the C core today (the SDK currently only *decodes* state and *encodes*
msgpack messages). That's a large subsystem and its own brief; the in-frame action transport is a
thin rider on top of it. So the rollout stays as §11 has it: **standalone `colyseus_action` ships
first** (needs only request/response), and `.input` / in-frame light up only once the input lane
is ported. Until then, passing `.input` falls back to standalone — the same graceful degradation
brief 18 specifies when the server lacks the in-frame capability flag.
