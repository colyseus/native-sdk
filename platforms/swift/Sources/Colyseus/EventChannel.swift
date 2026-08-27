import CColyseus
import Foundation

public extension Colyseus {
    /// An event you show before the server has agreed to it.
    ///
    /// A goal, a hit, a pickup: waiting a round trip to react makes the game
    /// feel dead, so predict it, and settle when the server rules. The channel
    /// keeps track of what is still unsettled and auto-rejects predictions the
    /// server has since processed past without confirming.
    ///
    /// ```swift
    /// let goals = predict.defineEvent(label: "goal",
    ///     onPredict: { hud.celebrate() },
    ///     onReject: { hud.retract() })
    ///
    /// // inside the reconciler step, on the live pass only
    /// if scored { ctx.predict(goals, key: "\(scoreCount)") }
    ///
    /// room.onMessage("score") { _ in goals.confirm() }
    /// ```
    final class EventChannel: @unchecked Sendable {
        let raw: OpaquePointer
        private let handlers: EventHandlers
        private let handlersPointer: UnsafeMutableRawPointer

        /// Held strongly for the same reason a reconciler holds it: this is
        /// driven by the Predict's tick and must not outlive it.
        private let predict: Predict
        /// A room message can arrive in the same pump that disposed this, so
        /// every entry point checks rather than trusting the caller.
        private var isDisposed: Bool { lock.withLock { disposed } }
        private var disposed = false
        private let lock = NSLock()

        init(
            raw: OpaquePointer,
            handlers: EventHandlers,
            handlersPointer: UnsafeMutableRawPointer,
            predict: Predict
        ) {
            self.raw = raw
            self.handlers = handlers
            self.handlersPointer = handlersPointer
            self.predict = predict
        }

        deinit { dispose() }

        /// Predict from outside the simulation — a button press, a UI action.
        ///
        /// Settles on a wall-clock deadline. For anything the simulation
        /// itself discovers, use ``Colyseus/StepContext/predict(_:key:)``, which
        /// settles on server progress and survives rollback.
        ///
        /// Returns false when the prediction was dropped: one is already
        /// pending under this key, or the cooldown has not elapsed.
        @discardableResult
        public func predict(key: String = "") -> Bool {
            guard !isDisposed else { return false }
            let payload = strdup(key)
            let accepted = key.withCString { colyseus_event_channel_predict(raw, $0, payload) }
            // Only an accepted prediction becomes the channel's to free.
            if !accepted { free(payload) }
            return accepted
        }

        /// The server agreed. Returns how many predictions this settled — 0
        /// means the signal arrived without one, which is the case an app
        /// usually wants to handle differently.
        @discardableResult
        public func confirm(key: String? = nil) -> Int {
            guard !isDisposed else { return 0 }
            return withCStrings([key]) { Int(colyseus_event_channel_confirm(raw, $0[0])) }
        }

        /// The server overruled. Returns how many predictions this retracted.
        @discardableResult
        public func reject(key: String? = nil) -> Int {
            guard !isDisposed else { return 0 }
            return withCStrings([key]) { Int(colyseus_event_channel_reject(raw, $0[0])) }
        }

        /// Is something still waiting on the server? A nil key asks about any.
        public func isPending(key: String? = nil) -> Bool {
            guard !isDisposed else { return false }
            return withCStrings([key]) { colyseus_event_channel_has(raw, $0[0]) }
        }

        public var pendingCount: Int {
            isDisposed ? 0 : Int(colyseus_event_channel_pending_count(raw))
        }

        /// Drop everything pending without confirming or rejecting it.
        public func clear() {
            guard !isDisposed else { return }
            colyseus_event_channel_clear(raw)
        }

        /// Stop this channel and let the Predict go. Safe to call twice, and
        /// called for you when the last reference goes away.
        public func dispose() {
            lock.lock()
            let alreadyGone = disposed
            disposed = true
            lock.unlock()
            guard !alreadyGone else { return }

            colyseus_event_channel_free(raw)
            releasePointer(handlersPointer, as: EventHandlers.self)
        }
    }
}

