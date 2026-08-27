import CColyseus
import Foundation

public extension Colyseus {
    /// The client's input channel for a room that declares `defineInput()`.
    ///
    /// One input is consumed per server tick. Write the fields, call
    /// ``send()``, and the sequence number that comes back is what the
    /// reconciler and the lag-compensation window key off.
    ///
    /// ```swift
    /// let input = room.input()
    /// for _ in 0 ..< predict.tick(room.clock.now) {
    ///     input.data.set("moveX", to: keyboard.x)
    ///     input.send()
    /// }
    /// ```
    ///
    /// The schema comes from the handshake, so nothing has to be generated for
    /// it.
    struct InputHandle: @unchecked Sendable {
        let raw: OpaquePointer

        /// The instance to write this tick's input into. Reused every tick —
        /// whatever you leave in it is what gets sent.
        public var data: SchemaView {
            SchemaView(colyseus_input_handle_data(raw))!
        }

        /// Transmit the current values. Returns the sequence number, or 0 when
        /// the room is not open.
        ///
        /// Always sends while connected, even when nothing changed: the server
        /// consumes exactly one input per tick, and a gap is a stutter.
        @discardableResult
        public func send() -> Int {
            Int(colyseus_input_handle_send(raw))
        }

        /// Start over: the next send is a full snapshot and the sequence
        /// numbering restarts.
        ///
        /// A reconnected session counts inputs from zero, so this belongs in
        /// ``Colyseus/Room/onReconnect(_:)`` alongside resetting whatever
        /// predicts from it.
        public func reset() {
            colyseus_input_handle_reset(raw)
        }

        /// The input that was sent as `seq`, for replaying it.
        ///
        /// The instance behind this is REUSED across calls — read what you
        /// need before asking for another.
        public func at(_ seq: Int) -> SchemaView? {
            SchemaView(colyseus_input_handle_at(raw, Int32(seq)))
        }

        /// When the client rendered the world it stamped onto input `seq` —
        /// the instant a lag-compensated server rewinds to.
        public func reckonTime(at seq: Int) -> Double {
            colyseus_input_handle_reckon_time_at(raw, Int32(seq))
        }

        /// How far behind live the app draws remote entities.
        ///
        /// This must match the interpolation delay actually used, or a
        /// rewinding server rewinds to the wrong instant. A reconciler built
        /// from a ``Colyseus/Predict`` sets it for you.
        public var renderDelay: Double {
            get { colyseus_input_handle_render_delay(raw) }
            nonmutating set { colyseus_input_handle_set_render_delay(raw, newValue) }
        }

        /// Which inputs the server should rewind for — a fire button, say.
        /// Rewinding every input would be expensive and pointless.
        public func allowRewind(_ predicate: @escaping @Sendable (SchemaView) -> Bool) {
            let box = RewindGate { instance in
                guard let view = SchemaView(instance) else { return false }
                return predicate(view)
            }
            // Held for the handle's lifetime: the core calls it per input and
            // there is no unregister.
            RewindGate.keepAlive(box)

            colyseus_input_handle_set_allow_rewind(raw, { instance, userdata in
                borrowObject(userdata, as: RewindGate.self)?.body(instance) ?? false
            }, retainedPointer(box))
        }

        // MARK: - Round-trip state

        /// How many inputs have been sent.
        public var sentCount: Int { Int(colyseus_input_handle_sent_count(raw)) }

        /// The last sequence the server confirmed.
        public var lastProcessed: Int { Int(colyseus_input_handle_last_processed(raw)) }

        /// Inputs applied locally that the server has not confirmed. At 200 ms
        /// on a 20 Hz room this sits around three or four.
        public var pendingCount: Int { Int(colyseus_input_handle_pending_count(raw)) }

        /// How many past inputs are kept for replay.
        public var replayBufferSize: Int { Int(colyseus_input_handle_replay_buffer_size(raw)) }

        /// Bumped by ``reset()``. Anything holding sequence numbers across a
        /// reconnect should notice this changing.
        public var epoch: Int { Int(colyseus_input_handle_epoch(raw)) }

        // MARK: - What the server advertised

        /// Server ticks per second.
        public var tickRate: Int { Int(colyseus_input_handle_tick_rate(raw)) }

        /// State patches per second.
        public var patchRate: Int { Int(colyseus_input_handle_patch_rate(raw)) }

        /// Simulation sub-steps the server runs per tick.
        public var subSteps: Int { Int(colyseus_input_handle_sub_steps(raw)) }
    }

    /// How an input channel behaves.
    struct InputOptions: Sendable {
        /// How many past inputs to keep for replay, in multiples of the
        /// round trip.
        public var historySize: Int = 3

        /// The interpolation delay the app draws remote entities at.
        public var renderDelay: Double = 0

        public init(historySize: Int = 3, renderDelay: Double = 0) {
            self.historySize = historySize
            self.renderDelay = renderDelay
        }
    }
}

public extension Colyseus.Room {
    /// The room's input channel, built on first use.
    ///
    /// Returns nil for a room whose server never calls `defineInput()` — there
    /// is no input schema to build one from.
    func input(_ options: Colyseus.InputOptions = .init()) -> Colyseus.InputHandle? {
        var raw = colyseus_input_options_t()
        raw.unreliable = false
        raw.history_size = Int32(options.historySize)
        raw.render_delay = options.renderDelay

        // A NULL vtable means "build it from the handshake reflection", which
        // is the only path a binding without codegen has.
        guard let handle = colyseus_room_input(self.raw, nil, &raw) else { return nil }
        return Colyseus.InputHandle(raw: handle)
    }
}

/// The rewind predicate is called by the core per input and never
/// unregistered, so it outlives every Swift reference to it.
private final class RewindGate: @unchecked Sendable {
    let body: (UnsafeMutableRawPointer?) -> Bool

    init(_ body: @escaping (UnsafeMutableRawPointer?) -> Bool) {
        self.body = body
    }

    private static let retained = Guarded<[RewindGate]>([])

    static func keepAlive(_ gate: RewindGate) {
        retained.withLock { $0.append(gate) }
    }
}
