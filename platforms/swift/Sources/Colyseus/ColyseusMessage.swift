import CColyseus
import Foundation

public indirect enum MessageValue {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MessageValue])
    case map([String: MessageValue])
}

extension MessageValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nil:            return "nil"
        case .bool(let v):   return String(v)
        case .int(let v):    return String(v)
        case .uint(let v):   return String(v)
        case .float(let v):  return String(v)
        case .string(let v): return v
        case .binary(let v): return "<\(v.count) bytes>"
        case .array(let v):  return String(describing: v)
        case .map(let v):    return String(describing: v)
        }
    }
}

public enum MessageType {
    case `nil`, bool, int, uint, float, string, binary, array, map

    init(_ raw: colyseus_message_type_t) {
        switch raw {
        case COLYSEUS_MESSAGE_TYPE_NIL:   self = .nil
        case COLYSEUS_MESSAGE_TYPE_BOOL:  self = .bool
        case COLYSEUS_MESSAGE_TYPE_INT:   self = .int
        case COLYSEUS_MESSAGE_TYPE_UINT:  self = .uint
        case COLYSEUS_MESSAGE_TYPE_FLOAT: self = .float
        case COLYSEUS_MESSAGE_TYPE_STR:   self = .string
        case COLYSEUS_MESSAGE_TYPE_BIN:   self = .binary
        case COLYSEUS_MESSAGE_TYPE_ARRAY: self = .array
        case COLYSEUS_MESSAGE_TYPE_MAP:   self = .map
        default:                          self = .nil
        }
    }
}

public final class MessageReader {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { colyseus_message_reader_free(raw) }

    public var type: MessageType { MessageType(colyseus_message_reader_get_type(raw)) }
    public var isNil:    Bool { colyseus_message_reader_is_nil(raw) }
    public var isBool:   Bool { colyseus_message_reader_is_bool(raw) }
    public var isInt:    Bool { colyseus_message_reader_is_int(raw) }
    public var isFloat:  Bool { colyseus_message_reader_is_float(raw) }
    public var isString: Bool { colyseus_message_reader_is_str(raw) }
    public var isBinary: Bool { colyseus_message_reader_is_bin(raw) }
    public var isArray:  Bool { colyseus_message_reader_is_array(raw) }
    public var isMap:    Bool { colyseus_message_reader_is_map(raw) }

    public var boolValue:  Bool   { colyseus_message_reader_get_bool(raw) }
    public var intValue:   Int64  { colyseus_message_reader_get_int(raw) }
    public var uintValue:  UInt64 { colyseus_message_reader_get_uint(raw) }
    public var floatValue: Double { colyseus_message_reader_get_float(raw) }

    public var stringValue: String? {
        var len = 0
        guard let ptr = colyseus_message_reader_get_str(raw, &len) else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: ptr, count: len), encoding: .utf8)
    }

    public var binaryValue: Data? {
        var len = 0
        guard let ptr = colyseus_message_reader_get_bin(raw, &len) else { return nil }
        return Data(bytes: ptr, count: len)
    }

    public var arrayCount: Int { colyseus_message_reader_get_array_size(raw) }

    public func arrayElement(at index: Int) -> MessageReader? {
        colyseus_message_reader_get_array_element(raw, index).map { MessageReader($0) }
    }

    public var mapCount: Int { colyseus_message_reader_get_map_size(raw) }

    public func mapValue(forKey key: String) -> MessageReader? {
        colyseus_message_reader_map_get(raw, key).map { MessageReader($0) }
    }

    public func mapString(forKey key: String) -> String? {
        var ptr: UnsafePointer<CChar>? = nil
        var len = 0
        guard colyseus_message_reader_map_get_str(raw, key, &ptr, &len), let p = ptr else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: p, count: len), encoding: .utf8)
    }

    public func mapInt(forKey key: String)   -> Int64?  { var v: Int64  = 0; return colyseus_message_reader_map_get_int(raw, key, &v)   ? v : nil }
    public func mapUInt(forKey key: String)  -> UInt64? { var v: UInt64 = 0; return colyseus_message_reader_map_get_uint(raw, key, &v)  ? v : nil }
    public func mapFloat(forKey key: String) -> Double? { var v: Double = 0; return colyseus_message_reader_map_get_float(raw, key, &v) ? v : nil }
    public func mapBool(forKey key: String)  -> Bool?   { var v = false;     return colyseus_message_reader_map_get_bool(raw, key, &v)  ? v : nil }

    public func decode() -> MessageValue {
        switch type {
        case .nil:    return .nil
        case .bool:   return .bool(boolValue)
        case .int:    return .int(intValue)
        case .uint:   return .uint(uintValue)
        case .float:  return .float(floatValue)
        case .string: return .string(stringValue ?? "")
        case .binary: return .binary(binaryValue ?? Data())
        case .array:
            return .array((0 ..< arrayCount).compactMap { arrayElement(at: $0)?.decode() })
        case .map:
            var result: [String: MessageValue] = [:]
            var iter = colyseus_message_reader_map_iterator(raw)
            while true {
                var kp: OpaquePointer? = nil
                var vp: OpaquePointer? = nil
                guard colyseus_message_map_iterator_next(&iter, &kp, &vp),
                      let k = kp, let v = vp else { break }
                let kr = MessageReader(k)
                let vr = MessageReader(v)
                result[kr.stringValue ?? String(kr.intValue)] = vr.decode()
            }
            return .map(result)
        }
    }
}

