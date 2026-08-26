import Foundation

/// A decoded message payload.
///
/// Messages are msgpack, which has no schema — what arrives is whatever the
/// server sent. Read it structurally:
///
/// ```swift
/// room.onMessage("shot") { payload in
///     let hit = payload["hit"]?.bool ?? false
/// }
/// ```
///
/// or decode it into a type, which is usually what you want:
///
/// ```swift
/// struct Shot: Decodable { let sid: String; let hit: Bool }
/// room.onMessage("shot") { (shot: Shot) in ... }
/// ```
public enum MessagePackValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([String: MessagePackValue])
}

// MARK: - Equality

// msgpack does not preserve the signed/unsigned distinction for a non-negative
// number: 5 sent as an Int arrives as a positive fixint and reads back
// unsigned. Comparing by case would make a value unequal to itself after one
// round trip, so the two integer cases compare — and hash — as one.
extension MessagePackValue: Hashable {
    public static func == (lhs: MessagePackValue, rhs: MessagePackValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.uint(let a), .uint(let b)):
            return a == b
        case (.int(let signed), .uint(let unsigned)), (.uint(let unsigned), .int(let signed)):
            return signed >= 0 && UInt64(signed) == unsigned
        case (.double(let a), .double(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.binary(let a), .binary(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.map(let a), .map(let b)):
            return a == b
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(value)
        case .int(let value) where value >= 0:
            hasher.combine(UInt64(value))
        case .int(let value):
            hasher.combine(value)
        case .uint(let value):
            hasher.combine(value)
        case .double(let value):
            hasher.combine(value)
        case .string(let value):
            hasher.combine(value)
        case .binary(let value):
            hasher.combine(value)
        case .array(let value):
            hasher.combine(value)
        case .map(let value):
            hasher.combine(value)
        }
    }
}

// MARK: - Reading

public extension MessagePackValue {
    var isNull: Bool { self == .null }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        default: return nil
        }
    }

    /// Any integral value, whether it arrived signed or unsigned. A `uint` too
    /// large for `Int` reads as nil rather than wrapping.
    var int: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .uint(let value): return Int(exactly: value)
        case .double(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    /// Any numeric value. Schema-adjacent payloads mix ints and floats freely,
    /// so this is the accessor most call sites want.
    var double: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .uint(let value): return Double(value)
        default: return nil
        }
    }

    var string: String? {
        switch self {
        case .string(let value): return value
        default: return nil
        }
    }

    var binary: Data? {
        switch self {
        case .binary(let value): return value
        default: return nil
        }
    }

    var array: [MessagePackValue]? {
        switch self {
        case .array(let value): return value
        default: return nil
        }
    }

    var map: [String: MessagePackValue]? {
        switch self {
        case .map(let value): return value
        default: return nil
        }
    }

    subscript(key: String) -> MessagePackValue? {
        guard case .map(let entries) = self else { return nil }
        return entries[key]
    }

    subscript(index: Int) -> MessagePackValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

// MARK: - Writing

extension MessagePackValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension MessagePackValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension MessagePackValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension MessagePackValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension MessagePackValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension MessagePackValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MessagePackValue...) { self = .array(elements) }
}

extension MessagePackValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, MessagePackValue)...) {
        self = .map(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension MessagePackValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return String(value)
        case .int(let value): return String(value)
        case .uint(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return "\"\(value)\""
        case .binary(let value): return "<\(value.count) bytes>"
        case .array(let items): return "[" + items.map(\.description).joined(separator: ", ") + "]"
        case .map(let entries):
            let body = entries
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            return "{" + body + "}"
        }
    }
}
