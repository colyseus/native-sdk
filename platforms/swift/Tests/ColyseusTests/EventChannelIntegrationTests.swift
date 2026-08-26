import Foundation
import XCTest
@testable import Colyseus

/// Against the playground's `lab-goal`: show the goal before the server has
/// agreed to it, then settle.
final class EventChannelIntegrationTests: XCTestCase {
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

    func testAPredictedGoalFiresEarlyAndIsConfirmed() async throws {
        let room = try await client.create("lab-goal", options: ["private": true], state: GoalState.self)
        defer { room.leave() }

        let sessionId = try XCTUnwrap(room.sessionId)
        waitPumping("own player") { room.state?.players[sessionId] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let input = try XCTUnwrap(room.input())
        let me = try XCTUnwrap(room.state?.players[sessionId])

        let predicted = Counter()
        let confirmed = Counter()
        let rejected = Counter()

        let goals = try XCTUnwrap(predict.defineEvent(
            label: "goal",
            onPredict: { _ in predicted.increment() },
            onConfirm: { _ in confirmed.increment() },
            onReject: { _ in rejected.increment() }
        ))
        defer { goals.dispose() }

        room.onMessage("goal") { payload in
            guard payload["sid"]?.string == sessionId else { return }
            goals.confirm()
        }

        // The step closure is @Sendable, so its counter has to be shared safely.
        let scored = Counter()
        let reconciler = try XCTUnwrap(predict.reconciler(
            truth: me, input: input,
            fields: ["x", "y", "vx", "vy", "scoreTicks"], smoothMs: 65
        ) { ctx, state, command in
            PlaygroundSim.stepEntity(state, command, dt: ctx.dt)
            if PlaygroundSim.stepScoreGate(state) {
                ctx.predict(goals, key: "goal-\(scored.value)")
                scored.increment()
            }
        })
        defer { reconciler.dispose() }

        // Drive into the goal strip on the right edge, at its vertical middle.
        driveToward(
            x: PlaygroundSim.goalZone.x + 4,
            y: PlaygroundSim.arenaHeight / 2,
            room: room, predict: predict, input: input, reconciler: reconciler,
            seconds: 5
        )

        XCTAssertGreaterThan(predicted.value, 0, "never predicted a goal — did the player reach the zone?")

        // The prediction fires on the crossing; the server's broadcast follows.
        waitPumping("the server to confirm") { confirmed.value > 0 }
        XCTAssertEqual(rejected.value, 0, "a goal was retracted with deny rate at zero")
        XCTAssertEqual(goals.pendingCount, 0)
    }

    func testPredictingTheSameKeyTwiceIsDropped() async throws {
        let room = try await client.create("lab-goal", options: ["private": true], state: GoalState.self)
        defer { room.leave() }
        waitPumping("own player") { room.state?.players[room.sessionId ?? ""] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let channel = try XCTUnwrap(predict.defineEvent(label: "manual"))
        defer { channel.dispose() }

        XCTAssertTrue(channel.predict(key: "once"))
        XCTAssertFalse(channel.predict(key: "once"), "the same key was accepted twice")
        XCTAssertTrue(channel.isPending(key: "once"))
        XCTAssertEqual(channel.pendingCount, 1)

        XCTAssertEqual(channel.confirm(key: "once"), 1)
        XCTAssertFalse(channel.isPending())

        // A confirm that settles nothing is its own case, not a no-op.
        XCTAssertEqual(channel.confirm(key: "once"), 0)
    }

    func testRejectRetractsAPrediction() async throws {
        let room = try await client.create("lab-goal", options: ["private": true], state: GoalState.self)
        defer { room.leave() }
        waitPumping("own player") { room.state?.players[room.sessionId ?? ""] != nil }

        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        let rejected = Recorder()
        let channel = try XCTUnwrap(predict.defineEvent(
            label: "manual",
            onReject: { key in rejected.record(key) }
        ))
        defer { channel.dispose() }

        XCTAssertTrue(channel.predict(key: "shot-1"))
        XCTAssertEqual(channel.reject(key: "shot-1"), 1)
        XCTAssertEqual(rejected.values, ["shot-1"])
        XCTAssertEqual(channel.pendingCount, 0)
    }

    // MARK: -

    /// Steer toward a point, one input per fixed step.
    private func driveToward(
        x targetX: Double,
        y targetY: Double,
        room: Colyseus.Room<GoalState>,
        predict: Colyseus.Predict,
        input: Colyseus.InputHandle,
        reconciler: Colyseus.Reconciler,
        seconds: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Colyseus.pump()
            for _ in 0 ..< predict.tick(room.clock.now) {
                guard let state = reconciler.state else { break }
                let dx = targetX - state["x"]
                let dy = targetY - state["y"]
                // The input is tri-state, so this is a direction, not a speed.
                input.data.set("moveX", to: dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0))
                input.data.set("moveY", to: dy > 0.5 ? 1 : (dy < -0.5 ? -1 : 0))
                input.send()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
    }
}
