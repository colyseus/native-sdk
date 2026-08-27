import Foundation

public extension Colyseus {
    /// Everything the SDK throws.
    enum Error: Swift.Error, LocalizedError, Sendable {
        /// Matchmaking refused, with the server's own code and message —
        /// a full room, an unknown room name, an `onAuth` rejection.
        case matchmaking(code: Int32, message: String)

        /// The room closed while a call was still waiting on it.
        case roomClosed(code: Int32, reason: String)

        /// A `request()` the server's handler deliberately refused with
        /// `ctx.reject(reason)`. The reason arrives as the server authored it,
        /// so a structured one survives instead of being flattened to text.
        case requestRejected(reason: MessagePackValue)

        /// A `request()` whose handler threw, or for which the room had no
        /// handler at all. Rebuilt from the sanitized `{ name, message, code }`
        /// the server sends — never the raw thrown value, so a crash cannot
        /// pose as a deliberate rejection.
        case requestFailed(name: String, message: String, code: MessagePackValue?)

        /// A `request()` that got no reply in time.
        case requestTimedOut(type: String, seconds: TimeInterval)

        /// An HTTP call that came back outside 2xx.
        case http(status: Int32, body: String)

        /// An auth call the server refused.
        case auth(String)

        case invalidEndpoint(String)
        case unsupportedScheme(String)

        /// A payload that did not decode as the type asked for.
        case decoding(String)

        /// The core rejected the call — usually a room used after it closed.
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .matchmaking(let code, let message):
                return "matchmaking failed (\(code)): \(message)"
            case .roomClosed(let code, let reason):
                return reason.isEmpty ? "room closed (\(code))" : "room closed (\(code)): \(reason)"
            case .requestRejected(let reason):
                return "request rejected: \(reason)"
            case .requestFailed(let name, let message, _):
                return "request failed — \(name): \(message)"
            case .requestTimedOut(let type, let seconds):
                return "request \"\(type)\" timed out after \(Int(seconds * 1000))ms"
            case .http(let status, let body):
                return "HTTP \(status): \(body)"
            case .auth(let message):
                return "auth failed: \(message)"
            case .invalidEndpoint(let endpoint):
                return "not a valid endpoint: \(endpoint)"
            case .unsupportedScheme(let scheme):
                return "unsupported scheme '\(scheme)' — use ws, wss, http or https"
            case .decoding(let detail):
                return "could not decode: \(detail)"
            case .unavailable(let detail):
                return detail
            }
        }
    }
}
