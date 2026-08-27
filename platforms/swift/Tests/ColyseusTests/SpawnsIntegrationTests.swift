import Foundation
import XCTest
@testable import Colyseus

/// Against the playground's `lab-projectile`: fire now, hand off to the
/// server's projectile without a seam.
final class SpawnsIntegrationTests: XCTestCase {
    private var client: Colyseus.Client!

    override func setUpWithError() throws {
        try Server.requirePlayground()
        Colyseus.autoPump = false
        client = try Colyseus.Client(endpoint: Server.playground)
    }

    override func tearDown() {
        client = nil
        Colyseus.autoPump = true
    }

    func testAPredictedShotIsTakenOverByTheServers() async throws {
        let room = try await client.create("lab-projectile", options: ["private": true], state: ProjectileState.self)
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let input = try XCTUnwrap(room.input())
        let state = try XCTUnwrap(room.state)
        let me = try XCTUnwrap(state.players[sessionId])

        let store = try XCTUnwrap(predict.spawns(
            state.projectiles,
            owned: { $0.string("owner") == sessionId },
            spawnTime: { $0["bornMs"] },
            // Without this a confirmed entity reads its last decoded
            // snapshot, a round trip behind where the prediction had flown
            // it, and the handoff shows up as the trajectory changing.
            reckon: .init(fields: ["x", "y"]) { projectile, dt, _ in
                var body = PlaygroundSim.projectile(view: projectile)
                PlaygroundSim.stepProjectile(&body, dt: dt)
                PlaygroundSim.write(body, to: projectile)
            }
        ))
        defer { store.dispose() }

        let reconciler = try XCTUnwrap(predict.reconciler(
            truth: me, input: input, fields: ["x", "y", "vx", "vy"], smoothMs: 65
        ) { ctx, state, command in
            PlaygroundSim.stepEntity(state, command, dt: ctx.dt)
        })
        defer { reconciler.dispose() }

        // Fire once, aiming along +x from wherever the player is.
        let originX = reconciler.value("x")
        let originY = reconciler.value("y")
        let id = store.spawn(LocalProjectile(
            x: originX, y: originY, vx: PlaygroundSim.projectileSpeed, vy: 0
        ))

        let pending = try XCTUnwrap(store.entries.first { $0.id == id })
        XCTAssertFalse(pending.isConfirmed)
        XCTAssertNotNil(pending.local)
        XCTAssertNil(pending.server)
        XCTAssertEqual(store.value(pending, "x"), originX, accuracy: 1e-9)

        // Tell the server to fire the same shot.
        fire(room: room, predict: predict, input: input, aimX: originX + 20, aimY: originY, seconds: 1.5)

        let confirmed = try XCTUnwrap(
            store.entries.first { $0.id == id },
            "the entry was evicted before the server's projectile arrived"
        )
        XCTAssertTrue(confirmed.isConfirmed, "the handoff never happened")
        XCTAssertNotNil(confirmed.server)

        // The same entry, still the same id — that is what makes the handoff
        // seamless rather than a second projectile appearing.
        XCTAssertEqual(confirmed.id, id)

        // Measured, not assumed: how far ahead of the server this client fired.
        XCTAssertGreaterThan(confirmed.leadMs, 0)
        XCTAssertLessThan(confirmed.leadMs, 2000)

        // One render path across the handoff.
        XCTAssertFalse(store.value(confirmed, "x").isNaN)

        // And the handoff is seamless: a reckoned confirmed entity reads
        // AHEAD of its last decoded snapshot, by the snapshot's age plus the
        // lead measured for this spawn. Reading level with the raw field is
        // the symptom of the reckon descriptor never reaching the store —
        // which is what made the trajectory visibly change on acknowledgement.
        let server = try XCTUnwrap(confirmed.server)
        let forwarded = store.value(confirmed, "x") - server["x"]
        XCTAssertGreaterThan(
            abs(forwarded), 1e-6,
            "the confirmed entry read its raw snapshot rather than being forwarded"
        )
    }

    func testAnUnmatchedPredictionIsEvicted() async throws {
        let room = try await client.create("lab-projectile", options: ["private": true], state: ProjectileState.self)
        defer { room.leave() }
        waitPumping("own player") { room.state?.players[room.sessionId ?? ""] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let rejected = Counter()
        let store = try XCTUnwrap(predict.spawns(
            room.state!.projectiles,
            owned: { _ in false },
            ttlMs: 300,
            onReject: { _, _ in rejected.increment() }
        ))
        defer { store.dispose() }

        // A shot the server is never told about: nothing will ever correlate
        // with it, so the TTL has to clean it up.
        let id = store.spawn(LocalProjectile(x: 10, y: 10, vx: 1, vy: 0))
        XCTAssertTrue(store.isAlive(id))

        // Eviction rides on predict.tick(), not on pump(): pump releases
        // traffic, tick drives the prediction stack. A frame loop needs both.
        let dropped = tickUntil(room: room, predict: predict, seconds: 3) { !store.isAlive(id) }
        XCTAssertTrue(dropped, "the mispredict was never dropped")
        XCTAssertEqual(rejected.value, 1)
    }

    func testCancellingDropsAPendingSpawn() async throws {
        let room = try await client.create("lab-projectile", options: ["private": true], state: ProjectileState.self)
        defer { room.leave() }
        waitPumping("own player") { room.state?.players[room.sessionId ?? ""] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let store = try XCTUnwrap(predict.spawns(room.state!.projectiles, owned: { _ in false }))
        defer { store.dispose() }

        let id = store.spawn(LocalProjectile(x: 1, y: 2, vx: 0, vy: 0))
        XCTAssertTrue(store.isAlive(id))
        store.cancel(id)
        XCTAssertFalse(store.isAlive(id))
    }

    // MARK: -

    /// Pump and tick until `condition` holds. Some of what the prediction
    /// stack does — TTL eviction, event settlement — only happens in tick().
    private func tickUntil(
        room: Colyseus.Room<ProjectileState>,
        predict: Colyseus.Predict,
        seconds: TimeInterval,
        until condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Colyseus.pump()
            predict.tick(room.clock.now)
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
        return condition()
    }

    private func fire(
        room: Colyseus.Room<ProjectileState>,
        predict: Colyseus.Predict,
        input: Colyseus.InputHandle,
        aimX: Double,
        aimY: Double,
        seconds: TimeInterval
    ) {
        var fired = false
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Colyseus.pump()
            for _ in 0 ..< predict.tick(room.clock.now) {
                input.data.set("moveX", to: 0)
                input.data.set("moveY", to: 0)
                input.data.set("aimX", to: aimX)
                input.data.set("aimY", to: aimY)
                input.data.set("fire", to: !fired)
                input.send()
                fired = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
    }
}
