import Foundation
import XCTest
@testable import Colyseus

/// Servers the integration tests need.
///
/// A missing server skips the test with the command that starts it, rather
/// than failing — the same shape the Flutter suite uses, so a checkout without
/// a server running still reports something useful.
enum Server {
    static let example = "ws://127.0.0.1:2567"
    static let playground = "ws://127.0.0.1:5173"

    static func require(_ endpoint: String, _ startCommand: String) throws {
        guard isUp(endpoint) else {
            throw XCTSkip("no server on \(endpoint) — start it with: \(startCommand)")
        }
    }

    static func requireExample() throws {
        try require(example, "cd example-server && npm start")
    }

    static func requirePlayground() throws {
        try require(playground, "cd ../prediction-tools && pnpm dev --host 0.0.0.0")
    }

    private static func isUp(_ endpoint: String) -> Bool {
        guard let components = URLComponents(string: endpoint),
              let host = components.host,
              let port = components.port,
              let url = URL(string: "http://\(host):\(port)/matchmake/")
        else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"

        var reachable = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return reachable
    }
}

extension XCTestCase {
    /// Pump until `condition` holds, or fail after `timeout`.
    ///
    /// Everything the SDK delivers arrives inside a pump, so a test that waits
    /// without pumping waits forever.
    @discardableResult
    func waitPumping(
        _ what: String,
        timeout: TimeInterval = 8,
        until condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Colyseus.pump()
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        return false
    }

    /// Pump for a fixed stretch, for the checks that need traffic to settle
    /// rather than a specific thing to happen.
    func pump(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            Colyseus.pump()
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
    }
}
