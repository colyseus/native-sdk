import Foundation

/// msgpack, the subset Colyseus speaks.
///
/// Decoding happens here rather than in the C core because the core's reader
/// flattens nested maps and arrays and truncates long payloads — the same
/// reason the Flutter binding decodes in Dart.
enum MessagePack {

    // MARK: - Decoding

    enum DecodingError: Error, CustomStringConvertible {
        case truncated
        case unsupportedFormat(UInt8)
        case invalidUTF8
        case nonStringKey

        var description: String {
            switch self {
            case .truncated: return "message ended mid-value"
            case .unsupportedFormat(let byte): return String(format: "unsupported msgpack format 0x%02x", byte)
            case .invalidUTF8: return "string field is not valid UTF-8"
            case .nonStringKey: return "map key is not a string"
            }
        }
    }

    static func decode(_ bytes: Data) throws -> MessagePackValue {
        var reader = Reader(bytes)
        return try reader.readValue()
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func readValue() throws -> MessagePackValue {
            let format = try readByte()

            switch format {
            case 0x00...0x7f: return .uint(UInt64(format))                    // positive fixint
            case 0xe0...0xff: return .int(Int64(Int8(bitPattern: format)))    // negative fixint
            case 0x80...0x8f: return try readMap(count: Int(format & 0x0f))   // fixmap
            case 0x90...0x9f: return try readArray(count: Int(format & 0x0f)) // fixarray
            case 0xa0...0xbf: return .string(try readString(count: Int(format & 0x1f)))

            case 0xc0: return .null
            case 0xc2: return .bool(false)
            case 0xc3: return .bool(true)

            case 0xc4: return .binary(try readData(count: Int(try readByte())))
            case 0xc5: return .binary(try readData(count: Int(try readInteger(UInt16.self))))
            case 0xc6: return .binary(try readData(count: Int(try readInteger(UInt32.self))))

            case 0xca: return .double(Double(Float(bitPattern: try readInteger(UInt32.self))))
            case 0xcb: return .double(Double(bitPattern: try readInteger(UInt64.self)))

            case 0xcc: return .uint(UInt64(try readByte()))
            case 0xcd: return .uint(UInt64(try readInteger(UInt16.self)))
            case 0xce: return .uint(UInt64(try readInteger(UInt32.self)))
            case 0xcf: return .uint(try readInteger(UInt64.self))

            case 0xd0: return .int(Int64(Int8(bitPattern: try readByte())))
            case 0xd1: return .int(Int64(Int16(bitPattern: try readInteger(UInt16.self))))
            case 0xd2: return .int(Int64(Int32(bitPattern: try readInteger(UInt32.self))))
            case 0xd3: return .int(Int64(bitPattern: try readInteger(UInt64.self)))

            case 0xd9: return .string(try readString(count: Int(try readByte())))
            case 0xda: return .string(try readString(count: Int(try readInteger(UInt16.self))))
            case 0xdb: return .string(try readString(count: Int(try readInteger(UInt32.self))))

            case 0xdc: return try readArray(count: Int(try readInteger(UInt16.self)))
            case 0xdd: return try readArray(count: Int(try readInteger(UInt32.self)))

            case 0xde: return try readMap(count: Int(try readInteger(UInt16.self)))
            case 0xdf: return try readMap(count: Int(try readInteger(UInt32.self)))

            default: throw DecodingError.unsupportedFormat(format)
            }
        }

        private mutating func readByte() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodingError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        private mutating func readInteger<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) throws -> T {
            let width = MemoryLayout<T>.size
            guard offset + width <= bytes.count else { throw DecodingError.truncated }
            defer { offset += width }
            return bytes[offset ..< offset + width].reduce(T.zero) { ($0 << 8) | T($1) }
        }

        private mutating func readData(count: Int) throws -> Data {
            guard offset + count <= bytes.count else { throw DecodingError.truncated }
            defer { offset += count }
            return Data(bytes[offset ..< offset + count])
        }

        private mutating func readString(count: Int) throws -> String {
            let data = try readData(count: count)
            guard let string = String(data: data, encoding: .utf8) else {
                throw DecodingError.invalidUTF8
            }
            return string
        }

        private mutating func readArray(count: Int) throws -> MessagePackValue {
            var items: [MessagePackValue] = []
            items.reserveCapacity(count)
            for _ in 0 ..< count { items.append(try readValue()) }
            return .array(items)
        }

