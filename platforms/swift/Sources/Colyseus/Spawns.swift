import CColyseus
import Foundation

// A plain extension, not a `public` one: `open` conflicts with an extension
// that already declares its members public, and SpawnLocal exists to be
// subclassed from the app's module.
extension Colyseus {
    /// A predicted local body, before the server has one of its own.
    ///
    /// Subclass it with whatever your projectile needs, and the store will
    /// step it, hand it back for drawing, and drop it when the server's
    /// version arrives.
    open class SpawnLocal: @unchecked Sendable {
        public init() {}

        /// Advance by `dt` seconds. The same motion the server integrates.
        open func step(dt: Double) {}

        /// A named field, so a pending spawn draws through the same call as a
        /// confirmed one.
        open func value(_ field: String) -> Double { .nan }
    }
}

public extension Colyseus {
    /// One entry in a spawn store — a predicted local, an authoritative
    /// instance, or both while the handoff completes.
    struct SpawnEntry: @unchecked Sendable {
        let raw: UnsafePointer<colyseus_spawn_entry_t>

        /// Stable across the handoff, so a projectile keeps its identity when
        /// the server's version takes over.
        public var id: Int { Int(raw.pointee.id) }

        /// Has the server acknowledged this one?
        public var isConfirmed: Bool { raw.pointee.confirmed }

        /// The authoritative instance, once there is one.
        public var server: SchemaView? { SchemaView(raw.pointee.server) }

        /// The predicted local, while there is one.
        public var local: SpawnLocal? { borrowObject(raw.pointee.local, as: SpawnLocal.self) }

        /// How far ahead of the server this client fired, in milliseconds.
        ///
        /// Measured per spawn, not assumed: it is what lets a confirmed
        /// projectile keep flying the shooter's timeline instead of snapping
        /// back by lead × velocity.
        public var leadMs: Double { raw.pointee.lead_ms }
    }

    /// How a CONFIRMED spawn keeps moving between snapshots.
    ///
    /// Without this, a confirmed entity reads its last decoded position, which
    /// is a round trip behind where its prediction had already flown it — so
    /// the handoff shows up as the trajectory changing. With it, the store
    /// forwards each entity by the snapshot's age plus the lead it measured
    /// for that spawn, and an owned projectile keeps flying the shooter's
    /// timeline through the handoff.
    struct SpawnReckon: Sendable {
        /// The numeric fields the step reads and writes.
        public var fields: [String]
        /// Decay time constant, in milliseconds. 0 is raw projection, which is
        /// right for a deterministic constant-velocity spawn — smoothing there
        /// only adds lag.
        public var smoothMs: Double
        /// Integration granularity. 0 takes 16 ms.
        public var substepMs: Double
        /// The same motion the server integrates.
        public var step: @Sendable (SchemaView, Double, Double) -> Void

        public init(
            fields: [String],
            smoothMs: Double = 0,
            substepMs: Double = 0,
            step: @escaping @Sendable (SchemaView, Double, Double) -> Void
        ) {
            self.fields = fields
            self.smoothMs = smoothMs
            self.substepMs = substepMs
            self.step = step
        }
    }

    /// Entities you create before the server does.
    ///
    /// Fire, and the projectile exists immediately; when the server's own
    /// arrives it takes over the same entry, so there is no second projectile
    /// and no visible seam.
    final class Spawns: @unchecked Sendable {
        let raw: OpaquePointer
        private let hooks: SpawnHooks
        private let hooksPointer: UnsafeMutableRawPointer

        /// Held strongly: the store is driven by the Predict's tick.
        private let predict: Predict
        /// A patch can arrive in the same pump that disposed this store.
        private var isDisposed: Bool { lock.withLock { disposed } }
        private var disposed = false
        private let lock = NSLock()

        init(raw: OpaquePointer, hooks: SpawnHooks, hooksPointer: UnsafeMutableRawPointer, predict: Predict) {
            self.raw = raw
            self.hooks = hooks
            self.hooksPointer = hooksPointer
            self.predict = predict
        }

        deinit { dispose() }

        /// Record an optimistic spawn. The id is stable across the handoff.
        @discardableResult
        public func spawn(_ local: SpawnLocal) -> Int {
            guard !isDisposed else { return 0 }
            // The store takes ownership here and gives it back through
            // local_free, whether the entry is confirmed, rejected or evicted.
            return Int(colyseus_spawns_spawn(raw, retainedPointer(local)))
        }

        /// Drop a prediction that has not been confirmed. A no-op once it has.
        public func cancel(_ id: Int) {
            guard !isDisposed else { return }
            colyseus_spawns_cancel(raw, Int32(id))
        }

        /// The server said yes but its patch is still in flight — keep this
        /// entry out of the eviction sweep.
        public func accept(_ id: Int) {
            guard !isDisposed else { return }
            colyseus_spawns_accept(raw, Int32(id))
        }

        public var count: Int { isDisposed ? 0 : Int(colyseus_spawns_size(raw)) }

        public func isAlive(_ id: Int) -> Bool {
            !isDisposed && colyseus_spawns_alive(raw, Int32(id))
        }

        /// Every entry, in the order they were created.
        public var entries: [SpawnEntry] {
            guard !isDisposed else { return [] }
            var collected: [SpawnEntry] = []
            var cursor = colyseus_spawns_first(raw)
            while let entry = cursor {
                collected.append(SpawnEntry(raw: entry))
                cursor = colyseus_spawns_next(raw, entry)
            }
            return collected
        }

        /// Where to draw an entry, whichever side of the handoff it is on:
        /// the prediction while pending, the server's instance after.
        public func value(_ entry: SpawnEntry, _ field: String) -> Double {
            guard !isDisposed else { return .nan }
            return field.withCString { colyseus_spawns_value(raw, entry.raw, $0) }
        }

