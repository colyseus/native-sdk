import CColyseus
import Foundation

public extension Colyseus {
    /// What the simulation step is told about the step it is running.
    ///
    /// The same values the server's own step context carries — one fixed `dt`
    /// drives both sides, which is what makes the two agree.
    struct StepContext: @unchecked Sendable {
        let raw: UnsafePointer<colyseus_step_ctx_t>

        /// The fixed step, in seconds.
        public var dt: Double { raw.pointee.dt }
        /// The fixed step, in milliseconds.
        public var dtMs: Double { raw.pointee.dt_ms }
        /// The sequence number of the input being applied.
        public var tick: Int { Int(raw.pointee.tick) }
        /// Physics sub-steps per fixed step.
        public var subSteps: Int { Int(raw.pointee.sub_steps) }
        public var subDt: Double { raw.pointee.sub_dt }
        public var subDtMs: Double { raw.pointee.sub_dt_ms }

        /// True while re-simulating an input that already ran.
        ///
        /// Anything that happens once — a sound, a particle, a banner — has to
        /// check this, or it happens again on every rollback.
        public var isReplay: Bool { raw.pointee.is_replay }

        /// The instant this input was stamped with, in server time. What a
        /// lag-compensating server rewinds to.
        public var reckonTime: Double { raw.pointee.reckon_time }

        public var isLagCompActive: Bool { raw.pointee.lag_comp_active }

        /// Freeze a number that a replay could not re-derive — an RNG roll, a
        /// collision verdict measured against a rewound world.
        ///
        /// `compute` runs exactly once, on the live step. Every replay of the
        /// same input gets the frozen answer back without running it again.
        /// Return NaN for "nothing happened this step".
        public func memo(_ key: String = "", _ compute: @escaping () -> Double) -> Double {
            var body = compute
            return withUnsafeMutablePointer(to: &body) { pointer in
                key.withCString { keyPointer in
                    colyseus_step_memo(raw, keyPointer, { userdata in
                        userdata!.assumingMemoryBound(to: (() -> Double).self).pointee()
                    }, UnsafeMutableRawPointer(pointer))
                }
            }
        }

        /// Freeze several numbers under one key.
        ///
        /// A verdict that comes with a position is one derivation, and
        /// splitting it across scalar ``memo(_:_:)`` calls re-runs it once per
        /// component. At most four values.
        public func memo(_ key: String = "", _ compute: @escaping () -> [Double]) -> [Double] {
            var body = compute
            var out = [Double](repeating: 0, count: Int(COLYSEUS_MEMO_VEC_MAX))

            let count = withUnsafeMutablePointer(to: &body) { pointer in
                out.withUnsafeMutableBufferPointer { buffer in
                    key.withCString { keyPointer in
                        colyseus_step_memo_vec(raw, keyPointer, { out, userdata in
                            let values = userdata!.assumingMemoryBound(to: (() -> [Double]).self).pointee()
                            let count = min(values.count, Int(COLYSEUS_MEMO_VEC_MAX))
                            for index in 0 ..< count { out![index] = values[index] }
                            return Int32(count)
                        }, UnsafeMutableRawPointer(pointer), buffer.baseAddress)
                    }
                }
            }

            return Array(out.prefix(Int(count)))
        }
    }

    /// Rollback prediction for the one entity you control.
    ///
    /// Applies your inputs locally the moment you make them, then — when the
    /// server confirms an input — rewinds to what the server said and replays
    /// everything still in flight. When your step matches the server's, the
    /// correction is nothing and the entity never visibly moves.
    final class Reconciler: @unchecked Sendable {
        let raw: OpaquePointer

        /// The Predict that drives this, held strongly. Freeing a Predict
        /// takes the room's callbacks layer with it, so a reconciler must
        /// never be the thing that outlives it.
        private let predict: Predict

        /// The step closure, which the C side reaches through userdata.
        private let step: AnyObject
        private let stepPointer: UnsafeMutableRawPointer
        private var isDisposed: Bool { lock.withLock { disposed } }
        private var disposed = false
        private let lock = NSLock()

