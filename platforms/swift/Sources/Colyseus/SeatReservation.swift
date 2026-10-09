import Foundation

public extension Colyseus {
    /// A seat the server reserved for this client: what the server's
    /// `matchMaker.joinOrCreate()` / `create()` / `join()` / `joinById()` /
    /// `reserveSeatFor()` return. Join with it through
    /// `client.consumeSeatReservation(_:state:)`.
    ///
    /// Decodes straight from the JSON a server route answers with:
    ///
    /// ```swift
    /// let seat = try await client.http.post("/find_match").decode(Colyseus.SeatReservation.self)
    /// ```
    struct SeatReservation: Codable, Sendable, Hashable {
        /// The room's name, as defined on the server.
        public var name: String
        public var roomId: String
        /// The server process hosting the room.
        public var processId: String
        public var sessionId: String
        /// Where that process is reached, when it differs from the client's
        /// endpoint. Set by servers configured with a `publicAddress`.
        public var publicAddress: String?
        /// Set when the reservation re-takes a seat held for reconnection.
        public var reconnectionToken: String?
        public var devMode: Bool?

        public init(
            name: String,
            roomId: String,
            processId: String,
            sessionId: String,
            publicAddress: String? = nil,
            reconnectionToken: String? = nil,
            devMode: Bool? = nil
        ) {
            self.name = name
            self.roomId = roomId
            self.processId = processId
            self.sessionId = sessionId
            self.publicAddress = publicAddress
            self.reconnectionToken = reconnectionToken
            self.devMode = devMode
        }
    }
}
