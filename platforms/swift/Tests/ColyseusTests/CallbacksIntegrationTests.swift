import Foundation
import XCTest
@testable import Colyseus

/// Against the real example server: what the decoder changed, reported.
final class CallbacksIntegrationTests: XCTestCase {
    private var client: Colyseus.Client!

    override func setUpWithError() throws {
        try Server.requireExample()
        Colyseus.autoPump = false
        client = try Colyseus.Client(endpoint: Server.example)
    }

    override func tearDown() {
        client = nil
        Colyseus.autoPump = true
    }

    private func joinPrivateRoom() async throws -> Colyseus.Room<TestRoomState> {
        try await client.create("test_room", options: ["private": true], state: TestRoomState.self)
    }

    func testOnAddFiresForExistingAndNewEntries() async throws {
        let room = try await joinPrivateRoom()
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let added = Recorder()
        let callbacks = Colyseus.Callbacks.get(room)
        let state = try XCTUnwrap(room.state)
        callbacks.onAdd(state.players) { key, _ in added.record(key) }

        // immediate: the player already in the map counts.
        XCTAssertEqual(added.values, [sessionId])

        room.send("add_bot")
        waitPumping("the bot") { added.values.count == 2 }
        XCTAssertEqual(added.values.first, sessionId)
    }

    func testOnRemoveFiresWhenAnEntryGoes() async throws {
        let room = try await joinPrivateRoom()
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let callbacks = Colyseus.Callbacks.get(room)
        let state = try XCTUnwrap(room.state)

        let added = Recorder()
        callbacks.onAdd(state.players) { key, _ in added.record(key) }
        let removed = Recorder()
        callbacks.onRemove(state.players) { key, _ in removed.record(key) }

        room.send("add_bot")
        waitPumping("the bot") { added.values.count == 2 }
        let botId = try XCTUnwrap(added.values.last)

        room.send("remove_bot", ["name": .string(botId)])
        waitPumping("the bot to go") { removed.values.isEmpty == false }
        XCTAssertEqual(removed.values, [botId])
    }

    func testListenOnAStringField() async throws {
        let room = try await joinPrivateRoom()
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let seen = Recorder()
        let callbacks = Colyseus.Callbacks.get(room)
        let state = try XCTUnwrap(room.state)
        callbacks.listen(state, "currentTurn", as: String.self) { value, _ in
            seen.record(value ?? "<nil>")
        }

        // The first client to join becomes the current turn, so `immediate`
        // has something to report.
        XCTAssertEqual(seen.values, [sessionId])
    }

    func testListenOnANumericField() async throws {
        let room = try await joinPrivateRoom()
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let player = try XCTUnwrap(room.state?.players[sessionId])
        let seen = Numbers()
        let callbacks = Colyseus.Callbacks.get(room)
        callbacks.listen(player, "x", as: Double.self, immediate: false) { value, _ in
            seen.record(value ?? .nan)
        }

        room.send("move", ["x": 55.5, "y": 1.0])
        waitPumping("the move") { seen.values.contains(55.5) }
    }

    func testOnChangeFiresForTheInstance() async throws {
        let room = try await joinPrivateRoom()
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let player = try XCTUnwrap(room.state?.players[sessionId])
        let changes = Counter()
        Colyseus.Callbacks.get(room).onChange(player) { changes.increment() }

        room.send("move", ["x": 3.0, "y": 4.0])
        waitPumping("a change") { changes.value > 0 }
    }

    func testCancellingStopsTheHandler() async throws {
        let room = try await joinPrivateRoom()
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let player = try XCTUnwrap(room.state?.players[sessionId])
        let changes = Counter()
        let subscription = Colyseus.Callbacks.get(room).onChange(player) { changes.increment() }

        room.send("move", ["x": 1.0, "y": 1.0])
        waitPumping("a change") { changes.value > 0 }

        subscription.cancel()
        let before = changes.value
        room.send("move", ["x": 2.0, "y": 2.0])
        pump(for: 0.6)
        XCTAssertEqual(changes.value, before)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
    }
}

final class Numbers: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
    }
}
