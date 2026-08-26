import CColyseus
import Foundation

public extension Colyseus {
    /// A joined room.
    ///
    /// `State` is the root schema class `schema-codegen --swift` generated for
    /// this room. Decoding does not depend on it — the core builds its own
    /// picture from the handshake's reflection — so the generated class is a
    /// typed way to read what was decoded, nothing more.
    final class Room<State: SchemaRef>: @unchecked Sendable {
        let raw: UnsafeMutablePointer<colyseus_room_t>
        private let bridge: RoomBridge
        private let bridgePointer: UnsafeMutableRawPointer
        private var isClosed = false
        private let lock = NSLock()

        // MARK: - Identity

        public var id: String? { String(nullableCString: colyseus_room_get_id(raw)) }
        public var sessionId: String? { String(nullableCString: colyseus_room_get_session_id(raw)) }
        public var name: String? { String(nullableCString: colyseus_room_get_name(raw)) }
        public var isConnected: Bool { colyseus_room_is_connected(raw) }

        /// Pass to ``Colyseus/Client/reconnect(token:state:)`` to rejoin this
        /// seat. Nil until the room has joined.
        public var reconnectionToken: String? {
            String(nullableCString: colyseus_room_get_reconnection_token(raw))
        }

        // MARK: - State

        /// The decoded room state, or nil before the first patch arrives.
        public var state: State? {
            SchemaView(colyseus_room_get_state(raw)).map(State.init)
        }

        /// Local, estimated server, and render time, plus the round-trip
        /// figures the estimate is built from.
        public private(set) lazy var clock = RoomClock(colyseus_room_get_clock(raw))

        /// The room's decode-callback layer, built on first use. There is one
        /// per room, shared by everything that watches the state.
        public var callbacks: Callbacks {
            lock.lock()
            defer { lock.unlock() }
            if let existing = _callbacks { return existing }
            let created = Callbacks(colyseus_room_callbacks(raw))
            _callbacks = created
            return created
        }

        private var _callbacks: Callbacks?

        // MARK: - Lifetime

        init(raw: UnsafeMutablePointer<colyseus_room_t>) {
            self.raw = raw
            bridge = RoomBridge()
            bridgePointer = retainedPointer(bridge)
            bridge.install(on: raw, userdata: bridgePointer)
            Colyseus.runtime.roomOpened()
        }

        deinit {
            // The callbacks layer belongs to the C room and dies with it, so
            // Swift-side registrations have to be dropped BEFORE the free —
            // a stored property released afterwards would unregister from
            // memory that is gone.
            _callbacks?.invalidate()

            // Then order matters again: the transport thread can be inside a
            // callback right now, and it reaches the bridge through this
            // pointer. Free the room — which joins the thread — and only then
            // let go of the bridge.
            colyseus_netdelay_unwrap(raw.pointee.transport)
            colyseus_room_free(raw)
            releasePointer(bridgePointer, as: RoomBridge.self)
            Colyseus.runtime.roomClosed()
        }

        /// Matchmaking answers as soon as the connect STARTS, so a room handed
        /// straight back has no session and no state. Every Colyseus SDK
        /// resolves its join on the JOIN_ROOM handshake instead, and this is
        /// where that wait happens.
        ///
        /// It pumps while it waits: at this point the app has no frame loop
        /// yet, and the JOIN frame is sitting in the inbound queue.
        func waitUntilJoined(timeout: TimeInterval = 20) async throws {
            if isConnected { return }

            let outcome = Guarded<Result<Void, Swift.Error>?>(nil)
            let subscriptions = [
                onJoin { outcome.withLock { $0 = $0 ?? .success(()) } },
                onError { code, message in
                    outcome.withLock { $0 = $0 ?? .failure(Colyseus.Error.matchmaking(code: code, message: message)) }
                },
                onLeave { code, reason in
                    outcome.withLock { $0 = $0 ?? .failure(Colyseus.Error.roomClosed(code: code, reason: reason)) }
                },
            ]
            defer { subscriptions.forEach { $0.cancel() } }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                Colyseus.pump()
                if let result = outcome.current { return try result.get() }
                if isConnected { return }
                try await Task.sleep(nanoseconds: 4_000_000)
            }

