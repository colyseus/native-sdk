import Foundation
import XCTest
@testable import Colyseus

/// Against the real example server: join, decode, send, leave.
final class RoomIntegrationTests: XCTestCase {
    private var client: Colyseus.Client!

    override func setUpWithError() throws {
        try Server.requireExample()
        // The tests drive the pump themselves so every assertion sits at a
        // known point in the traffic.
        Colyseus.autoPump = false
        client = try Colyseus.Client(endpoint: Server.example)
    }

    override func tearDown() {
        client = nil
        Colyseus.autoPump = true
    }

    func testJoinDecodesOwnPlayer() async throws {
        let room = try await client.joinOrCreate("test_room", state: TestRoomState.self)
        defer { room.leave() }

        XCTAssertNotNil(room.id)
        XCTAssertNotNil(room.sessionId)
        XCTAssertEqual(room.name, "test_room")
        XCTAssertTrue(room.isConnected)

        waitPumping("own player to decode") {
            room.state?.players[room.sessionId ?? ""] != nil
        }

        let me = try XCTUnwrap(room.state?.players[room.sessionId ?? ""])
        XCTAssertFalse(me.x.isNaN)
        XCTAssertFalse(me.isBot)
    }

    func testOnStateChangeFires() async throws {
        let room = try await client.joinOrCreate("test_room", state: TestRoomState.self)
        defer { room.leave() }

        let changes = Counter()
        room.onStateChange { _ in changes.increment() }

        waitPumping("a patch") { changes.value > 0 }
        XCTAssertGreaterThan(changes.value, 0)
    }

    func testSendMovesThePlayer() async throws {
        let room = try await client.joinOrCreate("test_room", state: TestRoomState.self)
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player to decode") { room.state?.players[sessionId] != nil }

        room.send("move", ["x": 123.5, "y": -7.25])

        waitPumping("the move to come back") {
            room.state?.players[sessionId]?.x == 123.5
        }
        XCTAssertEqual(room.state?.players[sessionId]?.y, -7.25)
    }

    func testArraySchemaGrowsAndShrinks() async throws {
        let room = try await client.create("test_room", options: ["private": true], state: TestRoomState.self)
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player to decode") { room.state?.players[sessionId] != nil }

        // The room seeds every player with one item, so the counts here are
        // relative to whatever join left behind.
        let seeded = try XCTUnwrap(room.state?.players[sessionId]?.items.count)

        room.send("add_item", ["name": "shield"])
        waitPumping("the item to arrive") {
            room.state?.players[sessionId]?.items.count == seeded + 1
        }

        let items = try XCTUnwrap(room.state?.players[sessionId]?.items)
        XCTAssertEqual(items.count, items.values.count)
        XCTAssertTrue(items.values.contains { $0.name == "shield" })
        XCTAssertNil(items[items.count])

        room.send("remove_item")
        waitPumping("the item to go") {
            room.state?.players[sessionId]?.items.count == seeded
        }
    }

    func testMapSchemaSeesOtherPlayers() async throws {
        // A joinOrCreate lands in whatever room the other test files are
        // already in, and then the player count says nothing.
        let room = try await client.create("test_room", options: ["private": true], state: TestRoomState.self)
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player to decode") { room.state?.players[sessionId] != nil }

        room.send("add_bot")
        waitPumping("the bot to arrive") { (room.state?.players.count ?? 0) >= 2 }

        let players = try XCTUnwrap(room.state?.players)
        XCTAssertEqual(players.count, players.entries.count)
        XCTAssertTrue(players.keys.contains(sessionId))
        XCTAssertTrue(players.values.contains { $0.isBot })
    }

    func testLeaveReportsTheCode() async throws {
        let room = try await client.joinOrCreate("test_room", state: TestRoomState.self)

        let left = Counter()
        room.onLeave { code, _ in left.record(Int(code)) }

        waitPumping("the join") { room.state?.players.count ?? 0 > 0 }
        room.leave()

        waitPumping("the leave callback") { left.value > 0 }
        // 4000 is Colyseus's CONSENTED close code — a leave the client asked
        // for, as opposed to a drop.
        XCTAssertEqual(left.last, 4000)
    }

    func testTwoClientsSeeEachOther() async throws {
        let other = try Colyseus.Client(endpoint: Server.example)

        let first = try await client.create("test_room", options: ["private": true], state: TestRoomState.self)
        defer { first.leave() }
        let firstId = try XCTUnwrap(first.sessionId)

        waitPumping("the first player") { first.state?.players[firstId] != nil }
        let roomId = try XCTUnwrap(first.id)

        let second = try await other.joinById(roomId, state: TestRoomState.self)
        defer { second.leave() }
        let secondId = try XCTUnwrap(second.sessionId)

        waitPumping("each client to see both players") {
            first.state?.players[secondId] != nil && second.state?.players[firstId] != nil
        }

        second.send("move", ["x": 42.0, "y": 24.0])
        waitPumping("the other client's move to arrive") {
            first.state?.players[secondId]?.x == 42.0
        }
    }
}

/// XCTest closures escape, and the tests run in Swift 6 language mode, so
/// counters they touch have to be a reference type that is safe to share.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastValue = 0

    var value: Int { lock.withLock { count } }
    var last: Int { lock.withLock { lastValue } }

    func increment() { lock.withLock { count += 1 } }

    func record(_ value: Int) {
        lock.withLock {
            count += 1
            lastValue = value
        }
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
