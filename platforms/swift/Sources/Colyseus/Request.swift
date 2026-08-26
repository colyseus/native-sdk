import CColyseus
import Foundation

public extension Colyseus {
    /// How long ``Colyseus/Room/request(_:_:timeout:)`` waits for a reply
    /// before giving up.
    ///
    /// The C core has no timer runtime of its own, so the wait lives here.
    /// Override it per call with the `timeout:` argument.
    nonisolated(unsafe) static var defaultRequestTimeout: TimeInterval = 10
}

public extension Colyseus.Room {
    /// Send a message and wait for the server's reply — the value its matching
    /// handler returns.
    ///
    /// ```swift
    /// let profile = try await room.request("get-profile", ["id": 42])
    /// ```
    ///
    /// Throws ``Colyseus/Error/requestRejected(reason:)`` when the handler
    /// called `ctx.reject`, ``Colyseus/Error/requestFailed(name:message:code:)``
    /// when it threw or no handler was registered,
    /// ``Colyseus/Error/requestTimedOut(type:seconds:)`` when nothing came
    /// back in time, and ``Colyseus/Error/roomClosed(code:reason:)`` when the
    /// connection went away first.
    ///
    /// A handler with nothing to return answers `.null`.
    @discardableResult
    func request(
        _ type: String,
        _ payload: MessagePackValue = .null,
        timeout: TimeInterval = Colyseus.defaultRequestTimeout
    ) async throws -> MessagePackValue {
        let pending = PendingRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.arm(continuation)

                let encoded = payload == .null ? Data() : MessagePack.encode(payload)
                let userdata = pending.retainForCallback()
                let id: UInt32 = encoded.withUnsafeBytes { buffer in
                    type.withCString { typePointer in
                        colyseus_room_request_encoded_reply(
                            raw, typePointer,
                            buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
                            requestReplyTrampoline, userdata
                        )
                    }
                }

                pending.armTimeout(timeout, room: raw, id: id, type: type)
            }
        } onCancel: {
            pending.cancel()
        }
    }
}

/// One in-flight request: resumes its continuation exactly once, whichever of
/// the reply, the timeout or a task cancellation gets there first, and drops
/// the retain the C side holds at the same moment.
final class PendingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MessagePackValue, Swift.Error>?
    private var selfRef: Unmanaged<PendingRequest>?
    private var timer: DispatchSourceTimer?
    private var room: UnsafeMutablePointer<colyseus_room_t>?
    private var requestId: UInt32 = 0
    private var settled = false

    func arm(_ continuation: CheckedContinuation<MessagePackValue, Swift.Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func retainForCallback() -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        let reference = Unmanaged.passRetained(self)
        selfRef = reference
        return reference.toOpaque()
    }

    func armTimeout(
        _ seconds: TimeInterval,
        room: UnsafeMutablePointer<colyseus_room_t>,
        id: UInt32,
        type: String
    ) {
        guard seconds > 0 else { return }
        lock.lock()
        self.room = room
        self.requestId = id
        if settled { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: Colyseus.callbackQueue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            self?.settle(.failure(Colyseus.Error.requestTimedOut(type: type, seconds: seconds)))
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func cancel() {
        settle(.failure(CancellationError()))
    }

    /// Resume once. The core is single-threaded around its pending table, so
    /// dropping a request takes the same lock `pump()` delivers replies under —
    /// otherwise a timeout could free the entry mid-callback.
    func settle(_ result: Result<MessagePackValue, Swift.Error>) {
        Colyseus.runtime.pumpLock.lock()
        lock.lock()
        guard !settled, let continuation else {
            lock.unlock()
            Colyseus.runtime.pumpLock.unlock()
            return
        }
        settled = true
        self.continuation = nil
        let reference = selfRef
        selfRef = nil
        let timer = self.timer
        self.timer = nil
        // Only a request still on the wire needs dropping; a delivered reply
        // has already left the core's table.
        if case .failure = result, let room, requestId != 0 {
            colyseus_room_cancel_request(room, requestId)
        }
        lock.unlock()
        Colyseus.runtime.pumpLock.unlock()

        timer?.cancel()
        continuation.resume(with: result)
        reference?.release()
    }

    /// Called from inside `pump()`, which already holds `pumpLock`.
    func settleFromCallback(_ result: Result<MessagePackValue, Swift.Error>) {
        lock.lock()
        guard !settled, let continuation else { lock.unlock(); return }
        settled = true
        self.continuation = nil
        let reference = selfRef
        selfRef = nil
        let timer = self.timer
        self.timer = nil
        // The entry is already gone from the core's table — cancelling here
        // would hash a freed id.
        requestId = 0
        lock.unlock()

        timer?.cancel()
        continuation.resume(with: result)
        reference?.release()
    }
}

private let requestReplyTrampoline: @convention(c) (
    Bool, UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { ok, data, length, error, userdata in
    guard let userdata else { return }
    let pending = Unmanaged<PendingRequest>.fromOpaque(userdata).takeUnretainedValue()

    // An empty reply is not a msgpack nil on the wire, but a caller reading a
    // value cannot act on the difference — both arrive as `.null`.
    let reply: MessagePackValue = (data != nil && length > 0)
        ? ((try? MessagePack.decode(Data(bytes: data!, count: length))) ?? .null)
        : .null

    if ok {
        pending.settleFromCallback(.success(reply))
        return
    }

    // `error` set means a FAULT — the handler threw, or none was registered.
    // Without it the server deliberately rejected, and `reply` is the reason
    // it authored, which the caller gets verbatim rather than stringified.
    if error == nil {
        pending.settleFromCallback(.failure(Colyseus.Error.requestRejected(reason: reply)))
        return
    }

    if let map = reply.map {
        pending.settleFromCallback(.failure(Colyseus.Error.requestFailed(
            name: map["name"]?.string ?? "Error",
            message: map["message"]?.string ?? String(cString: error!),
            code: map["code"]
        )))
    } else {
        pending.settleFromCallback(.failure(Colyseus.Error.roomClosed(
            code: 0, reason: String(cString: error!))))
    }
}
