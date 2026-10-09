import Foundation
import XCTest
@testable import Colyseus

/// `consumeSeatReservation` against the example server, whose
/// `POST /reserve_seat` returns what `matchMaker.joinOrCreate()` reserved.
final class SeatReservationIntegrationTests: XCTestCase {
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

    private func reserveSeat() async throws -> Colyseus.HTTP.Response {
        try await client.http.post("/reserve_seat", json: #"{"roomName":"test_room","options":{"private":true}}"#)
    }

    func testConsumesATypedReservation() async throws {
        let seat = try await reserveSeat().decode(Colyseus.SeatReservation.self)
        let room = try await client.consumeSeatReservation(seat, state: TestRoomState.self)
        defer { room.leave() }

        XCTAssertEqual(room.sessionId, seat.sessionId)
        XCTAssertEqual(room.id, seat.roomId)
        XCTAssertEqual(room.name, "test_room")
        waitPumping("own player to decode") { room.state?.players[seat.sessionId] != nil }
    }

    func testConsumesAReservationAsAPayload() async throws {
        let response = try await reserveSeat()
        let seat = try XCTUnwrap(response.json)
        let room = try await client.consumeSeatReservation(seat, state: TestRoomState.self)
        defer { room.leave() }

        XCTAssertEqual(room.sessionId, seat["sessionId"]?.string)
    }

    func testConnectsToTheReservationsPublicAddress() async throws {
        var seat = try await reserveSeat().decode(Colyseus.SeatReservation.self)
        seat.publicAddress = "127.0.0.1:2567"

        // nothing listens on this client's own endpoint
        let deadClient = try Colyseus.Client(endpoint: "ws://127.0.0.1:1")
        let room = try await deadClient.consumeSeatReservation(seat, state: TestRoomState.self)
        // the room borrows its client's settings, so the client outlives it
        defer { room.leave(); withExtendedLifetime(deadClient) {} }

        XCTAssertEqual(room.sessionId, seat.sessionId)
        XCTAssertTrue(room.isConnected)
    }

    func testAnInvalidReservationThrows() async throws {
        do {
            let room = try await client.consumeSeatReservation(["roomId": "nope"], state: TestRoomState.self)
            room.leave()
            XCTFail("an incomplete reservation should not join")
        } catch Colyseus.Error.matchmaking(_, let message) {
            XCTAssertEqual(message, "Invalid seat reservation: missing name")
        }
    }
}
