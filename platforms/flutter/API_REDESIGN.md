# Flutter SDK — typed schema access and a callbacks object

> **Status: EXECUTED, 2026-08-12.** Both items landed before the first
> pub.dev publish, across all four repos (native-sdk, schema-5.0,
> prediction-tools, docs). Kept for the rationale; the work breakdown below
> is done.
>
> One deviation from the shape sketched below: the typed callback surface
> follows C#'s `Callbacks.Get(room)` strategy, not the TypeScript `$()`
> accessor (which is itself headed for deprecation). Registration takes the
> field to observe — `callbacks.onAdd(state.players, (key, player) ...)` —
> with `onAddByName` / `onRemoveByName` as the string-based variants. No
> callbacks extensions are generated.

Plan for two pieces of API feedback on the 0.18 Dart surface. Written to be
picked up from a fresh context; everything needed to execute is below.

> **Sequencing risk — read first.** Item 2 is a breaking change to
> `ColyseusRoom`, and item 1 changes what idiomatic usage looks like. The
> package is being prepared for its first pub.dev publish as `colyseus`
> 0.18.0. Landing both **before** that publish costs nothing; landing them
> after costs a deprecation cycle on a public package. Decide the publish
> timing before starting.

---

## The feedback

1. `instance.getMap('players')` / `getArray` / `getRef` is clumsy. Is it really
   a Dart limitation? Unity gets typed access through schema-codegen — Dart
   probably should too.
2. `room.listen()` / `room.onAdd()` / `room.onRemove()` should not hang off
   `Room`. The C# SDK is the reference.

Both are correct. Details and evidence below.

---

## 1. Typed state access

### It is not a Dart limitation

Dart is the only Colyseus client with **no codegen target at all**. That, not
the language, is where the untyped API comes from:

| SDK | Generator | What the user writes |
| --- | --- | --- |
| Unity / C# | `--csharp` | `state.players["id"].x` |
| Haxe | `--haxe` | typed fields |
| C | `--c` | `player->x` on a generated struct |
| Godot | `--gdscript` | `definition()` → native builds a vtable and decodes into the user's class |
| **Dart** | **none** | `(state.getMap('players')!['id'] as SchemaInstance)['x']` |

Generators live in `~/Projects/colyseus/schema-5.0/src/codegen/languages/`
(`@colyseus/schema` 5.0.11, which owns the `schema-codegen` bin). There is no
`dart.ts`. Registration is one record in `src/codegen/api.ts`:

```ts
export const generators: Record<string, any> = { csharp, cpp, haxe, ts, js, java, lua, c, gdscript, };
```

`cli.ts` builds its `--help` from that record, so adding `dart` there is all the
CLI needs.

### Recommended mechanism: typed façades over the existing handles

Generate Dart classes that wrap the `int` handle the binding already uses, and
expose typed getters. **No core changes, no new native callbacks, no risk to the
decode path.** The whole generated layer sits on the existing public Dart API in
`lib/src/schema.dart` (263 lines) and `lib/src/schema_view.dart` (124 lines).

```dart
// generated — schema.dart output
final class Player extends SchemaRef {
  Player(super.handle);
  double get x => view['x'];
  double get y => view['y'];
  bool get isBot => view.getBool('isBot');
  ArraySchema<Item> get items => arrayOf('items', Item.new);
}

final class MyRoomState extends SchemaRef {
  MyRoomState(super.handle);
  MapSchema<Player> get players => mapOf('players', Player.new);
  String get currentTurn => view.getString('currentTurn') ?? '';
  Player? get host => refOf('host', Player.new);
}
```

```dart
// usage
final state = room.stateAs(MyRoomState.new)!;
final me = state.players[room.sessionId];
print(me!.x);
```

`SchemaView` already caches each resolved field in `_fields` after the first
lookup, so a generated getter costs a map hit plus one leaf FFI call. Nothing
new is needed for scalars.

### Runtime pieces to hand-write (not generated)

In the package, alongside `SchemaInstance`:

- `abstract base class SchemaRef` — holds the handle, lazily owns a
  `SchemaView`, and provides `mapOf` / `arrayOf` / `refOf` helpers.
- `MapSchema<T extends SchemaRef>` and `ArraySchema<T>` — typed wrappers over
  `SchemaMap` / `SchemaArray` taking a `T Function(int handle)` factory.
- A handle-keyed instance cache owned by the room, invalidated on full resync
  and on `onReconnect`.

That cache is worth building deliberately. The current docs have to warn readers
never to hold a `SchemaInstance` across frames, because the decoder frees and
replaces instances on resync (`schema.dart:70-76`). Centralising the cache and
invalidating it in one place turns that footgun into an implementation detail.

### Fix `SchemaMap.operator[]` while in there

`SchemaMap.operator[]` (`lib/src/schema.dart:153`) snapshots the entire
collection and linear-scans it, allocating a Dart string per entry:

