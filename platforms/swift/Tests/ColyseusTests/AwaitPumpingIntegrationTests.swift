import Foundation
import XCTest
@testable import Colyseus

/// Latency probes and pings only advance inside a pump, so awaiting one has to
/// finish whether or not anything else is pumping — the await pumps for itself
/// when the app isn't, and keeps the automatic pump alive when it's on.
final class AwaitPumpingIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try Server.requireExample()
    }

    override func tearDown() {
        Colyseus.autoPump = true
    }

    func testLatencyResolvesWithNothingPumping() async throws {
        Colyseus.autoPump = false
        let latency = await Colyseus.Client.latency(of: Server.example)
        XCTAssertNotNil(latency)
    }

    func testFastestEndpointResolvesOnTheAutomaticPump() async throws {
        Colyseus.autoPump = true
        let fastest = await Colyseus.Client.fastestEndpoint(among: [Server.example])
        XCTAssertEqual(fastest?.endpoint, Server.example)
    }

    func testPingResolvesWithNothingPumping() async throws {
        Colyseus.autoPump = false
        let client = try Colyseus.Client(endpoint: Server.example)
        let room = try await client.create("test_room", options: ["private": true], state: TestRoomState.self)
        defer { room.leave() }

        let rtt = try await room.ping()
        XCTAssertGreaterThanOrEqual(rtt, 0)
    }
}
