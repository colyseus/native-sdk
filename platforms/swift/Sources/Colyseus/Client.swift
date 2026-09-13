import CColyseus
import Foundation

public extension Colyseus {
    /// Connects to a Colyseus server and joins rooms on it.
    ///
    /// ```swift
    /// let client = Colyseus.Client(endpoint: "ws://localhost:2567")
    /// let room = try await client.joinOrCreate("my_room", state: MyRoomState.self)
    /// ```
    final class Client: @unchecked Sendable {
        let raw: UnsafeMutablePointer<colyseus_client_t>
        public let settings: Settings

        /// Plain HTTP against the same server, carrying the auth token.
        public private(set) lazy var http = HTTP(colyseus_client_get_http(raw))

        /// Sign-in, registration and the token they produce.
        public private(set) lazy var auth = Auth(colyseus_client_get_auth(raw), http: http)

        public init(settings: Settings) {
            // The runtime switches the core to polled mode, which only reaches
            // sockets connected after it — so before this client starts one.
            _ = Colyseus.runtime
            self.settings = settings
            guard let raw = colyseus_client_create(settings.raw) else {
                fatalError("colyseus_client_create() returned NULL — out of memory")
            }
            self.raw = raw
        }

        /// `ws://host:port`, `wss://…`, or the `http`/`https` spellings.
        public convenience init(endpoint: String) throws {
            self.init(settings: try Settings.parsing(endpoint: endpoint))
        }

        deinit { colyseus_client_free(raw) }

        // MARK: - Matchmaking

        /// Join a room with space, or create one.
        public func joinOrCreate<State: SchemaRef>(
            _ roomName: String,
            options: MessagePackValue = [:],
            state: State.Type = State.self
        ) async throws -> Room<State> {
            try await matchmake(colyseus_client_join_or_create, roomName, options)
        }

        /// Always create a new room, even if a joinable one exists.
        public func create<State: SchemaRef>(
            _ roomName: String,
            options: MessagePackValue = [:],
            state: State.Type = State.self
        ) async throws -> Room<State> {
            try await matchmake(colyseus_client_create_room, roomName, options)
        }

        /// Join an existing room, failing when there is none.
        public func join<State: SchemaRef>(
            _ roomName: String,
            options: MessagePackValue = [:],
            state: State.Type = State.self
        ) async throws -> Room<State> {
            try await matchmake(colyseus_client_join, roomName, options)
        }

        /// Join one specific room by id.
        public func joinById<State: SchemaRef>(
            _ roomId: String,
            options: MessagePackValue = [:],
            state: State.Type = State.self
        ) async throws -> Room<State> {
            try await matchmake(colyseus_client_join_by_id, roomId, options)
        }

        /// Take back a seat the server is holding, using the token from
        /// ``Colyseus/Room/reconnectionToken``.
        public func reconnect<State: SchemaRef>(
            token: String,
            state: State.Type = State.self
        ) async throws -> Room<State> {
            try await openRoom { userdata in
                token.withCString { tokenPointer in
                    colyseus_client_reconnect(raw, tokenPointer, Self.onRoom, Self.onError, userdata)
                }
            }
        }

        // MARK: - Latency

        /// Round-trip time to one endpoint, or nil when it could not be reached.
        public static func latency(
            of endpoint: String,
            pingCount: Int = 1,
            timeoutMs: Int = 1500
        ) async -> Double? {
            var options = colyseus_latency_options_t()
            options.ping_count = Int32(pingCount)
            options.timeout_ms = Int32(timeoutMs)
            options.use_secure = endpoint.hasPrefix("wss") || endpoint.hasPrefix("https")

            let completion = Completion<Double?>()
            return try? await Colyseus.runtime.perform(completion) {
                endpoint.withCString { endpointPointer in
                    colyseus_get_latency(endpointPointer, &options, { result, userdata in
                        let value = (result?.pointee.ok ?? false) ? result?.pointee.latency_ms : nil
                        consumeObject(userdata, as: Completion<Double?>.self)?.finish(.success(value))
                    }, retainedPointer(completion))
                }
            }
        }