            throw Colyseus.Error.roomClosed(code: 0, reason: "timed out waiting to join " + (name ?? "the room"))
        }

        /// Leave the room. `consented: false` reports it as a drop, which is
        /// what lets a server's `allowReconnection` hold the seat.
        public func leave(consented: Bool = true) {
            colyseus_room_leave(raw, consented)
        }

        // MARK: - Events

        /// The room finished joining and the first state has arrived.
        @discardableResult
        public func onJoin(_ handler: @escaping @Sendable () -> Void) -> Subscription {
            bridge.join.add { handler() }
        }

        /// A patch was decoded. The state passed in is the same object
        /// ``state`` returns; it is handed over so the common case reads well.
        @discardableResult
        public func onStateChange(_ handler: @escaping @Sendable (State) -> Void) -> Subscription {
            bridge.stateChange.add { [weak self] in
                guard let state = self?.state else { return }
                handler(state)
            }
        }

        /// The server reported an error on this room.
        @discardableResult
        public func onError(_ handler: @escaping @Sendable (Int32, String) -> Void) -> Subscription {
            bridge.error.add { handler($0.code, $0.message) }
        }

        /// The room closed for good. After this the room will not reconnect.
        @discardableResult
        public func onLeave(_ handler: @escaping @Sendable (Int32, String) -> Void) -> Subscription {
            bridge.leave.add { handler($0.code, $0.message) }
        }

        /// The connection dropped and the SDK is about to retry. Prediction
        /// keeps running; nothing is authoritative until ``onReconnect(_:)``.
        @discardableResult
        public func onDrop(_ handler: @escaping @Sendable (Int32, String) -> Void) -> Subscription {
            bridge.drop.add { handler($0.code, $0.message) }
        }

        /// A retry succeeded.
        ///
        /// The reconnected session counts inputs from zero, so anything
        /// holding predicted state has to be reset here or it replays a
        /// backlog that no longer exists.
        @discardableResult
        public func onReconnect(_ handler: @escaping @Sendable () -> Void) -> Subscription {
            bridge.reconnect.add { handler() }
        }

        public var isReconnecting: Bool { colyseus_room_is_reconnecting(raw) }

        /// How hard to try when the connection drops.
        public var reconnection: ReconnectionOptions {
            get {
                var options = colyseus_reconnection_options_t()
                colyseus_room_get_reconnection_options(raw, &options)
                return ReconnectionOptions(options)
            }
            set {
                var options = newValue.asC
                colyseus_room_set_reconnection_options(raw, &options)
            }
        }

        // MARK: - Messages

        /// Handle one message type.
        ///
        /// ```swift
        /// room.onMessage("score") { payload in
        ///     hud.score = payload.string ?? ""
        /// }
        /// ```
        @discardableResult
        public func onMessage(
            _ type: String,
            _ handler: @escaping @Sendable (MessagePackValue) -> Void
        ) -> Subscription {
            bridge.messages.add(for: .string(type), handler)
        }

        /// Handle a numeric message type.
        @discardableResult
        public func onMessage(
            _ type: Int,
            _ handler: @escaping @Sendable (MessagePackValue) -> Void
        ) -> Subscription {
            bridge.messages.add(for: .int(type), handler)
        }

        /// Every message, whatever its type.
        @discardableResult
        public func onMessage(
            _ handler: @escaping @Sendable (MessageType, MessagePackValue) -> Void
        ) -> Subscription {
            bridge.anyMessage.add { handler($0.type, $0.payload) }
        }

        /// Raw `ROOM_DATA_BYTES` traffic — messages the server sent with
        /// `client.sendBytes`, which never went through msgpack.
        @discardableResult
        public func onMessageBytes(
            _ type: String,
            _ handler: @escaping @Sendable (Data) -> Void
        ) -> Subscription {
            bridge.byteMessages.add(for: .string(type), handler)
        }

