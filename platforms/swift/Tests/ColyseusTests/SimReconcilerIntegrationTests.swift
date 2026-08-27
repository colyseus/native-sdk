import Foundation
import XCTest
@testable import Colyseus

/// Against the playground's `lab-hockey`: a paddle and a puck rolled back
/// together, because one hits the other.
final class SimReconcilerIntegrationTests: XCTestCase {
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

    func testTheCompositeSimPredictsTheirContact() async throws {
        let room = try await client.create("lab-hockey", options: ["private": true], state: HockeyState.self)
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own paddle, the puck and the bot") {
            room.state?.players[sessionId] != nil
                && room.state?.puck != nil
                && room.state?.players[PlaygroundSim.botId] != nil
        }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let input = try XCTUnwrap(room.input())
        let state = try XCTUnwrap(room.state)
        let me = try XCTUnwrap(state.players[sessionId])
        let puck = try XCTUnwrap(state.puck)
        let bot = try XCTUnwrap(state.players[PlaygroundSim.botId])

        // Remote paddles are colliders as well as sprites, so they lerp: a
        // constant delay, rather than damped's velocity-dependent one.
        predict.attachAll(state.players, fields: ["x", "y"],
                          options: .init(mode: .lerp, delay: 100), except: sessionId)

        let contacts = Counter()
        let sim = try XCTUnwrap(predict.sim(
            input: input,
            parts: [.bound("paddle", me), .bound("puck", puck), .bound("bot", bot)],
            smoothMs: 65
        ) { ctx, world, command in
            guard let paddle = world["paddle"], let puck = world["puck"], let bot = world["bot"] else { return }

            // The server's order, reproduced: paddles, then the puck, then the
            // contacts. The bot steps from the PRE-step puck, as it does there.
            PlaygroundSim.stepEntity(paddle, command, dt: ctx.dt)

            let botCommand = PlaygroundSim.botInput(bot: bot, puck: puck, botEnabled: state.botEnabled)
            PlaygroundSim.stepEntity(bot, moveX: botCommand.x, moveY: botCommand.y, dt: ctx.dt)

            PlaygroundSim.stepPuck(puck, dt: ctx.dt)

            if PlaygroundSim.collidePaddlePuck(paddle: PlaygroundSim.body(paddle), puck: puck), !ctx.isReplay {
                contacts.increment()
            }
            PlaygroundSim.collidePaddlePuck(paddle: PlaygroundSim.body(bot), puck: puck)
        })
        defer { sim.dispose() }

        let run = chasePuck(room: room, predict: predict, input: input, sim: sim, seconds: 8)

        XCTAssertGreaterThan(contacts.value, 0, "never touched the puck in 8 seconds")
        XCTAssertGreaterThan(run.puckDistance, 5, "the puck never moved")

        // A composite sim re-adopts the whole world on every ack, so it cannot
        // reconcile to exactly zero the way a flat reconciler does. The lab
        // measured solo play at ema 0.000 with corrections up to 0.004, and
        // pinned 0.5 as the line between an honest contested touch and a real
        // determinism bug (freezing the bot instead of predicting it: 2.06).
        XCTAssertLessThan(run.medianCorrection, 0.5,
                          "median correction \(run.medianCorrection) over \(run.corrections.count) reconciles")

        // A bound part registers into predict.value, so the render layer reads
        // the predicted puck exactly the way it reads anything else — the
        // "part.field" key stays an internal detail.
        XCTAssertEqual(predict.value(puck, "x"), sim.value("puck.x"), accuracy: 1e-9)
        XCTAssertFalse(predict.value(puck, "x").isNaN)
    }

    func testACompositeSimNeedsSomethingToRestoreFrom() async throws {
        let room = try await client.create("lab-hockey", options: ["private": true], state: HockeyState.self)
        defer { room.leave() }
        waitPumping("own paddle") { room.state?.players[room.sessionId ?? ""] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let input = try XCTUnwrap(room.input())

        // Nothing bound and no adopt: there would be no restore point before a
        // replay, so this has to fail rather than silently drift.
        let sim = predict.sim(input: input, parts: []) { _, _, _ in }
        XCTAssertNil(sim)
    }

    // MARK: -

    struct Run {
        var corrections: [Double] = []
        var puckDistance = 0.0

        var medianCorrection: Double {
            guard !corrections.isEmpty else { return .infinity }
            let sorted = corrections.sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// Chase the puck, which is what produces contacts to mispredict.
    private func chasePuck(
        room: Colyseus.Room<HockeyState>,
        predict: Colyseus.Predict,
        input: Colyseus.InputHandle,
        sim: Colyseus.Reconciler,
        seconds: TimeInterval
    ) -> Run {
        var run = Run()
        var lastSeq = sim.reconcileSeq
        let world = Colyseus.SimWorld(raw: sim.raw)
        _ = world

        let start = room.state?.puck.map { (x: $0.x, y: $0.y) } ?? (x: 0, y: 0)
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            Colyseus.pump()
            for _ in 0 ..< predict.tick(room.clock.now) {
                let puck = room.state?.puck
                let dx = (puck?.x ?? 0) - sim.value("paddle.x")
                let dy = (puck?.y ?? 0) - sim.value("paddle.y")
                input.data.set("moveX", to: dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0))
                input.data.set("moveY", to: dy > 0.5 ? 1 : (dy < -0.5 ? -1 : 0))
                input.send()
            }

            if sim.reconcileSeq != lastSeq {
                lastSeq = sim.reconcileSeq
                run.corrections.append(sim.lastCorrectionMagnitude)
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }

        let end = room.state?.puck.map { (x: $0.x, y: $0.y) } ?? (x: 0, y: 0)
        run.puckDistance = ((end.x - start.x) * (end.x - start.x) + (end.y - start.y) * (end.y - start.y)).squareRoot()
        return run
    }
}
