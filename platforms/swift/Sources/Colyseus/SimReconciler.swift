import CColyseus
import Foundation

public extension Colyseus {
    /// One piece of a composite simulation.
    ///
    /// A part is BOUND when it mirrors a decoded instance — the store rebuilds
    /// the mirror from the server on every reconcile — or OPAQUE when it is
    /// your own object and your `adopt` decides how to restore it.
    struct SimPart: @unchecked Sendable {
        let name: String
        let source: SchemaRef?
        let opaque: AnyObject?

        /// A part that mirrors what the server decoded.
        public static func bound(_ name: String, _ instance: SchemaRef) -> SimPart {
            SimPart(name: name, source: instance, opaque: nil)
        }

        /// A part the store never touches. Restore it in `adopt`.
        public static func opaque(_ name: String, _ object: AnyObject) -> SimPart {
            SimPart(name: name, source: nil, opaque: object)
        }
    }

    /// The parts of a composite simulation, during a step.
    struct SimWorld: @unchecked Sendable {
        let raw: OpaquePointer

        /// The live mirror for a bound part.
        public subscript(name: String) -> SchemaView? {
            SchemaView(name.withCString { colyseus_sim_world_part(raw, $0) })
        }

        /// The object behind an opaque part.
        public func opaque<T: AnyObject>(_ name: String, as _: T.Type = T.self) -> T? {
            guard let pointer = name.withCString({ colyseus_sim_world_part(raw, $0) }) else { return nil }
            return borrowObject(pointer, as: T.self)
        }
    }
}

public extension Colyseus.Predict {
    /// Roll several things back together, because one of them hits another.
    ///
    /// A paddle and a puck cannot be reconciled separately: replaying the
    /// paddle without the puck it just struck reproduces a different contact.
    /// A composite reconciler rewinds every part to the server's version and
    /// replays the whole world through one step.
    ///
    /// ```swift
    /// let sim = predict.sim(
    ///     input: input,
    ///     parts: [.bound("paddle", me), .bound("puck", state.puck)],
    ///     smoothMs: 65
    /// ) { ctx, world, command in
    ///     stepPaddle(world["paddle"]!, command, ctx.dt)
    ///     stepPuck(world["puck"]!, ctx.dt)
    ///     collide(world["paddle"]!, world["puck"]!)
    /// }
    /// ```
    ///
    /// Bound parts register into ``value(_:_:)``, so drawing reads
    /// `predict.value(state.puck, "x")` like anything else.
    ///
    /// - Parameter adopt: restores the opaque parts before each replay.
    ///   Required when nothing is bound — otherwise there is no restore point.
    func sim(
        input: Colyseus.InputHandle,
        parts: [Colyseus.SimPart],
        smoothMs: Double = -1,
        snap: Double = 0,
        adopt: (@Sendable (Colyseus.SimWorld) -> Void)? = nil,
        step: @escaping @Sendable (Colyseus.StepContext, Colyseus.SimWorld, SchemaView) -> Void
    ) -> Colyseus.Reconciler? {
        let box = SimBox(step: step, adopt: adopt, parts: parts)
        let pointer = retainedPointer(box)

        let created = withCStrings(parts.map(\.name)) { names -> OpaquePointer? in
            var descriptors = parts.indices.map { index -> colyseus_sim_part_t in
                let part = parts[index]
                var descriptor = colyseus_sim_part_t()
                descriptor.name = names[index]
                if let source = part.source {
                    descriptor.source = source.view.instance
                    descriptor.vtable = source.view.instance.pointee.__vtable
                } else if let opaque = part.opaque {
                    descriptor.opaque = Unmanaged.passUnretained(opaque).toOpaque()
                }
                return descriptor
            }

            return descriptors.withUnsafeMutableBufferPointer { buffer -> OpaquePointer? in
                var options = colyseus_sim_reconciler_options_t()
                options.parts = UnsafePointer(buffer.baseAddress)
                options.part_count = Int32(parts.count)
                options.smooth_ms = smoothMs
                options.snap = snap
                options.userdata = pointer

                if adopt != nil {
                    options.adopt = { world, userdata in
                        guard let world, let box = borrowObject(userdata, as: SimBox.self) else { return }
                        box.adopt?(Colyseus.SimWorld(raw: world))
                    }
                }

                return colyseus_predict_sim_reconciler(raw, input.raw, { ctx, world, command, userdata in
                    guard let ctx, let world, let command,
                          let box = borrowObject(userdata, as: SimBox.self)
                    else { return }
                    box.step(
                        Colyseus.StepContext(raw: ctx),
                        Colyseus.SimWorld(raw: world),
                        SchemaView(UnsafeMutablePointer(mutating: command))
                    )
                }, &options)
            }
        }

        guard let created else {
            releasePointer(pointer, as: SimBox.self)
            return nil
        }

        return Colyseus.Reconciler(raw: created, step: box, stepPointer: pointer, predict: self)
    }
}

/// The composite step and adopt callbacks, plus the parts they were built from
/// — the opaque objects are held unretained by C, so something has to keep
/// them alive.
final class SimBox: @unchecked Sendable {
    let step: (Colyseus.StepContext, Colyseus.SimWorld, SchemaView) -> Void
    let adopt: ((Colyseus.SimWorld) -> Void)?
    let parts: [Colyseus.SimPart]

    init(
        step: @escaping (Colyseus.StepContext, Colyseus.SimWorld, SchemaView) -> Void,
        adopt: ((Colyseus.SimWorld) -> Void)?,
        parts: [Colyseus.SimPart]
    ) {
        self.step = step
        self.adopt = adopt
        self.parts = parts
    }
}
