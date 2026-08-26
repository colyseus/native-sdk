import Colyseus

/// The prediction playground's shared movement step, transliterated.
///
/// The whole point of a reconciler is that this computes exactly what the
/// server computes: matching it operation for operation is what makes the
/// steady-state correction zero, and a steady-state correction of zero is what
/// the tests assert. Keep the order of operations and the constants identical
/// to `src/shared/movement.ts`.
enum PlaygroundSim {
    static let tickHz = 20.0
    static let arenaWidth = 100.0
    static let arenaHeight = 60.0
    static let playerHalf = 1.6
    static let playerAccel = 220.0
    static let playerMaxSpeed = 34.0
    static let playerFriction = 0.72

    /// 1/sqrt(2) to the digit the TypeScript uses, so a diagonal move lands on
    /// the same float.
    static let sqrt1_2 = 0.70710678118654752440

    static func stepEntity(_ entity: SchemaView, _ input: SchemaView, dt: Double) {
        var ax = input["moveX"]
        var ay = input["moveY"]
        if ax != 0, ay != 0 {
            ax *= sqrt1_2
            ay *= sqrt1_2
        }

        var vx = entity["vx"]
        var vy = entity["vy"]

        if ax != 0 || ay != 0 {
            vx += ax * playerAccel * dt
            vy += ay * playerAccel * dt
        } else {
            vx *= playerFriction
            vy *= playerFriction
            if vx > -0.05, vx < 0.05 { vx = 0 }
            if vy > -0.05, vy < 0.05 { vy = 0 }
        }

        let squared = vx * vx + vy * vy
        if squared > playerMaxSpeed * playerMaxSpeed {
            let scale = playerMaxSpeed / squared.squareRoot()
            vx *= scale
            vy *= scale
        }

        var x = entity["x"] + vx * dt
        var y = entity["y"] + vy * dt

        let minX = playerHalf, maxX = arenaWidth - playerHalf
        let minY = playerHalf, maxY = arenaHeight - playerHalf
        if x < minX { x = minX; if vx < 0 { vx = 0 } }
        else if x > maxX { x = maxX; if vx > 0 { vx = 0 } }
        if y < minY { y = minY; if vy < 0 { vy = 0 } }
        else if y > maxY { y = maxY; if vy > 0 { vy = 0 } }

        entity.set("x", to: x)
        entity.set("y", to: y)
        entity.set("vx", to: vx)
        entity.set("vy", to: vy)
    }
}

// The playground's lab-move schema, as `schema-codegen --swift` will emit it.

public final class MovePlayer: SchemaRef {
    public var x: Double { view["x"] }
    public var y: Double { view["y"] }
    public var vx: Double { view["vx"] }
    public var vy: Double { view["vy"] }
    public var hue: Double { view["hue"] }
}

public final class MoveState: SchemaRef {
    public var players: MapSchema<MovePlayer> { mapOf("players") }
}
