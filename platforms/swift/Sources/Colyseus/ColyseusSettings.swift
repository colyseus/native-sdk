import CColyseus
import Foundation

/// Wraps `colyseus_settings_t` with a Swift-friendly interface.
public final class ColyseusSettings {

    let raw: UnsafeMutablePointer<colyseus_settings_t>

    public init() {
        guard let ptr = colyseus_settings_create() else {
            fatalError("colyseus_settings_create returned nil")
        }
        raw = ptr
    }

    deinit {
        colyseus_settings_free(raw)
    }

    public var address: String {
        get { raw.pointee.server_address.map { String(cString: $0) } ?? "localhost" }
        set { colyseus_settings_set_address(raw, newValue) }
    }

    public var port: String {
        get { raw.pointee.server_port.map { String(cString: $0) } ?? "2567" }
        set { colyseus_settings_set_port(raw, newValue) }
    }

    public var secure: Bool {
        get { raw.pointee.use_secure_protocol }
        set { colyseus_settings_set_secure(raw, newValue) }
    }

    public var tlsSkipVerification: Bool {
        get { raw.pointee.tls_skip_verification }
        set { raw.pointee.tls_skip_verification = newValue }
    }

    public func setHeader(_ value: String, forKey key: String) {
        colyseus_settings_add_header(raw, key, value)
    }

    public func removeHeader(forKey key: String) {
        colyseus_settings_remove_header(raw, key)
    }

    public func header(forKey key: String) -> String? {
        guard let ptr = colyseus_settings_get_header(raw, key) else { return nil }
        return String(cString: ptr)
    }

    public static func localhost(port: String = "2567", secure: Bool = false) -> ColyseusSettings {
        let s = ColyseusSettings()
        s.address = "localhost"
        s.port = port
        s.secure = secure
        return s
    }

    public static func from(endpoint: String) -> ColyseusSettings {
        let s = ColyseusSettings()
        var rest = endpoint
        if rest.hasPrefix("wss://") {
            s.secure = true
            rest = String(rest.dropFirst(6))
        } else if rest.hasPrefix("ws://") {
            s.secure = false
            rest = String(rest.dropFirst(5))
        }
        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[..<slash])
        }
        if let colon = rest.lastIndex(of: ":") {
            s.address = String(rest[..<colon])
            s.port = String(rest[rest.index(after: colon)...])
        } else {
            s.address = rest
            s.port = s.secure ? "443" : "80"
        }
        return s
    }
}
