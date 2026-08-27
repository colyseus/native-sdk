import Foundation
import XCTest
@testable import Colyseus

/// Against the example server's HTTP routes and auth module.
final class HTTPIntegrationTests: XCTestCase {
    private var client: Colyseus.Client!

    override func setUpWithError() throws {
        try Server.requireExample()
        client = try Colyseus.Client(endpoint: Server.example)
    }

    override func tearDown() { client = nil }

    func testGetReturnsJSON() async throws {
        let response = try await client.http.get("/test")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["things"]?.array?.count, 6)
        let things = try XCTUnwrap(response.json?["things"]?.array)
        XCTAssertEqual(things.first?.int, 1)
        // 1 must not come back as `true`.
        XCTAssertNil(things.first?.bool)
    }

    func testGetDecodesIntoAType() async throws {
        struct Things: Decodable { let things: [Int] }
        let things = try await client.http.get("/test").decode(Things.self)
        XCTAssertEqual(things.things, [1, 2, 3, 4, 5, 6])
    }

    func testTheOtherVerbsEchoTheirBody() async throws {
        let post = try await client.http.post("/test", json: #"{"n":7}"#)
        XCTAssertEqual(post.json?["method"]?.string, "POST")
        XCTAssertEqual(post.json?["body"]?["n"]?.int, 7)

        let put = try await client.http.put("/test", json: #"{"n":8}"#)
        XCTAssertEqual(put.json?["method"]?.string, "PUT")
        XCTAssertEqual(put.json?["body"]?["n"]?.int, 8)

        let patch = try await client.http.patch("/test", json: #"{"n":9}"#)
        XCTAssertEqual(patch.json?["method"]?.string, "PATCH")
        XCTAssertEqual(patch.json?["body"]?["n"]?.int, 9)

        let delete = try await client.http.delete("/test")
        XCTAssertEqual(delete.json?["method"]?.string, "DELETE")
    }

    func testAMissingRouteThrows() async throws {
        do {
            _ = try await client.http.get("/definitely_not_a_route")
            XCTFail("a 404 came back as a success")
        } catch let error as Colyseus.Error {
            guard case .http(let status, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertGreaterThanOrEqual(status, 400)
        }
    }

    /// The C HTTP calls block for the whole request, so the SDK queues them.
    /// Several at once must not deadlock or interleave into each other.
    func testConcurrentRequestsAllComplete() async throws {
        let responses = try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0 ..< 5 {
                group.addTask { [client] in try await client!.http.get("/test").status }
            }
            var collected: [Int32] = []
            for try await status in group { collected.append(status) }
            return collected
        }

        XCTAssertEqual(responses.count, 5)
        XCTAssertTrue(responses.allSatisfy { $0 == 200 })
    }
}

final class AuthIntegrationTests: XCTestCase {
    private var client: Colyseus.Client!

    override func setUpWithError() throws {
        try Server.requireExample()
        client = try Colyseus.Client(endpoint: Server.example)
    }

    override func tearDown() {
        // The token lives in the system keychain under one process-wide key,
        // so it outlives the test run unless it is cleared here.
        client?.auth.signOut()
        client = nil
    }

    func testAnonymousSignInIssuesAToken() async throws {
        let user = try await client.auth.signInAnonymously()
        XCTAssertFalse(user.token.isEmpty)
        XCTAssertEqual(client.auth.token, user.token)

        // The same token is what HTTP sends.
        XCTAssertEqual(client.http.token, user.token)
    }

    func testRegisterThenSignIn() async throws {
        // A fresh address per run: the server's user store is in-memory but
        // survives between test runs of the same server process.
        let email = "swift-\(UUID().uuidString.prefix(8))@example.com"
        let password = "correct horse battery staple"

        let registered = try await client.auth.register(email: email, password: password)
        XCTAssertFalse(registered.token.isEmpty)

        client.auth.signOut()
        XCTAssertNil(client.auth.token)

        let signedIn = try await client.auth.signIn(email: email, password: password)
        XCTAssertFalse(signedIn.token.isEmpty)
        XCTAssertEqual(signedIn.data["email"]?.string, email)
    }

    func testTheWrongPasswordIsRefused() async throws {
        let email = "swift-\(UUID().uuidString.prefix(8))@example.com"
        _ = try await client.auth.register(email: email, password: "correct horse battery")

        do {
            _ = try await client.auth.signIn(email: email, password: "a different long password")
            XCTFail("the wrong password was accepted")
        } catch let error as Colyseus.Error {
            guard case .auth = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testOnChangeReportsSignInAndSignOut() async throws {
        let changes = Recorder()
        client.auth.onChange { user in changes.record(user?.token ?? "<signed out>") }

        _ = try await client.auth.signInAnonymously()
        XCTAssertEqual(changes.values.count, 1)
        XCTAssertNotEqual(changes.values.first, "<signed out>")

        client.auth.signOut()
        XCTAssertEqual(changes.values.last, "<signed out>")
    }
}
