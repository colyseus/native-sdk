import Foundation
import XCTest
@testable import Colyseus

/// Against the prediction playground's `lab-move` room.
///
/// These are the load-bearing checks for the predict layer: that inputs are
/// paced by the server's own step, that prediction runs ahead of the server,
/// and that a client reproducing the server's arithmetic reconciles to nothing.
final class PredictIntegrationTests: XCTestCase {
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

    /// Join, and get the pieces every lab starts from.
    private func joinLabMove() async throws -> (
        room: Colyseus.Room<MoveState>,
        predict: Colyseus.Predict,
        input: Colyseus.InputHandle,
        me: MovePlayer
    ) {
        let room = try await client.create("lab-move", options: ["private": true], state: MoveState.self)
        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let input = try XCTUnwrap(room.input())
        let me = try XCTUnwrap(room.state?.players[sessionId])
        return (room, predict, input, me)
    }

    func testTheServerAdvertisesItsStep() async throws {
        let (room, _, input, _) = try await joinLabMove()
        defer { room.leave() }

        XCTAssertEqual(input.tickRate, 20)
        XCTAssertGreaterThan(input.patchRate, 0)
        XCTAssertGreaterThanOrEqual(input.subSteps, 1)
    }

    func testTheClockSyncsToTheServer() async throws {
        let (room, _, _, _) = try await joinLabMove()
        defer { room.leave() }

        // Server time only arrives on TIMED patches, so give it a few.
        pump(for: 1.0)

        XCTAssertGreaterThan(room.clock.now, 0)
        XCTAssertNotEqual(room.clock.serverNow, room.clock.now, "no server time — is the room stamping patches?")
        XCTAssertGreaterThan(room.clock.lastServerTime, 0)
        XCTAssertGreaterThanOrEqual(room.clock.rtt, 0)
    }

    func testTickPacesInputsOnTheServersCadence() async throws {
        let (room, predict, input, me) = try await joinLabMove()
        defer { room.leave() }

        // No reconciler yet, so nothing has advertised the fixed step.
        XCTAssertEqual(predict.tick(room.clock.now), 0)

        let reconciler = try XCTUnwrap(predict.reconciler(
            truth: me, input: input, fields: ["x", "y", "vx", "vy"], smoothMs: 65
        ) { ctx, state, command in
            PlaygroundSim.stepEntity(state, command, dt: ctx.dt)
        })
        defer { reconciler.dispose() }

        XCTAssertEqual(reconciler.stepMs, 50, accuracy: 0.001, "20 Hz is a 50 ms step")

        let steps = countSteps(room: room, predict: predict, seconds: 1.0)

        // One second at 20 Hz. The pacer caps bursts at 5 a frame, so this is
        // a range rather than a number.
        XCTAssertGreaterThan(steps, 12, "paced too slowly — \(steps) steps in a second")
        XCTAssertLessThan(steps, 30, "paced too fast — \(steps) steps in a second")
    }

    func testPredictionLeadsTheServerAndReconcilesToNothing() async throws {
        let (room, predict, input, me) = try await joinLabMove()
        defer { room.leave() }

        let reconciler = try XCTUnwrap(predict.reconciler(
            truth: me, input: input, fields: ["x", "y", "vx", "vy"], smoothMs: 65
        ) { ctx, state, command in
            PlaygroundSim.stepEntity(state, command, dt: ctx.dt)
        })
        defer { reconciler.dispose() }

        let run = driveBoxPattern(room: room, predict: predict, input: input, reconciler: reconciler)

        // Liveness first. A near-zero correction is also what a dead
        // simulation reads: a player pinned against a wall has no velocity
        // left for friction to act on, and then this measures nothing.
        XCTAssertGreaterThan(run.distanceTravelled, 8, "the player barely moved")
        XCTAssertGreaterThan(run.fastestCoast, 2,
                             "never coasted with speed on — friction was never exercised")

        // Now the claim: a client running the server's arithmetic corrects by
        // nothing. The MEDIAN, because a contested reconcile mispredicts by
        // design and an end-of-run reading answers a question nobody asked.
        XCTAssertLessThan(run.medianCorrection, 1e-6,
                          "median correction \(run.medianCorrection) over \(run.corrections.count) reconciles")
        XCTAssertEqual(reconciler.drift.status, .matched,
                       "drift ema \(reconciler.drift.ema), peak \(reconciler.drift.peak)")
        XCTAssertGreaterThan(reconciler.reconcileSeq, 0)
    }

    func testInjectedLatencyDeepensThePendingWindow() async throws {
        let (room, predict, input, me) = try await joinLabMove()
        defer { room.leave() }

        let reconciler = try XCTUnwrap(predict.reconciler(
            truth: me, input: input, fields: ["x", "y", "vx", "vy"], smoothMs: 65
        ) { ctx, state, command in
            PlaygroundSim.stepEntity(state, command, dt: ctx.dt)
        })
        defer { reconciler.dispose() }

        drive(room: room, predict: predict, input: input, moveX: 1, seconds: 1.0)
        let pendingOnLoopback = reconciler.pendingCount

        // A 200 ms round trip at 20 Hz is four inputs in flight.
        room.setLatency(delayMs: 200)
        drive(room: room, predict: predict, input: input, moveX: 1, seconds: 1.5)
        let pendingWithLatency = reconciler.pendingCount

        XCTAssertGreaterThan(pendingWithLatency, pendingOnLoopback,
                             "\(pendingOnLoopback) -> \(pendingWithLatency)")
        XCTAssertGreaterThan(room.clock.smoothedRtt, 100)

        // Prediction is still exact; latency changes when the server agrees,
        // not whether it does.
        XCTAssertEqual(reconciler.drift.status, .matched,
                       "drift ema \(reconciler.drift.ema), peak \(reconciler.drift.peak)")

        room.setLatency(delayMs: 0)
    }

