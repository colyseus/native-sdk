import Foundation
import XCTest
@testable import Colyseus

/// Against the playground's `lab-bots`: smoothing and dead reckoning over
/// entities the client does not control.
final class ReckonIntegrationTests: XCTestCase {
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

    private func joinLabBots() async throws -> (
        room: Colyseus.Room<BotsState>,
        predict: Colyseus.Predict,
        state: BotsState
    ) {
        let room = try await client.create("lab-bots", options: ["private": true], state: BotsState.self)
        waitPumping("the bots") { (room.state?.bots.count ?? 0) > 0 }
        let predict = try XCTUnwrap(Colyseus.Predict.get(room))
        return (room, predict, try XCTUnwrap(room.state))
    }

    func testAttachAllReckonAcceptsAReflectionSchema() async throws {
        let (room, predict, state) = try await joinLabBots()
        defer { room.leave() }

        let stepped = Counter()
        XCTAssertTrue(predict.attachAllReckon(
            state.bots,
            fields: ["x", "y"],
            smoothMs: 80
        ) { bot, dt, elapsedMs in
            stepped.increment()
            PlaygroundSim.stepBot(bot, dt: dt, elapsedMs: elapsedMs)
        })

        // Reckoning is computed on demand and cached per frame, so a loop
        // that ticks without reading never asks anything to be reckoned.
        tick(room: room, predict: predict, seconds: 1.5) {
            for bot in state.bots.values { _ = predict.value(bot, "x") }
        }

        XCTAssertGreaterThan(stepped.value, 0, "the reckon step never ran")

        let bot = try XCTUnwrap(state.bots.values.first)
        XCTAssertFalse(predict.value(bot, "x").isNaN)
    }

    func testLerpAndRawDisagreeOnAMovingBot() async throws {
        let (room, predict, state) = try await joinLabBots()
        defer { room.leave() }

        // 300 ms of render delay is a third of a second in the past, which on
        // a bot crossing the arena is a visible gap from the raw snapshot.
        predict.attachAll(state.bots, fields: ["x"], options: .init(mode: .lerp, delay: 300))

        tick(room: room, predict: predict, seconds: 1.5)

        let gaps = state.bots.values.map { abs(predict.value($0, "x") - $0.x) }
        XCTAssertFalse(gaps.isEmpty)
        XCTAssertTrue(gaps.contains { $0 > 0.01 },
                      "no bot's interpolated pose differed from its raw one — are they moving?")
    }

    // MARK: -

    private func tick(
        room: Colyseus.Room<BotsState>,
        predict: Colyseus.Predict,
        seconds: TimeInterval,
        eachFrame: () -> Void = {}
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Colyseus.pump()
            predict.tick(room.clock.now)
            eachFrame()
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
    }
}