```dart
final count = _n.collectionSnapshot(_handle, 1);
for (var i = 0; i < count; i++) {
  if (_n.collectionEntryKey(i).toDartString() == key) return _snapshotEntry(i);
}
```

So `state.players[room.sessionId]` is O(n) with n allocations, every call — on
the path a game touches every frame. The O(1) route already exists end to end
and is simply unused:

- core: `colyseus_map_schema_get(map, key)` (`include/colyseus/schema/collections.h:127`)
- glue: `colyseus_flutter_collection_get` (`src/flutter_extras.c:383`)
- Dart binding: `collectionGet` (`lib/src/bindings/native_functions.dart:500`) — **zero call sites**

The in-code comment explains the snapshot: primitive children carry no type tag,
so unboxing needs the collection's declared type. But
`collection_primitive_type` is bound too, so the fast path works for primitive
and schema children alike. Fix this first — it is independently worth it and the
typed layer will lean on it hard.

### Rejected: the Godot mechanism (native instance factory)

Godot passes its generated classes into the decoder with
`room.set_state_type(TestRoomState)`. The core then builds a
`colyseus_dynamic_vtable_t` and **constructs the user's class per instance**
through `create_userdata_fn` / `set_field_fn`
(`include/colyseus/schema/dynamic_schema.h:179-190`), so `on_add` hands back a
real `Player`. Verified in
`platforms/godot/tests/test/test_gdscript_schema.gd` (`assert_true(_captured_player is Player)`).

Do not copy this for Dart. It puts a Dart callback on **every field of every
patch**, arriving from the decode thread — which in this binding means
`NativeCallable.listener` traffic per field, exactly the cost the design
avoids. It also widens the surface for the teardown and dangling-handle classes
of bug the CHANGELOG already tracks. Façades give the same ergonomics for none
of that.

### Open decision: plain classes vs `extension type`

`pubspec.yaml` requires `sdk: '>=3.3.0 <4.0.0'`, so Dart 3.3 extension types are
available and would make the wrappers genuinely zero-cost.

- **Plain `final class` + instance cache (recommended).** Supports schema
  inheritance (`Class.extends` is a real thing in the parser), works with `is` /
  `as`, and the cache removes the allocation concern.
- **`extension type Player(SchemaView _v)`.** No allocation at all, but erases
  at runtime: no `is Player`, and inheritance only via `implements`. Schema
  inheritance makes that awkward.

Recommend plain classes. Revisit if profiling shows the cache is not enough.

---

## 2. Callbacks as their own object

### Every other SDK separates them

| SDK | Entry point | Call |
| --- | --- | --- |
| TypeScript 0.18 | `getStateCallbacks(room)` | `$(room.state).players.onAdd((p, k) => {})` |
| C# | `Callbacks.Get(room)` → `StateCallbackStrategy<TState>` | `cb.OnAdd(s => s.players, (k, p) => {})` |
| Godot | `Colyseus.Callbacks.of(room)` | `callbacks.on_add("players", cb)` |
| GameMaker | `colyseus_callbacks_create(room)` | `colyseus_on_add(callbacks, "players", cb)` |
| **Dart** | — | `room.onAdd('players', cb)` |

C# reference: `colyseus-unity-sdk/Assets/Colyseus/Runtime/Colyseus/Serializer/Schema/Callbacks/Callbacks.cs`.
Worth reading before implementing — note it keeps **string-based overloads**
(lines 360-435) beside the typed expression ones, for untyped access. Dart
should do the same rather than making codegen mandatory.

### Shape

New `lib/src/callbacks.dart`, exported from `lib/colyseus.dart`:

```dart
StateCallbacks getStateCallbacks(ColyseusRoom room);

class StateCallbacks {
  // untyped, mirrors C#'s string overloads
  StreamSubscription listen(SchemaInstance instance, String field,
      void Function(dynamic value, dynamic previous) cb, {bool immediate = true});
  StreamSubscription onAdd(SchemaInstance instance, String field,
      void Function(dynamic value, String key) cb, {bool immediate = true});
  StreamSubscription onRemove(SchemaInstance instance, String field,
      void Function(dynamic value, String key) cb);
  StreamSubscription onChange(SchemaInstance instance, void Function() cb);

  SchemaCallbacksOf<T> call<T extends SchemaRef>(T instance);
  void dispose();
}
```

With codegen, one generated extension per schema class gives the TypeScript
`$()` idiom with full static typing — no proxies or expression trees needed,
because Dart resolves extension members statically:

```dart
// generated
extension MyRoomStateCallbacks on SchemaCallbacksOf<MyRoomState> {
  CollectionCallbacks<Player, String> get players => collection('players', Player.new);
  PropertyCallbacks<String> get currentTurn => property('currentTurn');
  RefCallbacks<Player> get host => ref('host', Player.new);
}
```

```dart
final $ = getStateCallbacks(room);
$(state).players.onAdd((Player player, String key) { ... });
$(player).hp.listen((double hp, double? prev) { ... });
```

### `onChange` is missing and should land here