        /// One endpoint and how long it took to answer.
        public struct EndpointLatency: Sendable {
            public let endpoint: String
            public let latencyMs: Double
        }

        /// The endpoint that answered fastest, having pinged them all.
        public static func fastestEndpoint(
            among endpoints: [String],
            pingCount: Int = 1,
            timeoutMs: Int = 1500
        ) async -> EndpointLatency? {
            guard !endpoints.isEmpty else { return nil }

            var options = colyseus_latency_options_t()
            options.ping_count = Int32(pingCount)
            options.timeout_ms = Int32(timeoutMs)
            options.use_secure = endpoints.contains { $0.hasPrefix("wss") || $0.hasPrefix("https") }

            let completion = Completion<EndpointLatency?>()
            return try? await Colyseus.runtime.perform(completion) {
                // The core copies the array and its strings before returning,
                // so borrowing them for the call is enough.
                withCStrings(endpoints) { pointers in
                    var borrowed = pointers
                    colyseus_select_by_latency(&borrowed, endpoints.count, &options, { best, latency, userdata in
                        let fastest = String(nullableCString: best)
                            .map { EndpointLatency(endpoint: $0, latencyMs: latency) }
                        consumeObject(userdata, as: Completion<EndpointLatency?>.self)?.finish(.success(fastest))
                    }, retainedPointer(completion))
                }
            }
        }

        // MARK: - Plumbing

        private typealias MatchmakeCall = @convention(c) (
            UnsafeMutablePointer<colyseus_client_t>?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            colyseus_client_room_callback_t?,
            colyseus_client_error_callback_t?,
            UnsafeMutableRawPointer?
        ) -> Void

        private func matchmake<State: SchemaRef>(
            _ call: MatchmakeCall,
            _ roomName: String,
            _ options: MessagePackValue
        ) async throws -> Room<State> {
            // Matchmaking options ride the HTTP request as JSON, not msgpack.
            let optionsJSON = options.jsonString ?? "{}"

            return try await openRoom { userdata in
                roomName.withCString { namePointer in
                    optionsJSON.withCString { optionsPointer in
                        call(raw, namePointer, optionsPointer, Self.onRoom, Self.onError, userdata)
                    }
                }
            }
        }

        /// Start a matchmaking call, then wait out the JOIN_ROOM handshake.
        private func openRoom<State: SchemaRef>(
            _ start: (UnsafeMutableRawPointer) -> Void
        ) async throws -> Room<State> {
            let completion = Completion<Room<State>>()
            let room = try await Colyseus.runtime.perform(completion) {
                start(retainedPointer(PendingJoin(completion)))
            }
            try await room.waitUntilJoined()
            return room
        }

        /// In polled mode matchmaking answers inside a pump. Either way the
        /// room is built here, before its first frame can be dispatched.
        private static let onRoom: colyseus_client_room_callback_t = { room, userdata in
            guard let pending = consumeObject(userdata, as: PendingJoin.self) else { return }
            if let room {
                pending.opened(room)
            } else {
                pending.failed(Colyseus.Error.matchmaking(code: 0, message: "matchmaking returned no room"))
            }
        }

        private static let onError: colyseus_client_error_callback_t = { code, message, userdata in
            consumeObject(userdata, as: PendingJoin.self)?
                .failed(Colyseus.Error.matchmaking(
                    code: code,
                    message: String(nullableCString: message) ?? "unknown error"
                ))
        }
    }
}

extension MessagePackValue {
    /// Matchmaking options travel as JSON, not msgpack.
    var jsonString: String? {
        guard let object = jsonObject,
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var jsonObject: Any? {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .uint(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .binary: return nil
        case .array(let items): return items.compactMap(\.jsonObject)
        case .map(let entries): return entries.compactMapValues(\.jsonObject)
        }
    }
}