        public func clear() {
            guard !isDisposed else { return }
            colyseus_spawns_clear(raw)
        }

        /// Stop this store and let the Predict go. Safe to call twice, and
        /// called for you when the last reference goes away.
        public func dispose() {
            lock.lock()
            let alreadyGone = disposed
            disposed = true
            lock.unlock()
            guard !alreadyGone else { return }

            colyseus_spawns_free(raw)
            releasePointer(hooksPointer, as: SpawnHooks.self)
        }
    }
}

public extension Colyseus.Predict {
    /// Open a spawn store over a collection, and wire the collection's adds
    /// and removes into it.
    ///
    /// - Parameters:
    ///   - owned: which arriving entities are this client's to correlate with
    ///     a pending prediction. Everything is correlatable when omitted.
    ///   - spawnTime: the server-clock instant an entity was created. Supplying
    ///     it turns on the measured input lead.
    ///   - ttlMs: how long an unmatched prediction survives before it is
    ///     dropped as a mispredict. 0 takes twice the round trip, floored at
    ///     600 ms.
    ///   - reckon: how a confirmed entity keeps moving between snapshots.
    ///     Omit it and the handoff is visible: a confirmed entity reads the
    ///     last position the server sent, which is a round trip behind the
    ///     prediction it is replacing.
    func spawns<Element: SchemaValue>(
        _ collection: MapSchema<Element>,
        owned: (@Sendable (SchemaView) -> Bool)? = nil,
        spawnTime: (@Sendable (SchemaView) -> Double)? = nil,
        ttlMs: Double = 0,
        reckon: Colyseus.SpawnReckon? = nil,
        onReject: (@Sendable (Colyseus.SpawnLocal?, Int) -> Void)? = nil
    ) -> Colyseus.Spawns? {
        let hooks = SpawnHooks(owned: owned, spawnTime: spawnTime, onReject: onReject)
        let pointer = retainedPointer(hooks)

        var options = colyseus_spawns_options_t()
        options.ttl_ms = ttlMs
        options.userdata = pointer
        options.has_spawn_time = spawnTime != nil

        if owned != nil {
            options.owned = { server, userdata in
                guard let view = SchemaView(server),
                      let hooks = borrowObject(userdata, as: SpawnHooks.self)
                else { return false }
                return hooks.owned?(view) ?? true
            }
        }

        if spawnTime != nil {
            options.spawn_time = { server, userdata in
                guard let view = SchemaView(server),
                      let hooks = borrowObject(userdata, as: SpawnHooks.self)
                else { return 0 }
                return hooks.spawnTime?(view) ?? 0
            }
        }

        options.step = { local, dt, _ in
            borrowObject(local, as: Colyseus.SpawnLocal.self)?.step(dt: dt)
        }

        options.local_read = { local, field, _ in
            guard let object = borrowObject(local, as: Colyseus.SpawnLocal.self),
                  let field = String(nullableCString: field)
            else { return .nan }
            return object.value(field)
        }

        if onReject != nil {
            options.on_reject = { local, id, userdata in
                borrowObject(userdata, as: SpawnHooks.self)?
                    .onReject?(borrowObject(local, as: Colyseus.SpawnLocal.self), Int(id))
            }
        }

        // The store owns each local once it takes it: this balances the retain
        // spawn() took, whether the entry was confirmed, rejected or evicted.
        options.local_free = { local in
            releasePointer(local, as: Colyseus.SpawnLocal.self)
        }

        guard let created = colyseus_spawns_create(&options, clock) else {
            releasePointer(pointer, as: SpawnHooks.self)
            return nil
        }

        let store = Colyseus.Spawns(raw: created, hooks: hooks, hooksPointer: pointer, predict: self)

        collection.field.withCString { collectionPointer in
            guard let reckon else {
                colyseus_predict_bind_spawns(
                    raw, created, collection.owner.view.instance, collectionPointer, nil
                )
                return
            }

            // The step is called for the store's whole life and never handed
            // back, so the Predict keeps the closure alive.
            let box = ReckonBox(reckon.step)
            retain(box)

            withCStrings(reckon.fields) { fieldPointers in
                var borrowed = fieldPointers
                borrowed.withUnsafeMutableBufferPointer { buffer in
                    var descriptor = colyseus_spawns_reckon_t()
                    // NULL: each entry reckons with its own vtable, the only
                    // option for a reflection-built schema.
                    descriptor.entry_vtable = nil
                    descriptor.fields = UnsafePointer(buffer.baseAddress)
                    descriptor.field_count = Int32(reckon.fields.count)
                    descriptor.smooth_ms = reckon.smoothMs
                    descriptor.substep_ms = reckon.substepMs
                    descriptor.userdata = retainedPointer(box)
                    descriptor.step = { state, dt, elapsedMs, userdata in
                        guard let state, let box = borrowObject(userdata, as: ReckonBox.self) else { return }
                        box.body(SchemaView(state), dt, elapsedMs)
                    }

                    // The core copies the descriptor and strdups the names.
                    colyseus_predict_bind_spawns(
                        raw, created, collection.owner.view.instance, collectionPointer, &descriptor
                    )
                }
            }
        }
        return store
    }
}

final class SpawnHooks: @unchecked Sendable {
    let owned: ((SchemaView) -> Bool)?
    let spawnTime: ((SchemaView) -> Double)?
    let onReject: ((Colyseus.SpawnLocal?, Int) -> Void)?

    init(
        owned: ((SchemaView) -> Bool)?,
        spawnTime: ((SchemaView) -> Double)?,
        onReject: ((Colyseus.SpawnLocal?, Int) -> Void)?
    ) {
        self.owned = owned
        self.spawnTime = spawnTime
        self.onReject = onReject
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
