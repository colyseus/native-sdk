import CColyseus
import Foundation

/// A `MapSchema` on the decoded state.
///
/// The map is read live from the decoder — nothing is copied — so iterating it
/// twice in one frame is cheap and iterating it across frames is not safe.
///
/// It also remembers which field of which instance it came from, which is what
/// lets ``Colyseus/Callbacks/onAdd(_:_:)`` survive the server replacing the
/// whole collection.
public struct MapSchema<Element: SchemaValue>: Sendable {
    let owner: SchemaRef
    /// The field name on ``owner``. Callback registration keys off this.
    public let field: String

    init(owner: SchemaRef, field: String) {
        self.owner = owner
        self.field = field
    }

    private var raw: UnsafeMutablePointer<colyseus_map_schema_t>? {
        owner.view.child(field)?.assumingMemoryBound(to: colyseus_map_schema_t.self)
    }

    public var count: Int { raw.map { Int($0.pointee.count) } ?? 0 }
    public var isEmpty: Bool { count == 0 }

    /// O(1) — the core keeps the entries in a hash table.
    public subscript(key: String) -> Element? {
        guard let raw else { return nil }
        guard let value = key.withCString({ colyseus_map_schema_get(raw, $0) }) else { return nil }
        return Element._fromSchemaSlot(value, primitive: primitiveType(of: raw))
    }

    public func contains(_ key: String) -> Bool {
        guard let raw else { return false }
        return key.withCString { colyseus_map_schema_contains(raw, $0) }
    }

    public var keys: [String] { entries.map(\.key) }
    public var values: [Element] { entries.map(\.value) }

    /// Every entry, in the core's iteration order.
    public var entries: [(key: String, value: Element)] {
        guard let raw else { return [] }
        let primitive = primitiveType(of: raw)
        return mapSchemaSlots(raw).compactMap { slot in
            Element._fromSchemaSlot(slot.value, primitive: primitive)
                .map { (key: slot.key, value: $0) }
        }
    }

    private func primitiveType(of raw: UnsafeMutablePointer<colyseus_map_schema_t>) -> SchemaFieldType? {
        guard !raw.pointee.has_schema_child else { return nil }
        return String(nullableCString: raw.pointee.child_primitive_type)
            .flatMap { SchemaFieldType(colyseus_field_type_from_string($0)) }
    }
}

/// An `ArraySchema` on the decoded state.
public struct ArraySchema<Element: SchemaValue>: Sendable {
    let owner: SchemaRef
    public let field: String

    init(owner: SchemaRef, field: String) {
        self.owner = owner
        self.field = field
    }

    private var raw: UnsafeMutablePointer<colyseus_array_schema_t>? {
        owner.view.child(field)?.assumingMemoryBound(to: colyseus_array_schema_t.self)
    }

    public var count: Int { raw.map { Int($0.pointee.count) } ?? 0 }
    public var isEmpty: Bool { count == 0 }

    public subscript(index: Int) -> Element? {
        guard let raw, index >= 0, index < Int(raw.pointee.count) else { return nil }
        guard let value = colyseus_array_schema_get(raw, Int32(index)) else { return nil }
        return Element._fromSchemaSlot(value, primitive: primitiveType(of: raw))
    }

    /// Every element, in index order.
    public var values: [Element] {
        guard let raw else { return [] }
        return (0 ..< Int(raw.pointee.count)).compactMap { self[$0] }
    }

    private func primitiveType(of raw: UnsafeMutablePointer<colyseus_array_schema_t>) -> SchemaFieldType? {
        guard !raw.pointee.has_schema_child else { return nil }
        return String(nullableCString: raw.pointee.child_primitive_type)
            .flatMap { SchemaFieldType(colyseus_field_type_from_string($0)) }
    }
}

extension MapSchema: Sequence {
    public func makeIterator() -> Array<(key: String, value: Element)>.Iterator {
        entries.makeIterator()
    }
}

extension ArraySchema: Sequence {
    public func makeIterator() -> Array<Element>.Iterator {
        values.makeIterator()
    }
}

/// The core's map has no ordinal accessor — entries live in a uthash table —
/// so a full walk goes through foreach. Kept non-generic because a C function
/// pointer cannot be formed from a closure that captures a generic parameter.
private func mapSchemaSlots(
    _ raw: UnsafeMutablePointer<colyseus_map_schema_t>
) -> [(key: String, value: UnsafeMutableRawPointer)] {
    var collected: [(key: String, value: UnsafeMutableRawPointer)] = []
    collected.reserveCapacity(Int(raw.pointee.count))

    withUnsafeMutablePointer(to: &collected) { sink in
        colyseus_map_schema_foreach(raw, { key, value, userdata in
            guard let key, let value, let userdata else { return }
            userdata
                .assumingMemoryBound(to: [(key: String, value: UnsafeMutableRawPointer)].self)
                .pointee
                .append((key: String(cString: key), value: value))
        }, UnsafeMutableRawPointer(sink))
    }

    return collected
}
