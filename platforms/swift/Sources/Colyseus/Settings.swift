import CColyseus
import Foundation

public extension Colyseus {
    /// Where to connect, and how.
    ///
    /// Most apps never build one directly — ``Colyseus/Client/init(endpoint:)``
    /// parses a URL into one.
    final class Settings: @unchecked Sendable {
        let raw: UnsafeMutablePointer<colyseus_settings_t>
        private let lock = NSLock()

        public init() {
            guard let raw = colyseus_settings_create() else {
                fatalError("colyseus_settings_create() returned NULL — out of memory")
            }
            self.raw = raw
        }

        deinit { colyseus_settings_free(raw) }

        /// Host name or IP, without scheme or port.
        public var address: String {
            get { locked { String(nullableCString: raw.pointee.server_address) ?? "" } }
            set { locked { newValue.withCString { colyseus_settings_set_address(raw, $0) } } }
        }

        public var port: String {
            get { locked { String(nullableCString: raw.pointee.server_port) ?? "" } }
            set { locked { newValue.withCString { colyseus_settings_set_port(raw, $0) } } }
        }

        /// `wss://` and `https://` rather than `ws://` and `http://`.
        public var isSecure: Bool {
            get { locked { raw.pointee.use_secure_protocol } }
            set { locked { colyseus_settings_set_secure(raw, newValue) } }
        }

        /// Accept any certificate. For a self-signed development server only —
        /// it disables the check that makes TLS worth having.
        public var skipsTLSVerification: Bool {
            get { locked { raw.pointee.tls_skip_verification } }
            set { locked { raw.pointee.tls_skip_verification = newValue } }
        }

        /// Trust these PEM-encoded roots in addition to the bundled and system
        /// ones. Useful for a private CA.
        public func setCertificateAuthorities(pem: String) {
            locked {
                pem.withCString { colyseus_settings_set_ca_certificates(raw, $0, strlen($0)) }
            }
        }

        /// Headers sent with the matchmaking request and the websocket
        /// handshake — an `Authorization` header, say.
        public subscript(header key: String) -> String? {
            get {
                locked {
                    key.withCString { keyPointer in
                        String(nullableCString: colyseus_settings_get_header(raw, keyPointer))
                    }
                }
            }
            set {
                locked {
                    key.withCString { keyPointer in
                        guard let newValue else {
                            colyseus_settings_remove_header(raw, keyPointer)
                            return
                        }
                        newValue.withCString { colyseus_settings_add_header(raw, keyPointer, $0) }
                    }
                }
            }
        }

        /// Parse `ws://host:port`, `wss://…`, `http://…` or `https://…`.
        /// A missing port defaults to 443 when secure and 80 otherwise.
        public static func parsing(endpoint: String) throws -> Settings {
            guard let components = URLComponents(string: endpoint), let host = components.host else {
                throw Colyseus.Error.invalidEndpoint(endpoint)
            }

            let secure: Bool
            switch components.scheme?.lowercased() {
            case "wss", "https": secure = true
            case "ws", "http", nil: secure = false
            case .some(let scheme): throw Colyseus.Error.unsupportedScheme(scheme)
            }

            let settings = Settings()
            settings.address = host
            settings.isSecure = secure
            settings.port = String(components.port ?? (secure ? 443 : 80))
            return settings
        }

        private func locked<R>(_ body: () -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
}
