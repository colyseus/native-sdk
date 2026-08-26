import CColyseus
import Foundation

public extension Colyseus {
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

    /// Entities you create before the server does.
    ///
    /// Fire, and the projectile exists immediately; when the server's own
    /// arrives it takes over the same entry, so there is no second projectile
    /// and no visible seam.
    final class Spawns: @unchecked Sendable {
        let raw: OpaquePointer
        private let hooks: SpawnHooks
        private let hooksPointer: UnsafeMutableRawPointer
        private weak var parent: Predict?

        init(raw: OpaquePointer, hooks: SpawnHooks, hooksPointer: UnsafeMutableRawPointer, parent: Predict?) {
            self.raw = raw
            self.hooks = hooks
            self.hooksPointer = hooksPointer
            self.parent = parent
        }

        deinit {
            colyseus_spawns_free(raw)
            releasePointer(hooksPointer, as: SpawnHooks.self)
        }

        /// Record an optimistic spawn. The id is stable across the handoff.
        @discardableResult
        public func spawn(_ local: SpawnLocal) -> Int {
            // The store takes ownership here and gives it back through
            // local_free, whether the entry is confirmed, rejected or evicted.
            Int(colyseus_spawns_spawn(raw, retainedPointer(local)))
        }

        /// Drop a prediction that has not been confirmed. A no-op once it has.
        public func cancel(_ id: Int) {
            colyseus_spawns_cancel(raw, Int32(id))
        }

        /// The server said yes but its patch is still in flight — keep this
        /// entry out of the eviction sweep.
        public func accept(_ id: Int) {
            colyseus_spawns_accept(raw, Int32(id))
        }

        public var count: Int { Int(colyseus_spawns_size(raw)) }

        public func isAlive(_ id: Int) -> Bool { colyseus_spawns_alive(raw, Int32(id)) }

        /// Every entry, in the order they were created.
        public var entries: [SpawnEntry] {
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
            field.withCString { colyseus_spawns_value(raw, entry.raw, $0) }
        }

        public func clear() {
            colyseus_spawns_clear(raw)
        }

        /// Stop this store. The Predict stops driving it.
        public func dispose() {
            parent?.release(self)
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
    func spawns<Element: SchemaValue>(
        _ collection: MapSchema<Element>,
        owned: (@Sendable (SchemaView) -> Bool)? = nil,
        spawnTime: (@Sendable (SchemaView) -> Double)? = nil,
        ttlMs: Double = 0,
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

        let store = Colyseus.Spawns(raw: created, hooks: hooks, hooksPointer: pointer, parent: self)

        collection.field.withCString { fieldPointer in
            colyseus_predict_bind_spawns(raw, created, collection.owner.view.instance, fieldPointer, nil)
        }
        adopt(store)
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
