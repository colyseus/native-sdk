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

    /// Step from a decoded input instance.
    static func stepEntity(_ entity: SchemaView, _ input: SchemaView, dt: Double) {
        stepEntity(entity, moveX: input["moveX"], moveY: input["moveY"], dt: dt)
    }

    /// Step from a move the caller derived — the bot's, say, which is
    /// computed rather than received and so has no input instance to read.
    static func stepEntity(_ entity: SchemaView, moveX: Double, moveY: Double, dt: Double) {
        var ax = moveX
        var ay = moveY
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

// MARK: - lab-goal

extension PlaygroundSim {
    /// The goal zone: a strip on the right edge, from `src/shared/goal.ts`.
    static let goalZone = (x: arenaWidth - 8, y: arenaHeight / 2 - 9, width: 8.0, height: 18.0)
    static let scoreCooldownTicks = 50.0

    /// The scoring gate, run once per input step on both sides.
    ///
    /// Returns true on the entry EDGE only. Whether the goal is AWARDED is the
    /// server's to decide, which is exactly why the client can predict the
    /// crossing without ever mispredicting it.
    static func stepScoreGate(_ player: SchemaView) -> Bool {
        let ticks = player["scoreTicks"]
        if ticks > 0 {
            player.set("scoreTicks", to: ticks - 1)
            return false
        }

        let x = player["x"], y = player["y"]
        if x >= goalZone.x, y >= goalZone.y, y <= goalZone.y + goalZone.height {
            player.set("scoreTicks", to: scoreCooldownTicks)
            return true
        }
        return false
    }
}

public final class GoalPlayer: SchemaRef {
    public var x: Double { view["x"] }
    public var y: Double { view["y"] }
    public var score: Double { view["score"] }
    public var scoreTicks: Double { view["scoreTicks"] }
}

public final class GoalState: SchemaRef {
    public var players: MapSchema<GoalPlayer> { mapOf("players") }
    public var denyRate: Double { view["denyRate"] }
}

// MARK: - lab-hockey

extension PlaygroundSim {
    static let paddleRadius = 2.2
    static let puckRadius = 1.4
    static let puckFriction = 0.985
    static let puckRestitution = 0.92
    static let puckPushMin = 14.0

    /// The server-driven paddle's session id.
    static let botId = "bot"

    /// Where the bot steers. A decision the server owns, but a pure function
    /// of synced state — which is what makes it predictable, unlike a human.
    static func botInput(bot: SchemaView, puck: SchemaView, botEnabled: Bool) -> (x: Double, y: Double) {
        let chase = botEnabled && puck["y"] < arenaHeight / 2
        let target = chase
            ? (x: puck["x"], y: puck["y"])
            : (x: arenaWidth / 2, y: arenaHeight * 0.2)

        let dx = target.x - bot["x"]
        let dy = target.y - bot["y"]
        return (
            x: dx > 1 ? 1 : (dx < -1 ? -1 : 0),
            y: dy > 1 ? 1 : (dy < -1 ? -1 : 0)
        )
    }

    /// Puck free flight: integrate, bounce off the walls, bleed speed.
    static func stepPuck(_ puck: SchemaView, dt: Double) {
        var vx = puck["vx"] * puckFriction
        var vy = puck["vy"] * puckFriction
        var x = puck["x"] + vx * dt
        var y = puck["y"] + vy * dt

        let minimum = puckRadius
        let maxX = arenaWidth - puckRadius
        let maxY = arenaHeight - puckRadius
        if x < minimum { x = minimum; vx = abs(vx) * puckRestitution }
        else if x > maxX { x = maxX; vx = -abs(vx) * puckRestitution }
        if y < minimum { y = minimum; vy = abs(vy) * puckRestitution }
        else if y > maxY { y = maxY; vy = -abs(vy) * puckRestitution }

        puck.set("x", to: x)
        puck.set("y", to: y)
        puck.set("vx", to: vx)
        puck.set("vy", to: vy)
    }

    /// Paddle-puck contact. Order-dependent: both sides must resolve paddles
    /// in the same order or they compute different worlds.
    @discardableResult
    static func collidePaddlePuck(
        paddle: (x: Double, y: Double, vx: Double, vy: Double),
        puck: SchemaView
    ) -> Bool {
        let dx = puck["x"] - paddle.x
        let dy = puck["y"] - paddle.y
        let radius = paddleRadius + puckRadius
        let squared = dx * dx + dy * dy
        if squared >= radius * radius { return false }

        let root = squared.squareRoot()
        let distance = root == 0 ? 1e-6 : root
        let nx = dx / distance, ny = dy / distance

        var x = paddle.x + nx * radius
        var y = paddle.y + ny * radius
        let along = paddle.vx * nx + paddle.vy * ny
        let speed = along > puckPushMin ? along : puckPushMin
        var vx = nx * speed + paddle.vx * 0.35
        var vy = ny * speed + paddle.vy * 0.35

        let minimum = puckRadius
        let maxX = arenaWidth - puckRadius
        let maxY = arenaHeight - puckRadius
        if x < minimum { x = minimum; vx = abs(vx) * puckRestitution }
        else if x > maxX { x = maxX; vx = -abs(vx) * puckRestitution }
        if y < minimum { y = minimum; vy = abs(vy) * puckRestitution }
        else if y > maxY { y = maxY; vy = -abs(vy) * puckRestitution }

        puck.set("x", to: x)
        puck.set("y", to: y)
        puck.set("vx", to: vx)
        puck.set("vy", to: vy)
        return true
    }

    static func body(_ view: SchemaView) -> (x: Double, y: Double, vx: Double, vy: Double) {
        (x: view["x"], y: view["y"], vx: view["vx"], vy: view["vy"])
    }
}

public final class Puck: SchemaRef {
    public var x: Double { view["x"] }
    public var y: Double { view["y"] }
    public var vx: Double { view["vx"] }
    public var vy: Double { view["vy"] }
}

public final class HockeyState: SchemaRef {
    public var players: MapSchema<MovePlayer> { mapOf("players") }
    public var puck: Puck? { refOf("puck") }
    public var botEnabled: Bool { view.bool("botEnabled") }
}
