import CColyseus
import Foundation

public extension Colyseus {
    /// How one field is smoothed between server snapshots.
    enum PredictMode: Sendable {
        /// Interpolate between the two snapshots either side of render time.
        /// Accurate, and a render delay behind.
        case lerp
        /// Project past the newest snapshot along its velocity. No delay, and
        /// wrong the moment the entity turns.
        case extrapolate
        /// Chase the newest value with an exponential decay. Never overshoots,
        /// always trailing.
        case damped
        /// Forward-simulate the last snapshot through a step function shared
        /// with the server.
        case reckon
        /// Draw the decoded value as it arrives, steps and all.
        case raw

        var asC: colyseus_predict_mode_t {
            switch self {
            case .lerp: return COLYSEUS_PREDICT_LERP
            case .extrapolate: return COLYSEUS_PREDICT_EXTRAPOLATE
            case .damped: return COLYSEUS_PREDICT_DAMPED
            case .reckon: return COLYSEUS_PREDICT_RECKON
            case .raw: return COLYSEUS_PREDICT_RAW
            }
        }
    }

    /// Per-field smoothing settings. Anything left alone takes the reference
    /// default: 100 ms render delay, 50 ms smoothing on damped and
    /// extrapolate, 200 ms extrapolation cap.
    struct PredictOptions: Sendable {
        public var mode: PredictMode
        /// Render-time lag for `lerp`, in milliseconds.
        public var delay: Double = 0
        /// Output-smoothing time constant, in milliseconds — roughly the extra
        /// display lag it buys. Pass a negative number for an explicit zero.
        public var smoothMs: Double = 0
        /// How far past the newest snapshot `extrapolate` may reach.
        public var maxExtrapolate: Double = 0
        /// Snap arrival timestamps to this grid, in milliseconds. 0 is off.
        public var snap: Double = 0
        /// Treat the field as radians and take the shortest arc between samples.
        public var isAngle: Bool = false

        public init(
            mode: PredictMode = .lerp,
            delay: Double = 0,
            smoothMs: Double = 0,
            maxExtrapolate: Double = 0,
            snap: Double = 0,
            isAngle: Bool = false
        ) {
            self.mode = mode
            self.delay = delay
            self.smoothMs = smoothMs
            self.maxExtrapolate = maxExtrapolate
            self.snap = snap
            self.isAngle = isAngle
        }

        var asC: colyseus_predict_field_options_t {
            var options = colyseus_predict_field_options_t()
            options.mode = mode.asC
            options.delay = delay
            options.smooth_ms = smoothMs
            options.max_extrapolate = maxExtrapolate
            options.snap = snap
            options.angle = isAngle
            return options
        }
    }

    /// Smoothing and prediction for one room.
    ///
    /// A Predict owns three jobs that all key off the same frame tick: it
    /// smooths entities you do not control, it hosts the reconciler for the
    /// one you do, and it paces your input sends.
    ///
    /// ```swift
    /// let predict = Colyseus.Predict.get(room)
    /// predict.attachAll(state.players, fields: ["x", "y"], except: room.sessionId)
    ///
    /// // once a frame
    /// for _ in 0 ..< predict.tick(room.clock.now) { input.send() }
    /// let x = predict.value(player, "x")
    /// ```
    final class Predict: @unchecked Sendable {
        let raw: OpaquePointer
        /// The room clock, which the children this Predict creates need too.
        let clock: OpaquePointer?

        /// The room this Predict borrows its callbacks layer from.
        ///
        /// Held strongly, because freeing the room frees that layer: a Predict
        /// that outlived its room would unregister from memory that is gone.
        /// Ownership runs one way — reconciler to Predict to room — so
        /// teardown order follows without anyone having to remember it.
        private let room: AnyObject?

        /// Callbacks the C side holds by pointer for this Predict's lifetime
        /// and never hands back: reckoning steps, which have no detach hook.
        private var retained: [AnyObject] = []
        private let lock = NSLock()

        init(raw: OpaquePointer, clock: OpaquePointer?, room: AnyObject?) {
            self.raw = raw
            self.clock = clock
            self.room = room
        }

