import CColyseus
import Foundation

public extension Colyseus {
    /// Plain HTTP against the same server, carrying whatever token
    /// ``Colyseus/Auth`` last obtained.
    ///
    /// Paths are relative to the server root: `http.get("/hello")`.
    final class HTTP: @unchecked Sendable {
        private let raw: UnsafeMutablePointer<colyseus_http_t>?

        /// The core's HTTP calls block for the whole request, so they run here
        /// rather than on whatever thread asked.
        private let queue = DispatchQueue(label: "io.colyseus.http", qos: .userInitiated)

        init(_ raw: UnsafeMutablePointer<colyseus_http_t>?) {
            self.raw = raw
        }

        /// The bearer token sent with every request.
        public var token: String? {
            get { raw.flatMap { String(nullableCString: colyseus_http_get_auth_token($0)) } }
            set {
                guard let raw else { return }
                if let newValue {
                    newValue.withCString { colyseus_http_set_auth_token(raw, $0) }
                } else {
                    colyseus_http_set_auth_token(raw, nil)
                }
            }
        }

        public struct Response: Sendable {
            public let status: Int32
            public let body: String

            /// The body parsed as JSON, when it is.
            public var json: MessagePackValue? {
                guard let data = body.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                else { return nil }
                return MessagePackValue(json: object)
            }

            /// Decode the body into a type.
            public func decode<T: Decodable>(_: T.Type = T.self) throws -> T {
                guard let data = body.data(using: .utf8) else {
                    throw Colyseus.Error.decoding("response body is not UTF-8")
                }
                return try JSONDecoder().decode(T.self, from: data)
            }
        }

        @discardableResult
        public func get(_ path: String) async throws -> Response {
            try await request(path, body: nil, call: colyseus_http_get_wrapper)
        }

        @discardableResult
        public func post(_ path: String, json: String? = nil) async throws -> Response {
            try await request(path, body: json ?? "{}", call: colyseus_http_post)
        }

        @discardableResult
        public func put(_ path: String, json: String? = nil) async throws -> Response {
            try await request(path, body: json ?? "{}", call: colyseus_http_put)
        }

        @discardableResult
        public func patch(_ path: String, json: String? = nil) async throws -> Response {
            try await request(path, body: json ?? "{}", call: colyseus_http_patch)
        }

        @discardableResult
        public func delete(_ path: String) async throws -> Response {
            try await request(path, body: nil, call: colyseus_http_delete_wrapper)
        }

        // MARK: -

        private typealias BodyCall = @convention(c) (
            UnsafeMutablePointer<colyseus_http_t>?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            colyseus_http_success_callback_t?,
            colyseus_http_error_callback_t?,
            UnsafeMutableRawPointer?
        ) -> Void

        private func request(_ path: String, body: String?, call: @escaping BodyCall) async throws -> Response {
            guard let handle = raw else {
                throw Colyseus.Error.unavailable("client has been released")
            }
            // The C client owns this pointer and outlives the request; handing
            // it to the worker is the whole point of having one.
            nonisolated(unsafe) let raw = handle

            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let box = OneShot<Response> { continuation.resume(with: $0) }
                    let pointer = retainedPointer(box)

                    withCStrings([path, body]) { strings in
                        call(raw, strings[0], strings[1], { response, userdata in
                            let box = consumeObject(userdata, as: OneShot<Response>.self)
                            guard let response = response?.pointee else {
                                box?.finish(.failure(Colyseus.Error.http(status: 0, body: "")))
                                return
                            }
                            let value = Response(
                                status: response.status_code,
                                body: String(nullableCString: response.body) ?? ""
                            )
                            box?.finish(response.success
                                ? .success(value)
                                : .failure(Colyseus.Error.http(status: value.status, body: value.body)))
                        }, { error, userdata in
                            consumeObject(userdata, as: OneShot<Response>.self)?
                                .finish(.failure(Colyseus.Error.http(
                                    status: error?.pointee.code ?? 0,
                                    body: String(nullableCString: error?.pointee.message) ?? ""
                                )))
                        }, pointer)
                    }
                }
            }
        }
    }
}

/// GET and DELETE take no body, so they have one fewer parameter than the
/// other three. These shims give all five the same shape.
private func colyseus_http_get_wrapper(
    _ http: UnsafeMutablePointer<colyseus_http_t>?,
    _ path: UnsafePointer<CChar>?,
    _ body: UnsafePointer<CChar>?,
    _ onSuccess: colyseus_http_success_callback_t?,
    _ onError: colyseus_http_error_callback_t?,
    _ userdata: UnsafeMutableRawPointer?
) {
    colyseus_http_get(http, path, onSuccess, onError, userdata)
}

private func colyseus_http_delete_wrapper(
    _ http: UnsafeMutablePointer<colyseus_http_t>?,
    _ path: UnsafePointer<CChar>?,
    _ body: UnsafePointer<CChar>?,
    _ onSuccess: colyseus_http_success_callback_t?,
    _ onError: colyseus_http_error_callback_t?,
    _ userdata: UnsafeMutableRawPointer?
) {
    colyseus_http_delete(http, path, onSuccess, onError, userdata)
}

extension MessagePackValue {
    /// Bridge from `JSONSerialization` output.
    init(json: Any) {
        switch json {
        case is NSNull: self = .null
        case let value as String: self = .string(value)
        case let value as NSNumber:
            // `case let value as Bool` cannot come first: JSONSerialization
            // hands back NSNumber, and an NSNumber holding 1 bridges to Bool
            // happily — every 1 in the payload would decode as true. Only the
            // CoreFoundation type tells them apart.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if value.doubleValue == value.doubleValue.rounded(),
                      let exact = Int64(exactly: value.doubleValue) {
                self = .int(exact)
            } else {
                self = .double(value.doubleValue)
            }
        case let value as [Any]: self = .array(value.map(MessagePackValue.init(json:)))
        case let value as [String: Any]: self = .map(value.mapValues(MessagePackValue.init(json:)))
        default: self = .null
        }
    }
}
