# Colyseus Swift SDK

Swift over the native C SDK, as a Swift package. macOS, iOS and tvOS.

```swift
let client = try Colyseus.Client(endpoint: "ws://localhost:2567")
let room = try await client.joinOrCreate("my_room", state: MyRoomState.self)

let callbacks = Colyseus.Callbacks.get(room)
callbacks.onAdd(room.state!.players) { sessionId, player in
    spawn(sessionId, at: player.x, player.y)
}

room.onMessage("score") { payload in
    hud.score = payload.string ?? ""
}
```

## Installing it

```swift
.package(url: "https://github.com/colyseus/colyseus-swift", from: "0.18.1")
```

[colyseus/colyseus-swift](https://github.com/colyseus/colyseus-swift) is this
directory, generated on every release by [`mirror.sh`](./mirror.sh). SwiftPM
resolves a package from a repository ROOT and only understands plain semver
tags, so it can see neither a manifest under `platforms/` nor a `swift-v*`
tag — and a consumer of this repo would clone 300 MB of submodules the Swift
package never uses.

Work on the SDK happens here. A commit pushed to the mirror is overwritten by
the next release.

## Building it

The core is Zig as much as it is C — msgpack, HTTP and the certificate store
are Zig modules — so SwiftPM cannot compile it from source. It arrives as a
pre-built xcframework instead.

```sh
cd platforms/swift
./build.sh          # needs Zig 0.15.2 and the Xcode command-line tools
swift build
swift test          # start example-server first; see below
```

`build.sh` produces `build/Colyseus.xcframework` covering macOS (arm64 +
x86_64), iOS, the iOS simulator (arm64 + x86_64), tvOS and the tvOS simulator.

To use a published one instead of building it:

```sh
export COLYSEUS_XCFRAMEWORK_URL=https://github.com/colyseus/native-sdk/releases/download/vX.Y.Z/Colyseus.xcframework.zip
export COLYSEUS_XCFRAMEWORK_CHECKSUM=…
```

> SwiftPM takes a local package's identity from its directory name, so a
> package of your own in a folder called `swift` cannot depend on this one.
> Name yours after your app.

## The frame loop

Nothing in the SDK runs on a thread of its own. Matchmaking, socket reads and
decoding, injected latency and reconnection all advance inside
`Colyseus.pump()`, and every room callback — `onJoin`, `onStateChange`,
messages, schema callbacks, `onError`, `onDrop`, `onReconnect`, `onLeave` —
runs inside it, on the thread that called it. Nothing is delivered between
pumps, so state read on that thread holds still.

By default the SDK pumps itself at 60 Hz on `Colyseus.callbackQueue`, the main
queue. An app with a frame loop should own the pump:

```swift
Colyseus.autoPump = false           // once, at startup

override func update(_ currentTime: TimeInterval) {
    Colyseus.pump()                          // release, decode, deliver
    for _ in 0 ..< predict.tick(room.clock.now) {
        input.data.set("moveX", to: keyboard.x)
        input.send()                         // each one predicted immediately
    }
    draw()                                   // read poses AFTER the sends
}
```

The order is load-bearing. A pose read before the pump is a frame stale; one
taken between the tick and the sends jitters. Awaiting a join or an HTTP call
before the loop is running pumps for you, so `try await client.joinOrCreate(...)`
needs no loop to finish.

## What's here

| | |
|---|---|
| `Colyseus.Client` | matchmaking, `http`, `auth`, latency measurement |
| `Colyseus.Room<State>` | lifecycle, messages, `request`, reconnection, `setLatency` |
| `SchemaRef` / `SchemaView` | typed façades over decoded state — what `schema-codegen --swift` emits |
| `MapSchema` / `ArraySchema` | collections, read live from the decoder |
| `Colyseus.Callbacks` | `listen`, `onAdd`, `onRemove`, `onChange` |
| `Colyseus.RoomClock` | local, server and render time; rtt, jitter |
| `Colyseus.InputHandle` | the input channel a room's `defineInput()` declares |
| `Colyseus.Predict` | smoothing, dead reckoning, and the frame tick |
| `Colyseus.Reconciler` | rollback prediction, flat and composite |
| `Colyseus.EventChannel` | optimistic events, confirmed or retracted |
| `Colyseus.Spawns` | entities you create before the server does |

Typed state comes from the schema generator:

```sh
npx schema-codegen src/rooms/MyRoom.ts --swift --bundle --output Sources/MyApp/Gen
```

Decoding does not depend on it — the core builds its own picture from the
handshake's reflection — so a generated class is a typed way to read what was
decoded, and nothing has to be generated for input schemas at all.

## Tests

```sh
cd example-server && npm install && npm start     # :2567
cd platforms/swift && swift test
```

The prediction tests want a second server, the
[prediction playground](https://github.com/colyseus/prediction-playground) on
`:5173` (`pnpm dev --host 0.0.0.0`), because `example-server` declares no
`defineInput()`. They skip themselves with the command to start it rather than
failing.

## Demos

Two clients are built on this package, and are the best place to see it used:

- [air-hockey](https://github.com/colyseus/air-hockey-demo) — `clients/swift-app`
- [prediction playground](https://github.com/colyseus/prediction-playground) — `clients/swift-app`, all twelve labs

## Known gaps

- Unreliable input needs a datagram transport the core does not have yet.
- `SetSchema` and `CollectionSchema` do not exist in the core.
