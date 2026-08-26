import CColyseus
import XCTest
@testable import Colyseus

final class LinkageTests: XCTestCase {
    /// The whole point of the merged archive: every layer's symbols are in it.
    func testCoreSymbolsLink() {
        XCTAssertGreaterThan(colyseus_monotonic_ms(), 0)

        let clock = colyseus_room_clock_create()
        XCTAssertNotNil(clock)
        colyseus_room_clock_free(clock)

        XCTAssertEqual(colyseus_netdelay_in_flight(), 0)
    }

    func testMessageRoundTripsThroughTheCore() {
        let message = colyseus_message_map_create()
        defer { colyseus_message_free(message) }
        colyseus_message_map_put_int(message, "n", 7)

        var length = 0
        let bytes = colyseus_message_encode(message, &length)
        defer { colyseus_message_encoded_free(bytes, length) }
        XCTAssertEqual(length, 4)
    }
}
