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
            try await withRoomContinuation { context, pointer in
                token.withCString { tokenPointer in
                    colyseus_client_reconnect(raw, tokenPointer, Self.onRoom, Self.onError, pointer)
                }
                _ = context
            }
        }

        // MARK: - Latency

        /// Round-trip time to one endpoint, or nil when it could not be reached.
        public static func latency(
            of endpoint: String,
            pingCount: Int = 1,
            timeoutMs: Int = 1500
        ) async -> Double? {
            await withCheckedContinuation { continuation in
                var options = colyseus_latency_options_t()
                options.ping_count = Int32(pingCount)
                options.timeout_ms = Int32(timeoutMs)
                options.use_secure = endpoint.hasPrefix("wss") || endpoint.hasPrefix("https")

                let box = OneShot<Double?> { result in
                    continuation.resume(returning: (try? result.get()).flatMap { $0 })
                }
                endpoint.withCString { endpointPointer in
                    colyseus_get_latency(endpointPointer, &options, { result, userdata in
                        let value = (result?.pointee.ok ?? false) ? result?.pointee.latency_ms : nil
                        consumeObject(userdata, as: OneShot<Double?>.self)?.finish(.success(value))
                    }, retainedPointer(box))
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

            return await withCheckedContinuation { continuation in
                var options = colyseus_latency_options_t()
                options.ping_count = Int32(pingCount)
                options.timeout_ms = Int32(timeoutMs)
                options.use_secure = endpoints.contains { $0.hasPrefix("wss") || $0.hasPrefix("https") }

                let box = OneShot<EndpointLatency?> { result in
                    continuation.resume(returning: (try? result.get()).flatMap { $0 })
                }

                // The core copies the array and its strings before returning,
                // so borrowing them for the call is enough.
                withCStrings(endpoints) { pointers in
                    var borrowed = pointers
                    colyseus_select_by_latency(&borrowed, endpoints.count, &options, { best, latency, userdata in
                        let winner = String(nullableCString: best)
                            .map { EndpointLatency(endpoint: $0, latencyMs: latency) }
                        consumeObject(userdata, as: OneShot<EndpointLatency?>.self)?.finish(.success(winner))
                    }, retainedPointer(box))
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

            return try await withRoomContinuation { _, pointer in
                roomName.withCString { namePointer in
                    optionsJSON.withCString { optionsPointer in
                        call(raw, namePointer, optionsPointer, Self.onRoom, Self.onError, pointer)
                    }
                }
            }
        }

        private func withRoomContinuation<State: SchemaRef>(
            _ start: (Void, UnsafeMutableRawPointer) -> Void
        ) async throws -> Room<State> {
            let handle: RoomHandle = try await withCheckedThrowingContinuation { continuation in
                let box = OneShot<RoomHandle> { continuation.resume(with: $0) }
                start((), retainedPointer(box))
            }

            let room = Room<State>(raw: handle.raw)
            try await room.waitUntilJoined()
            return room
        }

        /// Matchmaking answers on the HTTP worker thread, so both trampolines
        /// hand off through OneShot, which delivers on the callback queue.
        private static let onRoom: colyseus_client_room_callback_t = { room, userdata in
            guard let room else { return }
            consumeObject(userdata, as: OneShot<RoomHandle>.self)?
                .finish(.success(RoomHandle(raw: room)))
        }

        private static let onError: colyseus_client_error_callback_t = { code, message, userdata in
            consumeObject(userdata, as: OneShot<RoomHandle>.self)?
                .finish(.failure(Colyseus.Error.matchmaking(
                    code: code,
                    message: String(nullableCString: message) ?? "unknown error"
                )))
        }
    }
}

/// A raw room pointer on its way from a C callback to the continuation that
/// will wrap it.
struct RoomHandle: @unchecked Sendable {
    let raw: UnsafeMutablePointer<colyseus_room_t>
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
