import CColyseus
import Foundation

/// Base class for the schema types `schema-codegen --swift` generates.
///
/// A generated class is a façade: it holds no decoded data of its own, only a
/// pointer to the instance the core decoded, and its properties read through
/// ``view``.
///
/// ```swift
/// public final class Player: SchemaRef {
///     public var x: Double { view["x"] }
///     public var name: String { view.string("name") ?? "" }
/// }
/// ```
///
/// The instance a ref points at belongs to the decoder, which replaces
/// instances on resync — after a reconnect, say. Read refs out of
/// ``Colyseus/Room/state`` each frame rather than storing them across frames.
open class SchemaRef: SchemaValue, @unchecked Sendable {
    public let view: SchemaView

    public required init(_ view: SchemaView) {
        self.view = view
    }

    /// The instance pointer, for the prediction APIs that take one.
    public var handle: UnsafeMutableRawPointer { view.handle }

    /// The ref this field points at, or nil while the server has not set it.
    public func refOf<T: SchemaRef>(_ field: String, _: T.Type = T.self) -> T? {
        SchemaView(view.child(field)).map(T.init)
    }

    public func mapOf<T: SchemaValue>(_ field: String, _: T.Type = T.self) -> MapSchema<T> {
        MapSchema(owner: self, field: field)
    }

    public func arrayOf<T: SchemaValue>(_ field: String, _: T.Type = T.self) -> ArraySchema<T> {
        ArraySchema(owner: self, field: field)
    }

    public static func _fromSchemaSlot(
        _ pointer: UnsafeMutableRawPointer,
        primitive _: SchemaFieldType?
    ) -> Self? {
        SchemaView(pointer).map(Self.init)
    }
}

/// Something a schema slot can hold: a generated ``SchemaRef``, or one of the
/// primitives a `t.number()` field or a `t.array(t.number())` yields.
///
/// The core stores primitives at their declared width — an `int8` really is
/// one byte behind the pointer — so reading one needs the declared type, which
/// is what `primitive` carries. Collections and change callbacks both hand out
/// slots this way, which is why one protocol serves both.
public protocol SchemaValue {
    static func _fromSchemaSlot(
        _ pointer: UnsafeMutableRawPointer,
        primitive: SchemaFieldType?
    ) -> Self?
}

extension Double: SchemaValue {
    public static func _fromSchemaSlot(
        _ pointer: UnsafeMutableRawPointer,
        primitive: SchemaFieldType?
    ) -> Double? {
        readPrimitiveNumber(pointer, primitive)
    }
}

extension Int: SchemaValue {
    public static func _fromSchemaSlot(
        _ pointer: UnsafeMutableRawPointer,
        primitive: SchemaFieldType?
    ) -> Int? {
        readPrimitiveNumber(pointer, primitive).flatMap { Int(exactly: $0.rounded()) }
    }
}

extension Bool: SchemaValue {
    public static func _fromSchemaSlot(
        _ pointer: UnsafeMutableRawPointer,
        primitive: SchemaFieldType?
    ) -> Bool? {
        readPrimitiveNumber(pointer, primitive).map { $0 != 0 }
    }
}

extension String: SchemaValue {
    public static func _fromSchemaSlot(
        _ pointer: UnsafeMutableRawPointer,
        primitive: SchemaFieldType?
    ) -> String? {
        guard primitive == .string || primitive == nil else { return nil }
        return String(nullableCString: pointer.assumingMemoryBound(to: CChar.self))
    }
}

/// Primitives in a collection are stored at their declared width, so the type
/// decides how many bytes to load. Anything else would read neighbouring heap.
private func readPrimitiveNumber(
    _ pointer: UnsafeMutableRawPointer,
    _ primitive: SchemaFieldType?
) -> Double? {
    switch primitive {
    case .boolean, .int8: return Double(pointer.load(as: Int8.self))
    case .uint8: return Double(pointer.load(as: UInt8.self))
    case .int16: return Double(pointer.load(as: Int16.self))
    case .uint16: return Double(pointer.load(as: UInt16.self))
    case .int32: return Double(pointer.load(as: Int32.self))
    case .uint32: return Double(pointer.load(as: UInt32.self))
    case .int64: return Double(pointer.load(as: Int64.self))
    case .uint64: return Double(pointer.load(as: UInt64.self))
    case .float32: return Double(pointer.load(as: Float.self))
    case .number, .float64, .quantized: return pointer.load(as: Double.self)
    case .string, .ref, .array, .map, .none: return nil
    }
}