    func testAServerImpulseRegistersAsACorrectionAndDecays() async throws {
        let (room, predict, input, me) = try await joinLabMove()
        defer { room.leave() }

        let reconciler = try XCTUnwrap(predict.reconciler(
            truth: me, input: input, fields: ["x", "y", "vx", "vy"], smoothMs: 200
        ) { ctx, state, command in
            PlaygroundSim.stepEntity(state, command, dt: ctx.dt)
        })
        defer { reconciler.dispose() }

        drive(room: room, predict: predict, input: input, moveX: 1, seconds: 0.8)

        // The server kicks the player in a way no client could have predicted.
        room.send("impulse")
        drive(room: room, predict: predict, input: input, moveX: 0, seconds: 0.5)

        XCTAssertGreaterThan(reconciler.drift.peak, 1e-3, "the impulse produced no correction at all")

        // ...and it eases out rather than staying.
        drive(room: room, predict: predict, input: input, moveX: 0, seconds: 2.0)
        XCTAssertLessThan(reconciler.lastCorrectionMagnitude, reconciler.drift.peak)
    }

    func testRemoteEntitiesSmoothThroughAttachAll() async throws {
        let (room, predict, input, me) = try await joinLabMove()
        defer { room.leave() }

        let state = try XCTUnwrap(room.state)
        XCTAssertTrue(predict.attachAll(
            state.players,
            fields: ["x", "y"],
            options: .init(mode: .lerp, delay: 100),
            except: room.sessionId
        ))

        // Attaching must not disturb the local player, which is excepted.
        drive(room: room, predict: predict, input: input, moveX: 1, seconds: 0.5)
        XCTAssertFalse(predict.value(me, "x").isNaN)
    }

    func testValueFallsBackToRawStateForUntrackedFields() async throws {
        let (room, predict, _, me) = try await joinLabMove()
        defer { room.leave() }

        // hue is never attached, so this is the decoded value.
        XCTAssertEqual(predict.value(me, "hue"), me.hue)
        // ...and a field the schema does not declare reads as NaN, not zero.
        XCTAssertTrue(predict.value(me, "nonexistent").isNaN)
    }

    // MARK: -

    struct Run {
        var corrections: [Double] = []
        var distanceTravelled = 0.0
        /// The fastest the player was moving while holding no input — how
        /// much velocity friction actually had to work on.
        var fastestCoast = 0.0

        var medianCorrection: Double {
            guard !corrections.isEmpty else { return .infinity }
            let sorted = corrections.sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// Drive a box inside the arena, coasting between legs.
    ///
    /// The pattern matters: holding one direction pins the player against a
    /// wall, where velocity is zero and the friction term — the one place the
    /// two simulations can quietly disagree — never runs.
    private func driveBoxPattern(
        room: Colyseus.Room<MoveState>,
        predict: Colyseus.Predict,
        input: Colyseus.InputHandle,
        reconciler: Colyseus.Reconciler
    ) -> Run {
        var run = Run()
        var lastSeq = reconciler.reconcileSeq
        let start = (x: reconciler.value("x"), y: reconciler.value("y"))

        let legs: [(x: Double, y: Double, seconds: TimeInterval)] = [
            (1, 0, 0.35), (0, 0, 0.30),
            (0, 1, 0.35), (0, 0, 0.30),
            (-1, 0, 0.35), (0, 0, 0.30),
            (0, -1, 0.35), (0, 0, 0.30),
            (1, 1, 0.35), (0, 0, 0.45),
        ]

        for leg in legs {
            let deadline = Date().addingTimeInterval(leg.seconds)
            while Date() < deadline {
                Colyseus.pump()
                for _ in 0 ..< predict.tick(room.clock.now) {
                    input.data.set("moveX", to: leg.x)
                    input.data.set("moveY", to: leg.y)
                    input.send()
                }

                // One sample per reconcile, not per frame.
                if reconciler.reconcileSeq != lastSeq {
                    lastSeq = reconciler.reconcileSeq
                    run.corrections.append(reconciler.lastCorrectionMagnitude)
                }

                if leg.x == 0, leg.y == 0, let state = reconciler.state {
                    let speed = (state["vx"] * state["vx"] + state["vy"] * state["vy"]).squareRoot()
                    run.fastestCoast = max(run.fastestCoast, speed)
                }

                RunLoop.current.run(until: Date().addingTimeInterval(0.008))
            }
        }

        let dx = reconciler.value("x") - start.x
        let dy = reconciler.value("y") - start.y
        run.distanceTravelled = (dx * dx + dy * dy).squareRoot()
        return run
    }

    /// Run a frame loop and total up the fixed steps it was handed.
    private func countSteps(
        room: Colyseus.Room<MoveState>,
        predict: Colyseus.Predict,
        seconds: TimeInterval
    ) -> Int {
        var steps = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Colyseus.pump()
            steps += predict.tick(room.clock.now)
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
        return steps
    }

    /// One frame loop: pump, ask for the steps due, send one input each.
    private func drive(
        room: Colyseus.Room<MoveState>,
        predict: Colyseus.Predict,
        input: Colyseus.InputHandle,
        moveX: Double = 0,
        moveY: Double = 0,
        seconds: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Colyseus.pump()
            for _ in 0 ..< predict.tick(room.clock.now) {
                input.data.set("moveX", to: moveX)
                input.data.set("moveY", to: moveY)
                input.send()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
    }
}