        init(raw: OpaquePointer, step: AnyObject, stepPointer: UnsafeMutableRawPointer, predict: Predict) {
            self.raw = raw
            self.step = step
            self.stepPointer = stepPointer
            self.predict = predict
        }

        deinit { dispose() }

        /// The predicted state — the mirror your step mutates.
        ///
        /// Read this for game logic. For drawing, prefer
        /// ``Colyseus/Predict/value(_:_:)``, which adds the decaying
        /// correction so a disagreement eases out instead of snapping.
        ///
        /// Nil on a composite reconciler, which has one mirror per part rather
        /// than a single state — read those through ``world`` instead.
        public var state: SchemaView? {
            isDisposed ? nil : SchemaView(colyseus_reconciler_state(raw))
        }

        /// The parts of a composite reconciler, or nil on a flat one.
        public var world: SimWorld? {
            guard !isDisposed, let raw = colyseus_sim_reconciler_world(raw) else { return nil }
            return SimWorld(raw: raw)
        }

        /// The rendered value of a reconciled field: predicted, interpolated
        /// between the two most recent steps, plus the correction still
        /// decaying.
        public func value(_ field: String) -> Double {
            guard !isDisposed else { return .nan }
            return field.withCString { colyseus_reconciler_value(raw, $0) }
        }

        /// Re-seed from the server and drop everything in flight.
        ///
        /// Belongs in ``Colyseus/Room/onReconnect(_:)``: the reconnected
        /// session numbers its inputs from zero, and a reconciler still
        /// holding the old window replays a backlog that no longer exists.
        public func reset() {
            guard !isDisposed else { return }
            colyseus_reconciler_reset(raw)
        }

        /// Stop reconciling and let the Predict go.
        ///
        /// Safe to call more than once, and called for you when the last
        /// reference goes away.
        public func dispose() {
            lock.lock()
            let alreadyGone = disposed
            disposed = true
            lock.unlock()
            guard !alreadyGone else { return }

            // Frees the C object AND deregisters it from the Predict's tick.
            colyseus_reconciler_free(raw)
            releaseErased(stepPointer)
        }

        // MARK: - Telemetry

        /// Inputs applied locally that the server has not confirmed.
        public var pendingCount: Int { isDisposed ? 0 : Int(colyseus_reconciler_pending_count(raw)) }

        /// The fixed step, in milliseconds.
        public var stepMs: Double { isDisposed ? 0 : colyseus_reconciler_step_ms(raw) }

        /// The last input the server confirmed.
        public var reconcileSeq: Int { isDisposed ? 0 : Int(colyseus_reconciler_reconcile_seq(raw)) }

        /// How far the last correction moved things.
        public var lastCorrectionMagnitude: Double {
            isDisposed ? 0 : colyseus_reconciler_last_correction_mag(raw)
        }

        public func lastCorrection(_ field: String) -> Double {
            guard !isDisposed else { return 0 }
            return field.withCString { colyseus_reconciler_last_correction(raw, $0) }
        }

        /// How far prediction and server have been disagreeing.
        ///
        /// A steady near-zero `ema` means the client is computing exactly what
        /// the server computes. Near-zero is also what a dead simulation
        /// reads, so check it against something that proves the world is still
        /// moving.
        public var drift: Drift {
            guard !isDisposed else { return Drift(ema: 0, peak: 0) }
            return colyseus_reconciler_drift(raw).map { Drift($0.pointee) } ?? Drift(ema: 0, peak: 0)
        }
    }

    /// Prediction error over time.
    struct Drift: Sendable {
        /// Exponentially-weighted mean correction.
        public var ema: Double
        /// The largest correction seen.
        public var peak: Double

        init(ema: Double, peak: Double) {
            self.ema = ema
            self.peak = peak
        }

        init(_ raw: colyseus_drift_t) {
            ema = raw.ema
            peak = raw.peak
        }

