# Colyseus Flutter SDK

The Colyseus client for Flutter, as `dart:ffi` bindings over the native C SDK.

Supports macOS, iOS, Android, Linux and Windows. Not web — that target needs
the SDK's Emscripten build and a different transport.

## Layout

| | |
|---|---|
| `src/` | C glue: the room/event/message surface and the FFI helpers the generated bindings can't express. |
| `colyseus/` | The Dart package, published to pub.dev as [`colyseus`](https://pub.dev/packages/colyseus). |
| `build.zig`, `build.sh` | Build the native library and stage it into the plugin's platform folders. |
| `make-xcframework.sh` | Fuse the iOS slices into the xcframework the podspec vendors. |
| `stage-package.sh` | Assemble the publishable package for CI. |

## Build

Needs [Zig](https://ziglang.org) 0.15.2.

```sh
./build.sh              # every platform, staged into colyseus/
zig build               # host only, into zig-out/
```

`build.sh` runs one `zig build` per target rather than a single `-Dall` pass,
because the `native_sdk` dependency resolves once against the host and its
cross-target outputs do not link.

iOS is the awkward one. Device and simulator are both arm64 and no single
archive can hold two slices of one architecture, so the three iOS targets are
fused into `colyseus_flutter.xcframework`. The static library also has to carry
the core: `linkLibrary` only records a link-time dependency, which means
nothing for an archive, so `build.zig` merges the core and glue archives with
`libtool` for iOS. Without that the shipped `.a` holds three glue objects and
Dart's runtime symbol lookups fail for everything in 0.18.

Apps normally take the published package, which bundles the prebuilt
libraries: `flutter pub add colyseus`. To run against a local build instead:

```yaml
dependencies:
  colyseus:
    path: ../path/to/native-sdk/platforms/flutter/colyseus
```

macOS and iOS apps need the outbound-network entitlement
(`com.apple.security.network.client`) in both `DebugProfile.entitlements` and
`Release.entitlements`. Without it every connection fails silently inside the
sandbox, and `flutter create` does not add it.

## Use

```dart
final client = ColyseusClient('ws://localhost:2567');
final room = await client.joinOrCreate('my_room');

room.onMessage('chat').listen((data) => print(data['text']));
room.send('move', {'x': 10, 'y': 20});
```

### Reading state

`npx schema-codegen src/rooms/MyRoom.ts --dart --output lib/gen/` generates
one Dart class per schema; joining with `stateType:` types the room with it,
C#'s `JoinOrCreate<MyRoomState>`. Without codegen, the dynamic accessors do
the same job:

```dart
// generated classes
final room = await client.joinOrCreate('my_room', stateType: MyRoomState.new);
print(room.state!.players[room.sessionId]!.x);

// dynamic
final players = room.state!.getMap('players')!;
print((players[room.sessionId] as SchemaInstance)['x']);
```

### State callbacks

C#-style: registration takes the typed field to observe, and collection
handlers receive `(key, value)`.

```dart
final callbacks = Callbacks.get(room);
callbacks.onAdd(state.players, (sessionId, player) { ... });         // typed
callbacks.onAddByName(room.state!, 'players', (key, value) { ... }); // by name
```

### Prediction

Waiting for the server to confirm your own movement costs a round trip. The
predict layer applies each input immediately and reconciles when the server
disagrees:

```dart
Colyseus.autoPoll = false;              // the app drives the frame

final predict = Predict.get(room);
final input = room.input()!;

// Other players: smoothed, since their inputs aren't yours to predict.
predict.attachAll('players',
    config: {'x': PredictMode.damped, 'y': PredictMode.damped},
    exceptKey: room.sessionId);

// Yours: predicted and reconciled.
final me = room.state!.players[room.sessionId]!;
final recon = predict.reconciler(me,
  input: input,
  fields: const ['x', 'y', 'vx', 'vy'],
  step: (ctx, state, cmd) => stepPlayer(state, cmd, ctx.dt),  // shared with the server
);

void onFrame() {
  Colyseus.pump();                      // decode inbound, deliver events
  final steps = predict.tick(clock.now);
  for (var i = 0; i < steps; i++) {
    input.data['moveX'] = keyboard.x;
    input.send();                       // predicted immediately
  }
  draw(recon.value('x'), recon.value('y'));
}
```

`step` has to compute exactly what the server computes. When it does,
`recon.drift.ema` stays at the floating-point noise floor; when it drifts, that
number tells you.

### HTTP and auth

`colyseus_http_*` and `colyseus_auth_*` in the core BLOCK — each runs its
request inline and calls back before returning. The binding queues them onto a
worker thread (`src/flutter_http.c`) and answers through a
`NativeCallable.listener`, so neither call stalls the frame loop.

```dart
final res = await client.http.get('/test');
print(res.json['things']);
await client.http.post('/save', body: {'name': 'endel'});

final data = await client.auth.signInAnonymously();
print(data.user?['anonymousId']);

// The token is shared with client.http, so later requests are authenticated.
client.auth.onChange.listen((d) {
  if (d.token == null) showLoginScreen();
});
```

A non-2xx reply throws `ColyseusHttpException`; a rejected auth call throws
`ColyseusAuthException`.

The token is persisted through the platform's secure storage under one
process-wide key, so it survives a restart AND leaks between test runs — a
suite that signs in should sign out again, or later clients will send a token
the next server rejects.

See [CHANGELOG.md](colyseus/CHANGELOG.md) for the full 0.18 surface, and
[`demos/prediction-tools/clients/flutter-app`](../../../demos/prediction-tools/clients/flutter-app)
for a worked example.

## Tests

Two servers, both required:

```sh
cd ../../example-server && npm start                    # :2567
cd ../../../demos/prediction-tools && pnpm dev --host 0.0.0.0   # :5173
```

`--host` is not optional for the playground: without it Vite binds IPv6
loopback only and native clients cannot reach it. The example server declares
no `defineInput()`, so every prediction test needs the playground.

```sh
cd colyseus
COLYSEUS_LIBRARY_PATH="$PWD/../zig-out/lib/macos/arm64/libcolyseus_flutter.dylib" \
  flutter test test/ --concurrency=1
```

`--concurrency=1` is required: parallel test files put enough load on the
shared server to hit a pre-existing teardown race in the core.

That race is also why `netdelay_test.dart` occasionally dies mid-file with a
process-level crash rather than a failed assertion (roughly one run in three).
It is the same open core issue the Zig suite hits — `zig build test` reports
157/157 assertions passing while two test processes still abort on exit. Re-run
the file; if assertions fail, that is a real failure.

## Regenerating bindings

The 0.18 surface is generated from the core headers. After changing them:

```sh
cd colyseus && dart run ffigen --config ffigen.yaml
```

`ffigen.yaml` documents which functions may be declared leaf — the list is
narrower than it looks, because some functions that read like getters can call
back into Dart.

## Releasing

`.github/workflows/flutter.yml` builds every platform's library and publishes
the package with them bundled, so consumers install `colyseus` without a
toolchain. To cut a release, set `version:` in `colyseus/pubspec.yaml`, add the
matching `CHANGELOG.md` section, and push a tag:

```sh
git tag flutter-v0.18.0 && git push origin flutter-v0.18.0
```

The workflow refuses to publish if the tag and the pubspec disagree, or if any
platform's library is missing from the build artifacts. Running it from the
Actions tab with `publish` off builds and validates without publishing.

The publish step never reads the working tree: `stage-package.sh` assembles the
tagged commit plus the freshly built libraries into a directory outside the
repo. That is not a stylistic choice. pub drops any file matching a
`.gitignore`, even a checked-in one, so libraries cannot be published from
inside the repo without un-ignoring every binary.

The `colyseus.io` verified publisher already exists. Getting the package under
it, and onto the tag-driven flow above, is a one-time sequence that CI cannot
do for you, in this order:

1. Publish the first version by hand: `cd colyseus && flutter pub publish`.
   Automated publishing only works for packages that already exist, and pub
   cannot publish a new package straight to a publisher, so this first version
   lands under the uploader's personal account either way.
2. Transfer it at `pub.dev/packages/colyseus/admin`. This is irreversible: a
   package cannot move back from a publisher to an individual account.
3. On the same admin page, enable automated publishing from GitHub Actions for
   `colyseus/native-sdk` with the tag pattern `flutter-v{{version}}`.

From then on, pushing a `flutter-v*` tag is the whole release. Adding the other
maintainers to the publisher is worth doing at step 2, since publisher members
all inherit upload rights and a single personal account otherwise becomes the
only way to ship.
