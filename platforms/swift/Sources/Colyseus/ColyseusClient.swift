
import CColyseus
import Foundation

/// Top-level Colyseus client. Manages matchmaking and room lifecycle.
public final class ColyseusClient {

    private let raw: UnsafeMutablePointer<colyseus_client_t>
    private let settings: ColyseusSettings  // retain settings

    // MARK: - Lifecycle

    public init(settings: ColyseusSettings) {
        self.settings = settings
        guard let ptr = colyseus_client_create(settings.raw) else {
            fatalError("colyseus_client_create returned nil")
        }
        raw = ptr
    }

    deinit {
        colyseus_client_free(raw)
    }

    // MARK: - Matchmaking

    public func joinOrCreate(
        _ roomName: String,
        options: String = "{}",
        onSuccess: @escaping (ColyseusRoom) -> Void,
        onError:   @escaping (Int32, String) -> Void
    ) {
        let ctx = ClientContext(onSuccess: onSuccess, onError: onError)
        colyseus_client_join_or_create(
            raw, roomName, options,
            Self.roomSuccessCallback, Self.roomErrorCallback,
            ctx.retain()
        )
    }

    public func create(
        _ roomName: String,
        options: String = "{}",
        onSuccess: @escaping (ColyseusRoom) -> Void,
        onError:   @escaping (Int32, String) -> Void
    ) {
        let ctx = ClientContext(onSuccess: onSuccess, onError: onError)
        colyseus_client_create_room(
            raw, roomName, options,
            Self.roomSuccessCallback, Self.roomErrorCallback,
            ctx.retain()
        )
    }

    public func join(
        _ roomName: String,
        options: String = "{}",
        onSuccess: @escaping (ColyseusRoom) -> Void,
        onError:   @escaping (Int32, String) -> Void
    ) {
        let ctx = ClientContext(onSuccess: onSuccess, onError: onError)
        colyseus_client_join(
            raw, roomName, options,
            Self.roomSuccessCallback, Self.roomErrorCallback,
            ctx.retain()
        )
    }

    public func joinById(
        _ roomId: String,
        options: String = "{}",
        onSuccess: @escaping (ColyseusRoom) -> Void,
        onError:   @escaping (Int32, String) -> Void
    ) {
        let ctx = ClientContext(onSuccess: onSuccess, onError: onError)
        colyseus_client_join_by_id(
            raw, roomId, options,
            Self.roomSuccessCallback, Self.roomErrorCallback,
            ctx.retain()
        )
    }

    public func reconnect(
        token: String,
        onSuccess: @escaping (ColyseusRoom) -> Void,
        onError:   @escaping (Int32, String) -> Void
    ) {
        let ctx = ClientContext(onSuccess: onSuccess, onError: onError)
        colyseus_client_reconnect(
            raw, token,
            Self.roomSuccessCallback, Self.roomErrorCallback,
            ctx.retain()
        )
    }

    // MARK: - Async/await wrappers

    public func joinOrCreate(_ roomName: String, options: String = "{}") async throws -> ColyseusRoom {
        try await withCheckedThrowingContinuation { cont in
            joinOrCreate(roomName, options: options,
                onSuccess: { cont.resume(returning: $0) },
                onError:   { code, msg in cont.resume(throwing: ColyseusError(code: code, message: msg)) }
            )
        }
    }

    public func create(_ roomName: String, options: String = "{}") async throws -> ColyseusRoom {
        try await withCheckedThrowingContinuation { cont in
            create(roomName, options: options,
                onSuccess: { cont.resume(returning: $0) },
                onError:   { code, msg in cont.resume(throwing: ColyseusError(code: code, message: msg)) }
            )
        }
    }

    public func join(_ roomName: String, options: String = "{}") async throws -> ColyseusRoom {
        try await withCheckedThrowingContinuation { cont in
            join(roomName, options: options,
                onSuccess: { cont.resume(returning: $0) },
                onError:   { code, msg in cont.resume(throwing: ColyseusError(code: code, message: msg)) }
            )
        }
    }

    public func joinById(_ roomId: String, options: String = "{}") async throws -> ColyseusRoom {
        try await withCheckedThrowingContinuation { cont in
            joinById(roomId, options: options,
                onSuccess: { cont.resume(returning: $0) },
                onError:   { code, msg in cont.resume(throwing: ColyseusError(code: code, message: msg)) }
            )
        }
    }

    public func reconnect(token: String) async throws -> ColyseusRoom {
        try await withCheckedThrowingContinuation { cont in
            reconnect(token: token,
                onSuccess: { cont.resume(returning: $0) },
                onError:   { code, msg in cont.resume(throwing: ColyseusError(code: code, message: msg)) }
            )
        }
    }

    // MARK: - C trampolines (must be @convention(c))

    private static let roomSuccessCallback: colyseus_client_room_callback_t = { rawRoom, userdata in
        guard let rawRoom = rawRoom, let userdata = userdata else { return }
        let ctx = ClientContext.consume(userdata)
        let room = ColyseusRoom(raw: rawRoom, owns: true)
        room.installCallbacks()
        DispatchQueue.main.async { ctx.onSuccess(room) }
    }

    private static let roomErrorCallback: colyseus_client_error_callback_t = { code, message, userdata in
        guard let userdata = userdata else { return }
        let ctx = ClientContext.consume(userdata)
        let msg = message.map { String(cString: $0) } ?? ""
        DispatchQueue.main.async { ctx.onError(code, msg) }
    }
}

// MARK: - ColyseusError

public struct ColyseusError: Error, LocalizedError {
    public let code: Int32
    public let message: String

    public var errorDescription: String? { "Colyseus error \(code): \(message)" }
}
