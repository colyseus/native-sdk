import Colyseus
import Foundation

// A whole client in one file, against the repo's example-server:
//
//   cd example-server && npm install && npm start
//   cd platforms/swift/example && swift run
//
// It joins, reads state through generated-style typed classes, reacts to what
// the decoder changed, sends a message, and leaves.

/// What `schema-codegen --swift` emits for the example server's TestRoom.
///
///     npx schema-codegen src/rooms/TestRoom.ts --swift --bundle --output .
final class Player: SchemaRef, @unchecked Sendable {
    var x: Double { view["x"] }
    var y: Double { view["y"] }
    var isBot: Bool { view.bool("isBot") }
}

final class TestRoomState: SchemaRef, @unchecked Sendable {
    var players: MapSchema<Player> { mapOf("players") }
    var currentTurn: String { view.string("currentTurn") ?? "" }
}

let endpoint = CommandLine.arguments.dropFirst().first ?? "ws://127.0.0.1:2567"

// This example drives its own loop, so it pumps rather than leaving it to the
// SDK's timer. The join below pumps for itself until the loop starts.
Colyseus.autoPump = false

let client = try Colyseus.Client(endpoint: endpoint)
let room = try await client.joinOrCreate("my_room", state: TestRoomState.self)
print("joined \(room.name ?? "?") as \(room.sessionId ?? "?")")

let callbacks = Colyseus.Callbacks.get(room)
if let state = room.state {
    callbacks.onAdd(state.players) { sessionId, player in
        let who = sessionId == room.sessionId ? "you" : sessionId
        print("+ \(who) at (\(player.x), \(player.y))")
    }
    callbacks.onRemove(state.players) { sessionId, _ in
        print("- \(sessionId)")
    }
    callbacks.listen(state, "currentTurn", as: String.self) { turn, _ in
        print("turn: \(turn ?? "-")")
    }
}

room.onMessage("join_options") { payload in
    print("server said hello: \(payload)")
}

room.send("move", ["x": 42.0, "y": 7.5])

// Everything above is delivered inside a pump, on this thread.
let deadline = Date().addingTimeInterval(3)
while Date() < deadline {
    Colyseus.pump()
    try await Task.sleep(for: .milliseconds(16))
}

if let me = room.sessionId.flatMap({ room.state?.players[$0] }) {
    print("moved to (\(me.x), \(me.y))")
}

room.leave()
Colyseus.pump()
print("left")
