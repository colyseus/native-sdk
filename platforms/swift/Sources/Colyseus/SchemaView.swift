import CColyseus
import Foundation

/// The kinds a schema field can have on the wire.
public enum SchemaFieldType: Sendable, Hashable {
    case string, boolean, number, quantized
    case int8, uint8, int16, uint16, int32, uint32, int64, uint64
    case float32, float64
    case ref, array, map

    init?(_ raw: colyseus_field_type_t) {
        switch raw {
        case COLYSEUS_FIELD_STRING: self = .string
        case COLYSEUS_FIELD_BOOLEAN: self = .boolean
        case COLYSEUS_FIELD_NUMBER: self = .number
        case COLYSEUS_FIELD_QUANTIZED: self = .quantized
        case COLYSEUS_FIELD_INT8: self = .int8
        case COLYSEUS_FIELD_UINT8: self = .uint8
        case COLYSEUS_FIELD_INT16: self = .int16
        case COLYSEUS_FIELD_UINT16: self = .uint16
        case COLYSEUS_FIELD_INT32: self = .int32
        case COLYSEUS_FIELD_UINT32: self = .uint32
        case COLYSEUS_FIELD_INT64: self = .int64
        case COLYSEUS_FIELD_UINT64: self = .uint64
        case COLYSEUS_FIELD_FLOAT32: self = .float32
        case COLYSEUS_FIELD_FLOAT64: self = .float64
        case COLYSEUS_FIELD_REF: self = .ref
        case COLYSEUS_FIELD_ARRAY: self = .array
        case COLYSEUS_FIELD_MAP: self = .map
        default: return nil
        }
    }

    /// Whether the field reads as a `Double`. Everything numeric does — the
    /// SDK does not distinguish int widths on the way out, because the schema
    /// already pinned the range on the way in.
    public var isNumeric: Bool {
        switch self {
        case .string, .boolean, .ref, .array, .map: return false
        default: return true
        }
    }
}

/// Direct access to one decoded schema instance.
///
/// A view is a pointer, not a copy: it reads the live decoded state, so a read
/// after the next ``Colyseus/pump()`` sees the next patch. Hold values, not
/// views, across frames.
public struct SchemaView: @unchecked Sendable {
    let instance: UnsafeMutablePointer<colyseus_schema_t>

    init(_ instance: UnsafeMutablePointer<colyseus_schema_t>) {
        self.instance = instance
    }

    init?(_ raw: UnsafeMutableRawPointer?) {
        guard let raw else { return nil }
        self.init(raw.assumingMemoryBound(to: colyseus_schema_t.self))
    }

    /// The instance pointer, for the prediction APIs that take one.
    public var handle: UnsafeMutableRawPointer { UnsafeMutableRawPointer(instance) }

    // MARK: - Reading

    /// A numeric field, or NaN when the schema has no such field.
    ///
    /// NaN rather than 0 on purpose: a typo in a field name should show up as
    /// an obviously broken value, not as a plausible one.
    public subscript(field: String) -> Double {
        guard let resolved = resolve(field), resolved.type != COLYSEUS_FIELD_STRING else {
            return .nan
        }
        return colyseus_schema_read_scalar(instance, resolved.type, resolved.offset, resolved.index)
    }

    public func number(_ field: String) -> Double { self[field] }

    public func bool(_ field: String) -> Bool { self[field] != 0 }

    public func string(_ field: String) -> String? {
        guard let resolved = resolve(field), resolved.type == COLYSEUS_FIELD_STRING else {
            return nil
        }

        if colyseus_vtable_is_dynamic(instance.pointee.__vtable) {
            let dynamic = UnsafeMutableRawPointer(instance)
                .assumingMemoryBound(to: colyseus_dynamic_schema_t.self)
            guard let cell = colyseus_dynamic_schema_get(dynamic, resolved.index),
                  cell.pointee.type == COLYSEUS_FIELD_STRING
            else { return nil }
            return String(nullableCString: cell.pointee.data.str)
        }

        let slot = UnsafeRawPointer(instance)
            .advanced(by: Int(resolved.offset))
            .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        return String(nullableCString: slot.pointee)
    }

    /// The child instance, collection or map behind a `ref`/`array`/`map` field.
    public func child(_ field: String) -> UnsafeMutableRawPointer? {
        guard let resolved = resolve(field) else { return nil }

        if colyseus_vtable_is_dynamic(instance.pointee.__vtable) {
            let dynamic = UnsafeMutableRawPointer(instance)
                .assumingMemoryBound(to: colyseus_dynamic_schema_t.self)
            return colyseus_dynamic_schema_get(dynamic, resolved.index)?.pointee.data.ptr
        }

        return UnsafeRawPointer(instance)
            .advanced(by: Int(resolved.offset))
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            .pointee
    }

    // MARK: - Writing
    //
    // Only meaningful on instances you own — an input handle's data, or a
    // prediction mirror. Writing to decoded state is overwritten by the next
    // patch.

    public func set(_ field: String, to value: Double) {
        guard let resolved = resolve(field) else { return }
        colyseus_schema_write_scalar(instance, resolved.type, resolved.offset, resolved.index, resolved.name, value)
    }

    public func set(_ field: String, to value: Bool) {
        set(field, to: value ? 1 : 0)
    }

    // MARK: - Shape

    /// Field names in declaration order.
    public var fieldNames: [String] {
        guard let vtable = instance.pointee.__vtable else { return [] }
        return (0 ..< colyseus_vtable_field_count(vtable)).compactMap { index in
            var reference = colyseus_field_ref_t()
            guard colyseus_vtable_field_at(vtable, index, &reference) else { return nil }
            return String(nullableCString: reference.name)
        }
    }

    public func type(of field: String) -> SchemaFieldType? {
        resolve(field).flatMap { SchemaFieldType($0.type) }
    }

    public func has(_ field: String) -> Bool { resolve(field) != nil }

    private func resolve(_ field: String) -> colyseus_field_ref_t? {
        guard let vtable = instance.pointee.__vtable else { return nil }
        var reference = colyseus_field_ref_t()
        let found = field.withCString { colyseus_vtable_find_field(vtable, $0, &reference) }
        return found ? reference : nil
    }
}