public final class MessageBuilder {
    let raw: OpaquePointer
    private init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { colyseus_message_free(raw) }

    public static func map()   -> MessageBuilder { MessageBuilder(colyseus_message_map_create()!)   }
    public static func array() -> MessageBuilder { MessageBuilder(colyseus_message_array_create()!) }
    public static func nil_()  -> MessageBuilder { MessageBuilder(colyseus_message_nil_create()!)   }
    public static func value(_ v: Bool)   -> MessageBuilder { MessageBuilder(colyseus_message_bool_create(v)!)  }
    public static func value(_ v: Int64)  -> MessageBuilder { MessageBuilder(colyseus_message_int_create(v)!)   }
    public static func value(_ v: UInt64) -> MessageBuilder { MessageBuilder(colyseus_message_uint_create(v)!)  }
    public static func value(_ v: Double) -> MessageBuilder { MessageBuilder(colyseus_message_float_create(v)!) }
    public static func value(_ v: String) -> MessageBuilder { MessageBuilder(colyseus_message_str_create(v)!)   }

    @discardableResult public func set(_ k: String, _ v: String)         -> MessageBuilder { colyseus_message_map_put_str(raw, k, v);   return self }
    @discardableResult public func set(_ k: String, _ v: Int64)          -> MessageBuilder { colyseus_message_map_put_int(raw, k, v);   return self }
    @discardableResult public func set(_ k: String, _ v: UInt64)         -> MessageBuilder { colyseus_message_map_put_uint(raw, k, v);  return self }
    @discardableResult public func set(_ k: String, _ v: Double)         -> MessageBuilder { colyseus_message_map_put_float(raw, k, v); return self }
    @discardableResult public func set(_ k: String, _ v: Bool)           -> MessageBuilder { colyseus_message_map_put_bool(raw, k, v);  return self }
    @discardableResult public func setNil(_ k: String)                   -> MessageBuilder { colyseus_message_map_put_nil(raw, k);       return self }
    @discardableResult public func set(_ k: String, _ v: MessageBuilder) -> MessageBuilder { colyseus_message_map_put(raw, k, v.raw);   return self }

    @discardableResult public func push(_ v: String)         -> MessageBuilder { colyseus_message_array_push_str(raw, v);   return self }
    @discardableResult public func push(_ v: Int64)          -> MessageBuilder { colyseus_message_array_push_int(raw, v);   return self }
    @discardableResult public func push(_ v: UInt64)         -> MessageBuilder { colyseus_message_array_push_uint(raw, v);  return self }
    @discardableResult public func push(_ v: Double)         -> MessageBuilder { colyseus_message_array_push_float(raw, v); return self }
    @discardableResult public func push(_ v: Bool)           -> MessageBuilder { colyseus_message_array_push_bool(raw, v);  return self }
    @discardableResult public func pushNil()                 -> MessageBuilder { colyseus_message_array_push_nil(raw);       return self }
    @discardableResult public func push(_ v: MessageBuilder) -> MessageBuilder { colyseus_message_array_push(raw, v.raw);   return self }

    public func encode() -> Data {
        var length = 0
        guard let ptr = colyseus_message_encode(raw, &length) else { return Data() }
        let data = Data(bytes: ptr, count: length)
        colyseus_message_encoded_free(ptr, length)
        return data
    }
}
