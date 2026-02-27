
import CColyseus
import Foundation

/// Dynamic state as a nested dictionary.
/// Primitive fields -> Swift native types.
/// ref fields -> nested SchemaState.
/// array/map fields -> [Any] or [String: Any].
public typealias SchemaState = [String: Any]

// MARK: - Internal state walker

enum SchemaWalker {

    /// Walk a colyseus_dynamic_schema_t* and return a SchemaState.
    static func walk(_ ptr: UnsafeMutableRawPointer) -> SchemaState {
        let schema = ptr.assumingMemoryBound(to: colyseus_dynamic_schema_t.self)
        var result = SchemaState()

        // Iterate over all fields stored in the hash table.
        typealias Ctx = (result: SchemaState, schema: UnsafeMutablePointer<colyseus_dynamic_schema_t>)
        var ctx: Ctx = (result: [:], schema: schema)

        withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            colyseus_dynamic_schema_foreach(
                schema,
                { idx, name, value, userdata in
                    guard let name = name,
                          let value = value,
                          let userdata = userdata else { return }
                    let key = String(cString: name)
                    let ctx = userdata.assumingMemoryBound(to: Ctx.self)
                    ctx.pointee.result[key] = SchemaWalker.valueToSwift(value)
                },
                ctxPtr
            )
        }
        return ctx.result
    }

    static func valueToSwift(_ v: UnsafeMutablePointer<colyseus_dynamic_value_t>) -> Any {
        switch v.pointee.type {
        case COLYSEUS_FIELD_STRING:
            return v.pointee.data.str.map { String(cString: $0) } as Any? ?? NSNull()
        case COLYSEUS_FIELD_BOOLEAN:
            return v.pointee.data.boolean
        case COLYSEUS_FIELD_INT8:   return Int(v.pointee.data.i8)
        case COLYSEUS_FIELD_UINT8:  return Int(v.pointee.data.u8)
        case COLYSEUS_FIELD_INT16:  return Int(v.pointee.data.i16)
        case COLYSEUS_FIELD_UINT16: return Int(v.pointee.data.u16)
        case COLYSEUS_FIELD_INT32:  return Int(v.pointee.data.i32)
        case COLYSEUS_FIELD_UINT32: return Int(v.pointee.data.u32)
        case COLYSEUS_FIELD_INT64:  return v.pointee.data.i64
        case COLYSEUS_FIELD_UINT64: return v.pointee.data.u64
        case COLYSEUS_FIELD_NUMBER, COLYSEUS_FIELD_FLOAT64:
            return v.pointee.data.num
        case COLYSEUS_FIELD_FLOAT32:
            return Double(v.pointee.data.f32)
        case COLYSEUS_FIELD_REF:
            if let ref = v.pointee.data.ref {
                return walk(UnsafeMutableRawPointer(ref))
            }
            return SchemaState()
        case COLYSEUS_FIELD_ARRAY:
            return decodeArray(v.pointee.data.array)
        case COLYSEUS_FIELD_MAP:
            return decodeMap(v.pointee.data.map)
        default:
            return NSNull()
        }
    }

    private static func decodeArray(_ arr: UnsafeMutablePointer<colyseus_array_schema_t>?) -> [Any] {
        guard let arr = arr else { return [] }
        var result = [Any]()
        colyseus_array_schema_foreach(
            arr,
            { _, value, userdata in
                guard let value = value, let userdata = userdata else { return }
                let list = userdata.assumingMemoryBound(to: [Any].self)
                if arr.pointee.has_schema_child {
                    list.pointee.append(SchemaWalker.walk(value))
                } else {
                    list.pointee.append(SchemaWalker.primitiveFromPtr(value, arr.pointee.child_primitive_type))
                }
            },
            &result
        )
        return result
    }

    private static func decodeMap(_ map: UnsafeMutablePointer<colyseus_map_schema_t>?) -> SchemaState {
        guard let map = map else { return [:] }
        var result = SchemaState()
        colyseus_map_schema_foreach(
            map,
            { key, value, userdata in
                guard let key = key, let value = value, let userdata = userdata else { return }
                let dict = userdata.assumingMemoryBound(to: SchemaState.self)
                let k = String(cString: key)
                if map.pointee.has_schema_child {
                    dict.pointee[k] = SchemaWalker.walk(value)
                } else {
                    dict.pointee[k] = SchemaWalker.primitiveFromPtr(value, map.pointee.child_primitive_type)
                }
            },
            &result
        )
        return result
    }

    // Decode a raw void* primitive value using the type string stored in the collection.
    private static func primitiveFromPtr(_ ptr: UnsafeMutableRawPointer, _ typeStr: UnsafePointer<CChar>?) -> Any {
        let t = typeStr.map { String(cString: $0) } ?? "number"
        switch t {
        case "string":  return String(cString: ptr.assumingMemoryBound(to: CChar.self))
        case "boolean": return ptr.load(as: Bool.self)
        case "int8":    return Int(ptr.load(as: Int8.self))
        case "uint8":   return Int(ptr.load(as: UInt8.self))
        case "int16":   return Int(ptr.load(as: Int16.self))
        case "uint16":  return Int(ptr.load(as: UInt16.self))
        case "int32":   return Int(ptr.load(as: Int32.self))
        case "uint32":  return Int(ptr.load(as: UInt32.self))
        case "int64":   return ptr.load(as: Int64.self)
        case "uint64":  return ptr.load(as: UInt64.self)
        case "float32": return Double(ptr.load(as: Float.self))
        default:        return ptr.load(as: Double.self)
        }
    }
}
