import Foundation
import XCTest
@testable import Colyseus

/// `room.request()` against the example server's `request_*` fixtures — one
/// test per outcome the wire can carry, plus the two it can't (no reply, and a
/// caller that gave up).
///
/// The pump runs on its own timer here: a request resumes inside `pump()`, so a
/// suite that drives the pump by hand would await a reply it never releases.
final class RequestIntegrationTests: XCTestCase {
    private var client: Colyseus.Client!

    override func setUpWithError() throws {
        try Server.requireExample()
        client = try Colyseus.Client(endpoint: Server.example)
    }

    override func tearDown() {
        client = nil
    }

    private func room() async throws -> Colyseus.Room<TestRoomState> {
        try await client.create("test_room", options: ["private": true], state: TestRoomState.self)
    }

    func testReplyCarriesTheHandlersReturnValue() async throws {
        let room = try await room()
        defer { room.leave() }

        let reply = try await room.request("request_sum", ["a": 1, "b": 2])
        XCTAssertEqual(reply.int, 3)
    }

    func testANestedReplySurvivesTheRoundTrip() async throws {
        let room = try await room()
        defer { room.leave() }

        let reply = try await room.request("request_echo", [
            "nested": ["list": [1, 2], "flag": true],
        ])
        XCTAssertEqual(reply["nested"]?["list"]?[1]?.int, 2)
        XCTAssertEqual(reply["nested"]?["flag"]?.bool, true)
    }

    func testASideEffectOnlyHandlerRepliesNull() async throws {
        let room = try await room()
        defer { room.leave() }

        let reply = try await room.request("request_ack")
        XCTAssertTrue(reply.isNull)
    }

    func testARejectionKeepsTheReasonTheServerAuthored() async throws {
        let room = try await room()
        defer { room.leave() }

        do {
            _ = try await room.request("request_deny")
            XCTFail("a rejected request has to throw")
        } catch Colyseus.Error.requestRejected(let reason) {
            // The reason arrives structured, not flattened into the message —
            // which is the whole point of separating a reject from a fault.
            XCTAssertEqual(reason["code"]?.int, 403)
            XCTAssertEqual(reason["why"]?.string, "denied by the room")
        }
    }

    func testAThrownHandlerFaultsAndCannotPoseAsARejection() async throws {
        let room = try await room()
        defer { room.leave() }

        do {
            _ = try await room.request("request_boom")
            XCTFail("a faulted request has to throw")
        } catch Colyseus.Error.requestFailed(let name, let message, _) {
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testAnUnregisteredTypeFaultsRatherThanHanging() async throws {
        let room = try await room()
        defer { room.leave() }

        // The failure this guards is a caller waiting out its whole timeout for
        // a reply the server was never going to send.
        let started = Date()
        do {
            _ = try await room.request("no_such_handler", timeout: 5)
            XCTFail("an unhandled type has to throw")
        } catch Colyseus.Error.requestFailed {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testATimeoutGivesUpAndTheLateReplyIsHarmless() async throws {
        let room = try await room()
        defer { room.leave() }

        let started = Date()
        do {
            _ = try await room.request("request_slow", ["ms": 2000], timeout: 0.3)
            XCTFail("a request with no reply in time has to throw")
        } catch Colyseus.Error.requestTimedOut(let type, let seconds) {
            XCTAssertEqual(type, "request_slow")
            XCTAssertEqual(seconds, 0.3, accuracy: 1e-9)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

        // The server still answers ~1.7s from now. Staying alive through it is
        // the assertion: a timeout that left the pending entry behind would
        // resume a spent continuation when the reply landed.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let reply = try await room.request("request_sum", ["a": 20, "b": 22])
        XCTAssertEqual(reply.int, 42)
    }

    func testTimeoutsAreConfigurableGlobally() async throws {
        let room = try await room()
        defer { room.leave() }

        let previous = Colyseus.defaultRequestTimeout
        Colyseus.defaultRequestTimeout = 0.3
        defer { Colyseus.defaultRequestTimeout = previous }

        do {
            _ = try await room.request("request_slow", ["ms": 2000])
            XCTFail("the global default has to apply when no timeout is passed")
        } catch Colyseus.Error.requestTimedOut(_, let seconds) {
            XCTAssertEqual(seconds, 0.3, accuracy: 1e-9)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    func testCancellingTheTaskAbandonsTheRequest() async throws {
        let room = try await room()
        defer { room.leave() }

        let task = Task { try await room.request("request_slow", ["ms": 2000], timeout: 10) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled request has to throw")
        } catch is CancellationError {
            // expected
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    func testLeavingAnswersWhatIsStillInFlight() async throws {
        let room = try await room()

        let task = Task { try await room.request("request_slow", ["ms": 5000], timeout: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        room.leave()

        // A caller must not be left waiting on a reply that can no longer come.
        do {
            _ = try await task.value
            XCTFail("a request outliving its room has to throw")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }
}
