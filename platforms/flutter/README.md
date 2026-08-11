# Colyseus Flutter SDK

The Colyseus client for Flutter, as `dart:ffi` bindings over the native C SDK.

Supports macOS, iOS, Android, Linux and Windows. Not web — that target needs
the SDK's Emscripten build and a different transport.

## Layout

| | |
|---|---|
| `src/` | C glue: the room/event/message surface and the FFI helpers the generated bindings can't express. |
| `colyseus_flutter/` | The Dart package. |
| `build.zig`, `build.sh` | Build the native library and stage it into the plugin's platform folders. |

## Build

Needs [Zig](https://ziglang.org) 0.15.2.

```sh
./build.sh              # every platform, staged into colyseus_flutter/
zig build               # host only, into zig-out/
```

Add it to an app:

```yaml
dependencies:
  colyseus_flutter:
    path: ../path/to/native-sdk/platforms/flutter/colyseus_flutter
```

macOS and iOS apps need the outbound-network entitlement
(`com.apple.security.network.client`) in both `DebugProfile.entitlements` and
`Release.entitlements`. Without it every connection fails silently inside the
sandbox, and `flutter create` does not add it.

## Use

```dart
final client = ColyseusClient('ws://localhost:2567');
final room = await client.joinOrCreate('my_room');

room.onStateChange.listen((_) {
  final players = room.state!.getMap('players')!;
  for (final entry in players.entries) { ... }
});

room.onMessage('chat').listen((data) => print(data['text']));
room.send('move', {'x': 10, 'y': 20});
```

### Prediction

Waiting for the server to confirm your own movement costs a round trip. The
predict layer applies each input immediately and reconciles when the server
disagrees:

```dart
Colyseus.autoPoll = false;              // the app drives the frame

final predict = Predict.of(room);
final input = room.input()!;

// Other players: smoothed, since their inputs aren't yours to predict.
predict.attachAll('players',
    config: {'x': PredictMode.damped, 'y': PredictMode.damped},
    exceptKey: room.sessionId);

// Yours: predicted and reconciled.
final me = room.state!.getMap('players')![room.sessionId] as SchemaInstance;
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

See [CHANGELOG.md](CHANGELOG.md) for the full 0.18 surface, and
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
cd colyseus_flutter
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
cd colyseus_flutter && dart run ffigen --config ffigen.yaml
```

`ffigen.yaml` documents which functions may be declared leaf — the list is
narrower than it looks, because some functions that read like getters can call
back into Dart.