        /// A verdict on the numbers, on the same thresholds every other
        /// Colyseus SDK uses.
        public var status: Status {
            var raw = colyseus_drift_t(ema: ema, peak: peak)
            // A negative tolerance takes the float-noise floor, which is the
            // right answer when the client reproduces the server exactly.
            switch colyseus_drift_classify(&raw, -1) {
            case COLYSEUS_DRIFT_MATCHED: return .matched
            case COLYSEUS_DRIFT_JITTER: return .jitter
            default: return .diverging
            }
        }

        public enum Status: Sendable {
            /// The client is reproducing the server's arithmetic.
            case matched
            /// Small disagreements — float noise, a contested touch.
            case jitter
            /// The two simulations are not the same simulation.
            case diverging
        }
    }
}

public extension Colyseus.Predict {
    /// Predict the locally-controlled entity by applying inputs as they are
    /// sent, and reconcile when the server confirms them.
    ///
    /// Built through the Predict rather than standalone, so the input handle's
    /// lag-compensation delay is bound to this Predict's render delay — the
    /// server then rewinds to the instant this client actually displayed.
    ///
    /// ```swift
    /// let reconciler = predict.reconciler(
    ///     truth: me, input: input, fields: ["x", "y", "vx", "vy"], smoothMs: 65
    /// ) { ctx, state, command in
    ///     stepEntity(state, command, ctx.dt)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - truth: the decoded instance the server owns.
    ///   - fields: which numeric fields to reconcile. Empty means every one.
    ///   - smoothMs: how fast a correction eases out. Negative takes the
    ///     server's patch cadence; 0 snaps.
    ///   - snap: a correction bigger than this pops instead of easing — for
    ///     teleports, which are not prediction failures.
    func reconciler(
        truth: SchemaRef,
        input: Colyseus.InputHandle,
        fields: [String] = [],
        smoothMs: Double = -1,
        snap: Double = 0,
        step: @escaping @Sendable (Colyseus.StepContext, SchemaView, SchemaView) -> Void
    ) -> Colyseus.Reconciler? {
        let box = StepBox(step)
        let pointer = retainedPointer(box)

        let trampoline: colyseus_reconciler_step_fn = { ctx, state, command, userdata in
            guard let ctx, let state, let command,
                  let box = borrowObject(userdata, as: StepBox.self)
            else { return }
            box.body(
                Colyseus.StepContext(raw: ctx),
                SchemaView(state),
                SchemaView(UnsafeMutablePointer(mutating: command))
            )
        }

        var options = colyseus_reconciler_options_t()
        options.smooth_ms = smoothMs
        options.snap = snap
        options.field_count = Int32(fields.count)
        options.userdata = pointer

        let created = withCStrings(fields) { fieldPointers -> OpaquePointer? in
            var borrowed = fieldPointers
            return borrowed.withUnsafeMutableBufferPointer { buffer -> OpaquePointer? in
                // An empty list means "every numeric field the schema declares".
                options.fields = fields.isEmpty ? nil : UnsafePointer(buffer.baseAddress)
                return colyseus_predict_reconciler(
                    raw,
                    truth.view.instance,
                    truth.view.instance.pointee.__vtable,
                    input.raw,
                    trampoline,
                    &options
                )
            }
        }

        guard let created else {
            releasePointer(pointer, as: StepBox.self)
            return nil
        }

        return Colyseus.Reconciler(raw: created, step: box, stepPointer: pointer, predict: self)
    }
}

/// The step is a C function pointer called on every live input and again on
/// every replay, so the closure lives in an object userdata can reach.
final class StepBox: @unchecked Sendable {
    let body: (Colyseus.StepContext, SchemaView, SchemaView) -> Void

    init(_ body: @escaping (Colyseus.StepContext, SchemaView, SchemaView) -> Void) {
        self.body = body
    }
}


/// Release a retain taken by `retainedPointer`, whatever the object was.
///
/// The concrete type differs between a flat reconciler and a composite one,
/// and a release is a decrement either way.
func releaseErased(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<AnyObject>.fromOpaque(pointer).release()
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
