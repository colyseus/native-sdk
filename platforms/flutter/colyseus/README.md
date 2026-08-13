# Colyseus for Flutter

The [Colyseus](https://colyseus.io) multiplayer client, as `dart:ffi` bindings
over the native C SDK. Prebuilt native libraries ship with the package, so
there is no toolchain to install.

Supports macOS, iOS, Android, Linux and Windows. Web is not supported: that
target needs the SDK's Emscripten build and a different transport.

## Install

```sh
flutter pub add colyseus
```

macOS and iOS apps need the outbound-network entitlement
(`com.apple.security.network.client`) in both `DebugProfile.entitlements` and
`Release.entitlements`. Without it every connection fails silently inside the
sandbox, and `flutter create` does not add it.

## Use

```dart
import 'package:colyseus/colyseus.dart';

final client = ColyseusClient('ws://localhost:2567');
final room = await client.joinOrCreate('my_room');

room.onMessage('chat').listen((data) => print(data['text']));
room.send('move', {'x': 10, 'y': 20});
```

## Reading state

Generate Dart classes from the server's schema:

```sh
npx schema-codegen src/rooms/MyRoom.ts --dart --output lib/gen/
```

Join with the generated root class, the Dart spelling of C#'s
`JoinOrCreate<MyRoomState>("my_room")`, and the room is typed end to end:

```dart
final room = await client.joinOrCreate('my_room',
    stateType: MyRoomState.new);

final state = await room.onStateChange.first;   // MyRoomState, first patch
final me = state.players[room.sessionId]!;
print('${me.x}, ${me.y}');
```

`room.state` reads the same typed root on demand (null before the first
patch), and `onStateChange` fires with it after every patch. Reading every
frame is cheap: the room keeps the wrapper while the underlying instance
lives, and rebuilds it on reconnect, when the decoder replaces every
instance.

The same state also reads dynamically, with no generated classes:

```dart
final players = room.state!.getMap('players')!;
final me = players[room.sessionId] as SchemaInstance;
print(me['x']);
```

## State callbacks

Callbacks live on their own object and take the field to observe, following
the C# SDK's `Callbacks.Get(room)` strategy:

```dart
final callbacks = Callbacks.get(room);

// with generated classes — key and value are statically typed:
callbacks.onAdd(state.players, (sessionId, player) { ... });
callbacks.onRemove(state.players, (sessionId, player) { ... });
callbacks.listen(me, 'hp', (double hp, double? previous) { ... });
callbacks.listenRef(state, 'host', Player.new, (host) { ... });
callbacks.onChange(me, () { ... });

// by field name, with no generated classes:
callbacks.onAddByName(room.state!, 'players', (key, value) { ... });
callbacks.listen(room.state!, 'currentTurn', (value, previous) { ... });
```

Collection handlers receive `(key, value)`: a `String` key for maps, an `int`
index for arrays. Registration replays what already decoded, so `onAdd` fires
for existing items and `listen` for the current value (pass
`immediate: false` to skip). Cancelling the returned `StreamSubscription`
unregisters the native callback.

## Prediction

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

## HTTP and auth

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

Both run on a worker thread and answer through a `NativeCallable.listener`, so
neither call stalls the frame loop. A non-2xx reply throws
`ColyseusHttpException`; a rejected auth call throws `ColyseusAuthException`.

The token is persisted through the platform's secure storage under one
process-wide key, so it survives a restart and leaks between test runs. A suite
that signs in should sign out again, or later clients will send a token the
next server rejects.

## Links

- [Documentation](https://docs.colyseus.io)
- [Changelog](https://github.com/colyseus/native-sdk/blob/main/platforms/flutter/colyseus/CHANGELOG.md)
- [Issues](https://github.com/colyseus/native-sdk/issues)
- [Building from source](https://github.com/colyseus/native-sdk/tree/main/platforms/flutter)
