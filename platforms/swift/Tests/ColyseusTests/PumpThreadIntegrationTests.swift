import CColyseus
import Foundation
import XCTest
@testable import Colyseus

/// Where callbacks run: inside `Colyseus.pump()`, on the thread that called
/// it, and nowhere else — join, state, messages, errors, drop, reconnect and
/// leave alike.
///
/// The tests run a `PumpLoop`, a frame loop on a thread of its own, and trace
/// every callback against it. They wait by sleeping, never by pumping, so the
/// loop is the only thing that pumps.
final class PumpThreadIntegrationTests: XCTestCase {
    private var client: Colyseus.Client!
    private var loop: PumpLoop!

    override func setUpWithError() throws {
        try Server.requireExample()
        Colyseus.autoPump = false
        client = try Colyseus.Client(endpoint: Server.example)
        loop = PumpLoop()
    }

    override func tearDown() {
        loop?.stop()
        loop = nil
        client = nil
        Colyseus.autoPump = true
    }

    func testEveryRoomCallbackRunsOnThePumpingThread() throws {
        let trace = ThreadTrace(loop)
        let joined = Guarded<Colyseus.Room<TestRoomState>?>(nil)

        // Built inside the matchmaking callback, as the SDK does, so the
        // handlers are in place for the JOIN_ROOM handshake itself.
        let probe = JoinProbe(opened: { raw in
            let room = Colyseus.Room<TestRoomState>(raw: raw)
            room.onJoin { trace.record("join") }
            room.onStateChange { _ in trace.record("state") }
            room.onMessage("join_options") { _ in trace.record("message") }
            room.onMessage("tagged_echo") { _ in trace.record("echo") }
            room.onError { _, _ in trace.record("error") }
            room.onDrop { _, _ in trace.record("drop") }
            room.onReconnect { trace.record("reconnect") }
            room.onLeave { _, _ in trace.record("leave") }
            joined.current = room
        }, failed: { message in
            XCTFail("matchmaking failed: \(message)")
        })
        loop.post { [client] in probe.create(on: client!, "test_room", options: #"{"private":true}"#) }

        waitFor("the join, its first state and the join_options message") {
            trace.count(of: "join") == 1 && trace.count(of: "state") > 0 && trace.count(of: "message") > 0
        }
        let room = try XCTUnwrap(joined.current)

        // The default wants 5 s of uptime before a drop counts as reconnectable.
        var reconnection = room.reconnection
        reconnection.minUptimeMs = 0
        room.reconnection = reconnection

        loop.post { room.send("echo", ["n": 1]) }
        waitFor("the echo") { trace.count(of: "echo") == 1 }

        loop.post { room.dropConnection() }
        waitFor("the drop, then the reconnect") {
            trace.count(of: "drop") == 1 && trace.count(of: "reconnect") == 1
        }

        loop.post { room.send("echo", ["n": 2]) }
        waitFor("an echo over the new connection") { trace.count(of: "echo") == 2 }

        loop.post { room.leave() }
        waitFor("the leave") { trace.count(of: "leave") == 1 }

        XCTAssertEqual(trace.strays, [])
    }

    func testMatchmakingAnswersOnThePumpingThread() throws {
        let trace = ThreadTrace(loop)
        let opened = Guarded<Colyseus.Room<TestRoomState>?>(nil)

        let success = JoinProbe(opened: { raw in
            trace.record("matchmake")
            opened.current = Colyseus.Room<TestRoomState>(raw: raw)
        }, failed: { message in
            XCTFail("matchmaking failed: \(message)")
        })
        let failure = JoinProbe(opened: { raw in
            trace.record("unexpected room")
            opened.current = Colyseus.Room<TestRoomState>(raw: raw)
        }, failed: { _ in
            trace.record("matchmake error")
        })

        loop.post { [client] in
            success.create(on: client!, "test_room", options: #"{"private":true}"#)
            failure.joinById(on: client!, "no-such-room")
        }

        waitFor("both matchmaking answers") {
            trace.count(of: "matchmake") == 1 && trace.count(of: "matchmake error") == 1
        }
        XCTAssertEqual(trace.strays, [])

        loop.sync { opened.current?.leave() }
    }

    func testNothingIsDeliveredBetweenPumps() throws {
        let trace = ThreadTrace(loop)
        let room = try joinWhileTheLoopPumps()
        let sessionId = try XCTUnwrap(room.sessionId)

        room.onStateChange { _ in trace.record("state") }
        room.onMessage("tagged_echo") { _ in trace.record("echo") }
        room.onDrop { _, _ in trace.record("drop") }
        room.onReconnect { trace.record("reconnect") }

        var reconnection = room.reconnection
        reconnection.minUptimeMs = 0
        room.reconnection = reconnection

        waitFor("own player to decode") { loop.sync { room.state?.players[sessionId] != nil } }

        // Traffic the server answers, while nothing pumps.
        loop.isPumping = false
        let before = trace.count
        room.send("move", ["x": 77.0, "y": 1.0])
        room.send("echo", ["n": 1])
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertEqual(trace.count, before, "delivered between pumps: \(trace.all.dropFirst(before))")
        // Safe to read from here: no pump is running.
        XCTAssertNotEqual(room.state?.players[sessionId]?.x, 77.0, "decoded between pumps")

        loop.isPumping = true
        waitFor("the echo and the move, once pumped") {
            trace.count(of: "echo") == 1 && loop.sync { room.state?.players[sessionId]?.x == 77.0 }
        }

        // The core reports this close synchronously, on this thread; the
        // handler still waits for a pump.
        loop.isPumping = false
        room.dropConnection()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(trace.count(of: "drop"), 0, "onDrop ran between pumps")

        loop.isPumping = true
        waitFor("the drop, then the reconnect") {
            trace.count(of: "drop") == 1 && trace.count(of: "reconnect") == 1
        }

        XCTAssertEqual(trace.strays, [])
        loop.sync { room.leave() }
    }

    func testAutoPumpDeliversOnTheCallbackQueue() async throws {
        loop.isPumping = false
        Colyseus.autoPump = true

        let room = try await client.create("test_room", options: ["private": true], state: TestRoomState.self)

        let offMain = Counter()
        let echoed = expectation(description: "the echo")
        let left = expectation(description: "the leave")
        room.onMessage("tagged_echo") { _ in
            if !Thread.isMainThread { offMain.increment() }
            echoed.fulfill()
        }
        room.onLeave { _, _ in
            if !Thread.isMainThread { offMain.increment() }
            left.fulfill()
        }

        room.send("echo", ["n": 1])
        await fulfillment(of: [echoed], timeout: 5)

        room.leave()
        await fulfillment(of: [left], timeout: 5)

        XCTAssertEqual(offMain.value, 0, "callbacks ran off the main queue")
    }

    // MARK: -

    /// The Swift surface's join, awaited elsewhere while the loop pumps — the
    /// case where an await must leave the pumping to the app.
    private func joinWhileTheLoopPumps() throws -> Colyseus.Room<TestRoomState> {
        let outcome = Guarded<Result<Colyseus.Room<TestRoomState>, Swift.Error>?>(nil)
        Task.detached { [client] in
            do {
                let room = try await client!.create("test_room", options: ["private": true], state: TestRoomState.self)
                outcome.current = .success(room)
            } catch {
                outcome.current = .failure(error)
            }
        }
        waitFor("the join") { outcome.current != nil }
        return try XCTUnwrap(outcome.current).get()
    }

    /// Wait without pumping: the loop is the only thing that may.
    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 10,
        until condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}