The core exposes `colyseus_callbacks_on_change_instance`,
`on_change_collection`, and per-collection `map_on_*` / `array_on_*`
(`include/colyseus/schema/callbacks.h:182-273`). The Dart binding only binds
`listen`, `on_add` and `on_remove` (`native_functions.dart:349-359`). C# has
`OnChange`; Dart should too. Needs a new `FLUTTER_EXPORT` in
`src/flutter_extras.c`, a `lookupFunction` entry, and a controller in the same
pattern as the existing three.

### What moves

Remove `listen` / `onAdd` / `onRemove` from `ColyseusRoom`
(`lib/src/room.dart:388-435`), along with `_callbacks`, `_subscribe` and the
three controller maps (`room.dart:55-59`, `336-386`). The room keeps the
`handlePropertyChange` / `handleItemAdd` / `handleItemRemove` entry points the
native side calls — they route into `StateCallbacks` instead.

Keep `instanceHandle`-style scoping, but take the instance itself rather than a
raw handle: `callbacks.listen(player, 'hp', cb)` reads better than
`room.listen('hp', cb, instanceHandle: player.handle)`.

---

## Work breakdown

Four repos. Roughly in dependency order.

### A. `~/Projects/colyseus/schema-5.0`
1. `src/codegen/languages/dart.ts` — model on `csharp.ts` for structure and on
   `c.ts` for how a native-backed target handles child types. Emit one class per
   schema, plus `renderBundle` support (`--bundle`), matching the other
   generators.
2. Register `dart` in the `generators` record in `src/codegen/api.ts`. `--help`
   picks it up automatically.
3. Tests alongside the existing codegen tests in `test/codegen`.

### B. `~/Projects/colyseus/native-sdk/platforms/flutter`
4. Fix `SchemaMap.operator[]` to use the already-bound `collectionGet`.
5. Runtime types: `SchemaRef`, `MapSchema<T>`, `ArraySchema<T>`, instance cache
   with resync/reconnect invalidation.
6. Bind `on_change_instance`: C export, `native_functions.dart`, controller.
7. `lib/src/callbacks.dart` + `getStateCallbacks`, exported from
   `lib/colyseus.dart`.
8. Strip the callback surface off `ColyseusRoom`.
9. Update `README.md`, `CHANGELOG.md`, and the tests under
   `colyseus/test/integration/` (`schema_callbacks_test.dart` covers replay on
   registration and cancel-unregisters — both behaviours must survive).

### C. `~/Projects/colyseus/demos/prediction-tools/clients/flutter-app`
10. Port the 12 labs. `lib/labs/move_lane.dart` and `lib/net/schema_bridge.dart`
    are the ones that touch schema access hardest, and are the honest test of
    whether the typed layer is actually nicer.

### D. `~/Projects/colyseus/docs`
11. `pages/getting-started/flutter.mdx` — the **Reading State** and **State
    Callbacks** sections are written against today's API and both change. Also
    drop the line stating the SDK has no schema codegen, and add the
    `npx schema-codegen … --dart` block the Godot and Haxe pages carry.
12. `pages/state/callbacks.mdx` — the `schema-codegen --help` output listed
    around line 652 gains `--dart`.

---

## Decisions to make before starting

1. **Publish timing.** Hold the pub.dev publish until this lands, or publish
   0.18.0 now and take the break in 0.19.0?
2. **Callbacks call shape.** The `$(state).players.onAdd(...)` extension idiom
   above (matches TypeScript), or the flatter C# style
   `callbacks.onAdd(state.players, cb)`? The first reads better; the second
   generates less code.
3. **Is codegen required or optional?** Recommendation: optional, exactly as it
   is for Godot and Haxe. The untyped API keeps working, and the docs lead with
   codegen.
4. **Plain classes or extension types** for the generated wrappers (see above;
   recommendation is plain classes).

---

## Verification

- `cd schema-5.0 && npm test` for the generator; check the emitted Dart against
  `example-server/src/rooms/TestRoom.ts`, which is the schema the Godot and
  Flutter integration tests already use (map + schema child, array + schema
  child, ref + schema child, string/number/boolean primitives).
- Flutter suite, both servers up, per `platforms/flutter/README.md`:
  ```sh
  cd example-server && npm start                                  # :2567
  cd demos/prediction-tools && pnpm dev --host 0.0.0.0            # :5173
  cd platforms/flutter/colyseus
  COLYSEUS_LIBRARY_PATH="$PWD/../zig-out/lib/macos/arm64/libcolyseus_flutter.dylib" \
    flutter test test/ --concurrency=1
  ```
  `--concurrency=1` is required; `netdelay_test.dart` has a known ~1-in-3
  process-level abort from the core teardown race, so re-run before believing a
  crash.
- Run the playground app on macOS and step through the labs — the prediction
  path reads schema state every frame and is where a slow or allocating typed
  layer will show.
- `cd docs && npm run check-links && npm run lint:prose && npm run build`.