        deinit { colyseus_predict_free(raw) }

        /// The Predict for this room: its own callbacks layer, wired to the
        /// room clock and the server's fixed step.
        public static func get<State: SchemaRef>(_ room: Room<State>) -> Predict? {
            guard let raw = colyseus_predict_for_room(room.raw) else { return nil }
            return Predict(raw: raw, clock: room.clock.raw, room: room)
        }

        // MARK: - Attaching

        /// Smooth these fields of one instance.
        @discardableResult
        public func attach(_ instance: SchemaRef, fields: [String: PredictOptions]) -> Bool {
            withFieldConfig(fields) { config in
                colyseus_predict_attach(raw, instance.view.instance, config, Int32(config.count)) == 0
            }
        }

        /// Smooth these fields of one instance, all the same way.
        @discardableResult
        public func attach(
            _ instance: SchemaRef,
            fields: [String],
            options: PredictOptions = .init()
        ) -> Bool {
            attach(instance, fields: Dictionary(uniqueKeysWithValues: fields.map { ($0, options) }))
        }

        /// Smooth every entry of a collection — the ones there now and the
        /// ones that arrive later — and stop when they are removed.
        ///
        /// `except` skips one entry by key, which is how you leave your own
        /// player to the reconciler.
        @discardableResult
        public func attachAll<Element: SchemaValue>(
            _ collection: MapSchema<Element>,
            fields: [String: PredictOptions],
            except key: String? = nil
        ) -> Bool {
            withFieldConfig(fields) { config in
                withCStrings([collection.field, key]) { strings in
                    colyseus_predict_attach_all(
                        raw, collection.owner.view.instance, strings[0],
                        config, Int32(config.count), strings[1], nil
                    ) == 0
                }
            }
        }

        @discardableResult
        public func attachAll<Element: SchemaValue>(
            _ collection: MapSchema<Element>,
            fields: [String],
            options: PredictOptions = .init(),
            except key: String? = nil
        ) -> Bool {
            attachAll(
                collection,
                fields: Dictionary(uniqueKeysWithValues: fields.map { ($0, options) }),
                except: key
            )
        }

        /// Stop smoothing one instance.
        public func detach(_ instance: SchemaRef) {
            colyseus_predict_detach(raw, instance.view.instance)
        }

        // MARK: - Dead reckoning

        /// Forward-simulate every entry of a collection through a step shared
        /// with the server, instead of interpolating its snapshots.
        ///
        /// Where it applies this beats interpolation outright: there is no
        /// render delay, because the client computes what the server is about
        /// to send rather than waiting to be told. Where it does not — an
        /// entity whose next move depends on something only the server knows —
        /// it breaks honestly and visibly.
        ///
        /// The step runs on demand and its result is cached for the frame, so
        /// a loop that ticks without reading ``value(_:_:)`` reckons nothing.
        ///
        /// - Parameters:
        ///   - fields: the numeric fields the step reads and writes.
        ///   - smoothMs: how fast a rebase onto a fresh snapshot eases in.
        ///   - substepMs: integration granularity. 0 takes 16 ms.
        ///   - snap: a rebase further than this cuts instead of gliding — for
        ///     teleports, which are not reckoning failures.
        @discardableResult
        public func attachAllReckon<Element: SchemaValue>(
            _ collection: MapSchema<Element>,
            fields: [String],
            smoothMs: Double = 0,
            substepMs: Double = 0,
            snap: Double = 0,
            step: @escaping @Sendable (SchemaView, Double, Double) -> Void
        ) -> Bool {
            let box = ReckonBox(step)
            retain(box)

            return withCStrings(fields) { fieldPointers in
                var borrowed = fieldPointers
                return borrowed.withUnsafeMutableBufferPointer { buffer in
                    collection.field.withCString { collectionPointer in
                        colyseus_predict_attach_all_reckon(
                            raw,
                            collection.owner.view.instance,
                            collectionPointer,
                            // Each entry reckons with its own vtable, which is
                            // the only option for reflection-built schemas.
                            nil,
                            UnsafePointer(buffer.baseAddress),
                            Int32(fields.count),
                            { state, dt, elapsedMs, userdata in
                                guard let state, let box = borrowObject(userdata, as: ReckonBox.self) else { return }
                                box.body(SchemaView(state), dt, elapsedMs)
                            },
                            smoothMs, substepMs, snap,
                            retainedPointer(box)
                        ) == 0
                    }
                }
            }
        }