        private mutating func readMap(count: Int) throws -> MessagePackValue {
            var entries: [String: MessagePackValue] = [:]
            entries.reserveCapacity(count)
            for _ in 0 ..< count {
                // Colyseus only ever sends string keys; anything else means we
                // are reading the wrong offset.
                guard case .string(let key) = try readValue() else {
                    throw DecodingError.nonStringKey
                }
                entries[key] = try readValue()
            }
            return .map(entries)
        }
    }

    // MARK: - Encoding

    static func encode(_ value: MessagePackValue) -> Data {
        var out = Data()
        append(value, to: &out)
        return out
    }

    private static func append(_ value: MessagePackValue, to out: inout Data) {
        switch value {
        case .null:
            out.append(0xc0)

        case .bool(let flag):
            out.append(flag ? 0xc3 : 0xc2)

        case .uint(let number):
            appendUInt(number, to: &out)

        case .int(let number):
            if number >= 0 {
                appendUInt(UInt64(number), to: &out)
            } else if number >= -32 {
                out.append(UInt8(bitPattern: Int8(number)))
            } else if let small = Int8(exactly: number) {
                out.append(0xd0)
                out.append(UInt8(bitPattern: small))
            } else if let small = Int16(exactly: number) {
                out.append(0xd1)
                appendBigEndian(UInt16(bitPattern: small), to: &out)
            } else if let small = Int32(exactly: number) {
                out.append(0xd2)
                appendBigEndian(UInt32(bitPattern: small), to: &out)
            } else {
                out.append(0xd3)
                appendBigEndian(UInt64(bitPattern: number), to: &out)
            }

        case .double(let number):
            // Always float64. Narrowing to float32 would save four bytes and
            // silently change the value the server reads back.
            out.append(0xcb)
            appendBigEndian(number.bitPattern, to: &out)

        case .string(let text):
            let utf8 = Data(text.utf8)
            switch utf8.count {
            case 0 ..< 32: out.append(0xa0 | UInt8(utf8.count))
            case 32 ..< 256:
                out.append(0xd9)
                out.append(UInt8(utf8.count))
            case 256 ..< 65_536:
                out.append(0xda)
                appendBigEndian(UInt16(utf8.count), to: &out)
            default:
                out.append(0xdb)
                appendBigEndian(UInt32(utf8.count), to: &out)
            }
            out.append(utf8)

        case .binary(let data):
            switch data.count {
            case 0 ..< 256:
                out.append(0xc4)
                out.append(UInt8(data.count))
            case 256 ..< 65_536:
                out.append(0xc5)
                appendBigEndian(UInt16(data.count), to: &out)
            default:
                out.append(0xc6)
                appendBigEndian(UInt32(data.count), to: &out)
            }
            out.append(data)

        case .array(let items):
            switch items.count {
            case 0 ..< 16: out.append(0x90 | UInt8(items.count))
            case 16 ..< 65_536:
                out.append(0xdc)
                appendBigEndian(UInt16(items.count), to: &out)
            default:
                out.append(0xdd)
                appendBigEndian(UInt32(items.count), to: &out)
            }
            for item in items { append(item, to: &out) }

        case .map(let entries):
            switch entries.count {
            case 0 ..< 16: out.append(0x80 | UInt8(entries.count))
            case 16 ..< 65_536:
                out.append(0xde)
                appendBigEndian(UInt16(entries.count), to: &out)
            default:
                out.append(0xdf)
                appendBigEndian(UInt32(entries.count), to: &out)
            }
            // Sorted so the same payload always produces the same bytes, which
            // is what makes encoder tests worth writing.
            for (key, item) in entries.sorted(by: { $0.key < $1.key }) {
                append(.string(key), to: &out)
                append(item, to: &out)
            }
        }
    }

    private static func appendUInt(_ number: UInt64, to out: inout Data) {
        switch number {
        case 0 ..< 128: out.append(UInt8(number))
        case 128 ..< 256:
            out.append(0xcc)
            out.append(UInt8(number))
        case 256 ..< 65_536:
            out.append(0xcd)
            appendBigEndian(UInt16(number), to: &out)
        case 65_536 ..< 4_294_967_296:
            out.append(0xce)
            appendBigEndian(UInt32(number), to: &out)
        default:
            out.append(0xcf)
            appendBigEndian(number, to: &out)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ number: T, to out: inout Data) {
        withUnsafeBytes(of: number.bigEndian) { out.append(contentsOf: $0) }
    }
}