        public func send(_ type: String, _ payload: MessagePackValue = .null) {
            let encoded = MessagePack.encode(payload)
            encoded.withUnsafeBytes { buffer in
                type.withCString { typePointer in
                    colyseus_room_send_encoded(
                        raw, typePointer,
                        buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count
                    )
                }
            }
        }

        public func send(_ type: Int, _ payload: MessagePackValue = .null) {
            let encoded = MessagePack.encode(payload)
            encoded.withUnsafeBytes { buffer in
                colyseus_room_send_int_encoded(
                    raw, Int32(type),
                    buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count
                )
            }
        }

        /// Send bytes that skip msgpack entirely.
        public func sendBytes(_ type: String, _ data: Data) {
            data.withUnsafeBytes { buffer in
                type.withCString { typePointer in
                    colyseus_room_send_bytes(
                        raw, typePointer,
                        buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count
                    )
                }
            }
        }

        // MARK: - Round trip

        /// Measure the round trip with an explicit ping.
        ///
        /// A room whose server declares `defineInput()` gets round-trip figures
        /// for free through ``clock``; this is for the ones that do not.
        public func ping() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                let box = OneShot<Int> { result in
                    continuation.resume(with: result)
                }
                colyseus_room_ping(raw, { rtt, userdata in
                    consumeObject(userdata, as: OneShot<Int>.self)?.finish(.success(Int(rtt)))
                }, retainedPointer(box))
            }
        }

        // MARK: - Injected latency

        /// Delay this room's traffic, as if the server were further away.
        ///
        /// Both figures are a ROUND TRIP, split evenly across the two
        /// directions — `delayMs: 200` adds 100 ms each way. Jitter is applied
        /// symmetrically and never reorders packets.
        public func setLatency(delayMs: Double, jitterMs: Double = 0) {
            colyseus_netdelay_set(raw, delayMs, jitterMs)
        }

        /// Kill the connection uncleanly, the way a lost network would.
        /// Auto-reconnection takes it from there.
        public func dropConnection() {
            colyseus_netdelay_drop(raw)
        }
    }
}

// MARK: - Message types

public extension Colyseus {
    /// A message's type, as the server addressed it.
    enum MessageType: Sendable, Hashable {
        case string(String)
        case int(Int)

        /// The core keys numeric types as `"i<n>"`, so a string type that
        /// looks like one is indistinguishable from it. Colyseus servers do
        /// not name messages that way.
        init(wireType: String) {
            if wireType.hasPrefix("i"), let number = Int(wireType.dropFirst()) {
                self = .int(number)
            } else {
                self = .string(wireType)
            }
        }
    }

    /// How hard the SDK tries to get back in after a drop.
    struct ReconnectionOptions: Sendable {
        public var isEnabled: Bool
        public var maxRetries: Int
        public var minDelayMs: Int
        public var maxDelayMs: Int
        /// How long a connection must have lasted to count as established.
        public var minUptimeMs: Int
        /// The base of the exponential backoff.
        public var delayMs: Int
        /// Messages buffered while disconnected, sent on reconnect.
        public var maxEnqueuedMessages: Int

        public static var `default`: ReconnectionOptions {
            var options = colyseus_reconnection_options_t()
            colyseus_reconnection_options_init_defaults(&options)
            return ReconnectionOptions(options)
        }

        init(_ raw: colyseus_reconnection_options_t) {
            isEnabled = raw.enabled
            maxRetries = Int(raw.max_retries)
            minDelayMs = Int(raw.min_delay_ms)
            maxDelayMs = Int(raw.max_delay_ms)
            minUptimeMs = Int(raw.min_uptime_ms)
            delayMs = Int(raw.delay_ms)
            maxEnqueuedMessages = Int(raw.max_enqueued_messages)
        }

        var asC: colyseus_reconnection_options_t {
            colyseus_reconnection_options_t(
                enabled: isEnabled,
                max_retries: Int32(maxRetries),
                min_delay_ms: Int32(minDelayMs),
                max_delay_ms: Int32(maxDelayMs),
                min_uptime_ms: Int32(minUptimeMs),
                delay_ms: Int32(delayMs),
                max_enqueued_messages: Int32(maxEnqueuedMessages)
            )
        }
    }
}