        /// Dead-reckon one instance.
        @discardableResult
        public func attachReckon(
            _ instance: SchemaRef,
            fields: [String],
            smoothMs: Double = 0,
            substepMs: Double = 0,
            snap: Double = 0,
            step: @escaping @Sendable (SchemaView, Double, Double) -> Void
        ) -> Bool {
            let box = ReckonBox(step)
            retain(box)

            return withCStrings(fields) { fieldPointers in
                var borrowed = fieldPointers
                return borrowed.withUnsafeMutableBufferPointer { buffer in
                    colyseus_predict_attach_reckon(
                        raw,
                        instance.view.instance,
                        instance.view.instance.pointee.__vtable,
                        UnsafePointer(buffer.baseAddress),
                        Int32(fields.count),
                        { state, dt, elapsedMs, userdata in
                            guard let state, let box = borrowObject(userdata, as: ReckonBox.self) else { return }
                            box.body(SchemaView(state), dt, elapsedMs)
                        },
                        smoothMs, substepMs, snap,
                        retainedPointer(box)
                    ) == 0
                }
            }
        }

        // MARK: - The frame

        /// Advance one render frame, and say how many fixed input steps are due.
        ///
        /// Send exactly one input per returned step and the client stays on the
        /// server's cadence. The count is 0 until a reconciler advertises the
        /// step, and is capped at 5 — a hitch drops the backlog rather than
        /// firing a burst.
        @discardableResult
        public func tick(_ now: Double) -> Int {
            Int(colyseus_predict_tick(raw, now))
        }

        /// What to draw for this field: smoothed, predicted, or the raw
        /// decoded value when the field is not tracked.
        ///
        /// This is the one read a render loop should make — it keeps working
        /// as a field moves between raw, smoothed and reconciled.
        public func value(_ instance: SchemaRef, _ field: String) -> Double {
            field.withCString { colyseus_predict_value(raw, instance.view.instance, $0) }
        }

        /// The raw reckoned value at a given server-time instant — for hit
        /// tests and other game logic, where the smoothing offset would lie.
        public func value(_ instance: SchemaRef, _ field: String, at time: Double) -> Double {
            field.withCString { colyseus_predict_value_at(raw, instance.view.instance, $0, time) }
        }

        // MARK: -

        /// Keep an object alive for this Predict's whole life, for the C
        /// callbacks that are never unregistered.
        func retain(_ object: AnyObject) {
            lock.lock()
            retained.append(object)
            lock.unlock()
        }

        /// The C config is an array of (name, options) — the reference's
        /// per-field map with no map literal to write it in.
        private func withFieldConfig<R>(
            _ fields: [String: PredictOptions],
            _ body: ([colyseus_attach_field_t]) -> R
        ) -> R {
            let names = fields.keys.sorted()
            var options = names.map { fields[$0]!.asC }

            return withCStrings(names) { pointers in
                options.withUnsafeMutableBufferPointer { optionsBuffer in
                    let config = names.indices.map { index in
                        colyseus_attach_field_t(
                            field: pointers[index],
                            opts: optionsBuffer.baseAddress! + index
                        )
                    }
                    return body(config)
                }
            }
        }
    }
}

/// The reckoning step is a C function pointer invoked per substep, so the
/// closure lives in an object userdata can reach. There is no detach hook for
/// it, so the Predict keeps it for its own lifetime.
final class ReckonBox: @unchecked Sendable {
    let body: (SchemaView, Double, Double) -> Void

    init(_ body: @escaping (SchemaView, Double, Double) -> Void) {
        self.body = body
    }
}
