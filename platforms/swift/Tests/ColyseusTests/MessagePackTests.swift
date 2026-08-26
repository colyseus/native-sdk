import CColyseus
import Foundation
import XCTest
@testable import Colyseus

/// The Swift codec and the core's Zig one have to agree on the wire, so most
/// of these check one against the other rather than against a literal.
final class MessagePackTests: XCTestCase {

    // MARK: - Round trips

    private func roundTrip(_ value: MessagePackValue, file: StaticString = #filePath, line: UInt = #line) {
        let encoded = MessagePack.encode(value)
        do {
            let decoded = try MessagePack.decode(encoded)
            XCTAssertEqual(decoded, value, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testScalarsRoundTrip() {
        roundTrip(.null)
        roundTrip(.bool(true))
        roundTrip(.bool(false))
        roundTrip(.string(""))
        roundTrip(.string("hello"))
        roundTrip(.string(String(repeating: "x", count: 400)))
        roundTrip(.string(String(repeating: "y", count: 70_000)))
        roundTrip(.string("héllo 🌍"))
        roundTrip(.binary(Data([0, 1, 2, 255])))
    }

    func testIntegerBoundariesRoundTrip() {
        for value: Int64 in [0, 1, 127, -1, -32, -33, 128, 255, 256, 65_535, 65_536,
                             Int64(Int32.min), Int64(Int32.max), Int64.min, Int64.max] {
            roundTrip(.int(value))
        }
        for value: UInt64 in [0, 127, 128, 255, 256, 65_535, 65_536, 4_294_967_296, UInt64.max] {
            roundTrip(.uint(value))
        }
    }

    func testDoublesRoundTrip() {
        for value in [0.0, -0.5, 3.14159265358979, 1e300, -1e-300, Double.greatestFiniteMagnitude] {
            roundTrip(.double(value))
        }
        // NaN never equals itself, so check the bit pattern instead.
        let nan = try? MessagePack.decode(MessagePack.encode(.double(.nan)))
        XCTAssertEqual(nan?.double?.isNaN, true)
    }

    func testNestedStructuresRoundTrip() {
        roundTrip(["players": [["x": 1.5, "y": -2.0], ["x": 0.0, "y": 0.0]], "tick": 42])
        roundTrip(.array((0 ..< 40).map { .int(Int64($0)) }))
        roundTrip(.map(Dictionary(uniqueKeysWithValues: (0 ..< 40).map { ("k\($0)", MessagePackValue.int(Int64($0))) })))
    }

    // MARK: - Agreement with the core

    /// Encode with the C builder, decode in Swift.
    func testDecodesWhatTheCoreEncodes() throws {
        let message = colyseus_message_map_create()
        defer { colyseus_message_free(message) }
        colyseus_message_map_put_str(message, "sid", "abc")
        colyseus_message_map_put_int(message, "count", -7)
        colyseus_message_map_put_uint(message, "big", 70_000)
        colyseus_message_map_put_float(message, "x", 1.25)
        colyseus_message_map_put_bool(message, "hit", true)
        colyseus_message_map_put_nil(message, "nothing")

        let nested = colyseus_message_array_create()
        colyseus_message_array_push_int(nested, 1)
        colyseus_message_array_push_str(nested, "two")
        colyseus_message_map_put_msg(message, "list", nested)
        colyseus_message_free(nested)

        var length = 0
        let bytes = colyseus_message_encode(message, &length)
        defer { colyseus_message_encoded_free(bytes, length) }
        let decoded = try MessagePack.decode(Data(bytes: bytes!, count: length))

        XCTAssertEqual(decoded["sid"]?.string, "abc")
        XCTAssertEqual(decoded["count"]?.int, -7)
        XCTAssertEqual(decoded["big"]?.int, 70_000)
        XCTAssertEqual(decoded["x"]?.double, 1.25)
        XCTAssertEqual(decoded["hit"]?.bool, true)
        XCTAssertEqual(decoded["nothing"]?.isNull, true)
        XCTAssertEqual(decoded["list"]?[0]?.int, 1)
        XCTAssertEqual(decoded["list"]?[1]?.string, "two")
    }

    /// Encode in Swift, decode with the core's reader.
    func testTheCoreReadsWhatWeEncode() throws {
        let payload: MessagePackValue = ["sid": "abc", "count": -7, "x": 1.25, "hit": true]
        var bytes = [UInt8](MessagePack.encode(payload))

        let reader = colyseus_message_reader_create(&bytes, bytes.count)
        defer { colyseus_message_reader_free(reader) }

        XCTAssertTrue(colyseus_message_reader_is_map(reader))

        var text: UnsafePointer<CChar>?
        var textLength = 0
        XCTAssertTrue(colyseus_message_reader_map_get_str(reader, "sid", &text, &textLength))
        XCTAssertEqual(String(cString: text!), "abc")

        var count: Int64 = 0
        XCTAssertTrue(colyseus_message_reader_map_get_int(reader, "count", &count))
        XCTAssertEqual(count, -7)

        var x = 0.0
        XCTAssertTrue(colyseus_message_reader_map_get_float(reader, "x", &x))
        XCTAssertEqual(x, 1.25)

        var hit = false
        XCTAssertTrue(colyseus_message_reader_map_get_bool(reader, "hit", &hit))
        XCTAssertTrue(hit)
    }

    // MARK: - Reading

    func testAccessorsAreForgivingAboutNumericKinds() {
        XCTAssertEqual(MessagePackValue.uint(5).int, 5)
        XCTAssertEqual(MessagePackValue.int(-5).double, -5)
        XCTAssertEqual(MessagePackValue.double(5).int, 5)
        XCTAssertNil(MessagePackValue.uint(.max).int)
        XCTAssertNil(MessagePackValue.string("5").int)
    }

    func testSubscriptsReturnNilOffTheEnd() {
        let value: MessagePackValue = ["a": [1, 2]]
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["a"]?[9])
        XCTAssertNil(value[0])
    }

    // MARK: - Malformed input

    func testTruncatedPayloadThrows() {
        let full = MessagePack.encode(["key": "a long enough string"])
        XCTAssertThrowsError(try MessagePack.decode(full.prefix(4)))
    }

    func testUnsupportedFormatThrows() {
        XCTAssertThrowsError(try MessagePack.decode(Data([0xc1])))
    }
}