public extension Colyseus.Predict {
    /// Open an optimistic event channel, driven by this Predict's tick.
    ///
    /// - Parameters:
    ///   - graceTicks: how many server ticks a sim-born prediction waits for
    ///     confirmation before auto-rejecting.
    ///   - ttlMs: how long a UI-born prediction waits. 0 takes twice the round
    ///     trip, floored at 600 ms.
    ///   - cooldownMs: the shortest gap between two `onPredict` fires, for
    ///     feedback that would otherwise stutter.
    func defineEvent(
        label: String = "",
        graceTicks: Int = 10,
        ttlMs: Double = 0,
        cooldownMs: Double = 0,
        onPredict: @escaping @Sendable (String) -> Void = { _ in },
        onConfirm: @escaping @Sendable (String) -> Void = { _ in },
        onReject: @escaping @Sendable (String) -> Void = { _ in },
        onUnpredicted: @escaping @Sendable (String) -> Void = { _ in }
    ) -> Colyseus.EventChannel? {
        _ = label

        let handlers = EventHandlers(
            onPredict: onPredict,
            onConfirm: onConfirm,
            onReject: onReject,
            onUnpredicted: onUnpredicted
        )
        let pointer = retainedPointer(handlers)

        var options = colyseus_event_channel_options_t()
        options.grace_ticks = Int32(graceTicks)
        options.ttl_ms = ttlMs
        options.cooldown_ms = cooldownMs
        options.userdata = pointer

        // The payload is the key, strdup'd so it outlives the call that made
        // the prediction; each settle hands it back and then frees it.
        options.on_predict = { payload, userdata in
            borrowObject(userdata, as: EventHandlers.self)?.onPredict(payloadKey(payload))
        }
        options.on_confirm = { payload, userdata in
            borrowObject(userdata, as: EventHandlers.self)?.onConfirm(payloadKey(payload))
        }
        options.on_reject = { payload, userdata in
            borrowObject(userdata, as: EventHandlers.self)?.onReject(payloadKey(payload))
        }
        options.on_unpredicted = { key, userdata in
            borrowObject(userdata, as: EventHandlers.self)?.onUnpredicted(String(nullableCString: key) ?? "")
        }
        options.payload_free = { free($0) }

        guard let created = colyseus_event_channel_create(&options, clock) else {
            releasePointer(pointer, as: EventHandlers.self)
            return nil
        }

        let channel = Colyseus.EventChannel(
            raw: created, handlers: handlers, handlersPointer: pointer, predict: self
        )
        colyseus_predict_drive_events(raw, created)
        return channel
    }
}

public extension Colyseus.StepContext {
    /// Predict an event the simulation just discovered.
    ///
    /// Fires on the live step only — a rollback replay silently skips it, so
    /// the celebration happens once no matter how many times the input is
    /// re-simulated. Settlement is by server progress, not wall clock.
    func predict(_ channel: Colyseus.EventChannel, key: String = "") {
        // The channel frees this when the entry settles or is dropped — which
        // includes the replay passes that skip the prediction entirely.
        let payload = strdup(key)
        key.withCString { colyseus_step_predict(raw, channel.raw, $0, payload) }
    }
}

/// The key a settle callback reports.
///
/// The C settle hooks are handed the payload, not the key, so the key travels
/// as the payload — copied on the way in, freed by the channel on the way out.
private func payloadKey(_ payload: UnsafeMutableRawPointer?) -> String {
    guard let payload else { return "" }
    return String(cString: payload.assumingMemoryBound(to: CChar.self))
}

final class EventHandlers: @unchecked Sendable {
    let onPredict: (String) -> Void
    let onConfirm: (String) -> Void
    let onReject: (String) -> Void
    let onUnpredicted: (String) -> Void

    init(
        onPredict: @escaping (String) -> Void,
        onConfirm: @escaping (String) -> Void,
        onReject: @escaping (String) -> Void,
        onUnpredicted: @escaping (String) -> Void
    ) {
        self.onPredict = onPredict
        self.onConfirm = onConfirm
        self.onReject = onReject
        self.onUnpredicted = onUnpredicted
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
