import CColyseus
import Foundation

public extension Colyseus {
    /// How long ``Colyseus/Room/request(_:_:timeout:)`` waits for a reply
    /// before giving up.
    ///
    /// Nothing in the core drives a deadline for pending requests yet, so the
    /// wait lives here. Override it per call with the `timeout:` argument.
    static var defaultRequestTimeout: TimeInterval {
        get { runtime.defaultRequestTimeout }
        set { runtime.defaultRequestTimeout = newValue }
    }
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
    /// A handler with nothing to return answers `.null`, the same as one that
    /// returns nil — the wire keeps those apart, but a caller reading a value
    /// cannot act on the difference.
    @discardableResult
    func request(
        _ type: String,
        _ payload: MessagePackValue = .null,
        timeout: TimeInterval = Colyseus.defaultRequestTimeout
    ) async throws -> MessagePackValue {
        let pending = PendingRequest(room: raw, type: type)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let userdata = pending.arm(continuation)
                let encoded = payload == .null ? Data() : MessagePack.encode(payload)
                let id: UInt32 = encoded.withUnsafeBytes { buffer in
                    type.withCString { typePointer in
                        colyseus_room_request_encoded_reply(
                            raw, typePointer,
                            buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
                            requestReplyTrampoline, userdata
                        )
                    }
                }
                pending.started(id: id, timeout: timeout)
            }
        } onCancel: {
            pending.settle(.failure(CancellationError()))
        }
    }
}

/// One in-flight request. Whichever of the reply, the timeout or a task
/// cancellation gets there first claims it, and that claim is what resumes the
/// continuation, disarms the timer and drops the retain the C side holds —
/// each exactly once.
final class PendingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let room: UnsafeMutablePointer<colyseus_room_t>
    private let type: String
    private var continuation: CheckedContinuation<MessagePackValue, Swift.Error>?
    private var userdata: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?
    private var requestId: UInt32 = 0

    init(room: UnsafeMutablePointer<colyseus_room_t>, type: String) {
        self.room = room
        self.type = type
    }

    /// Take the continuation and the retain the C callback reads us back
    /// through.
    func arm(_ continuation: CheckedContinuation<MessagePackValue, Swift.Error>) -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
        let pointer = retainedPointer(self)
        userdata = pointer
        return pointer
    }

    /// Record the id unconditionally — a request with no timeout can still be
    /// dropped by a cancellation, and dropping it is what keeps the core from
    /// calling back into a released object.
    func started(id: UInt32, timeout: TimeInterval) {
        lock.lock()
        requestId = id
        guard userdata != nil, timeout > 0 else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: Colyseus.callbackQueue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self, type] in
            self?.settle(.failure(Colyseus.Error.requestTimedOut(type: type, seconds: timeout)))
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    /// Settle from outside the core's callback — a timeout or a cancellation.
    ///
    /// Takes the pump lock so the entry is not dropped while a reply is being
    /// delivered through `pump()`. That covers the common race but not all of
    /// it: the core's pending table has no lock of its own, and a close
    /// rejects from the transport thread.
    func settle(_ result: Result<MessagePackValue, Swift.Error>) {
        Colyseus.runtime.pumpLock.lock()
        defer { Colyseus.runtime.pumpLock.unlock() }
        claim(result) { room, id in colyseus_room_cancel_request(room, id) }
    }

    /// Settle from the C callback, which has already taken the entry out of
    /// the core's table — cancelling here would hash a spent id.
    func settleFromCallback(_ result: Result<MessagePackValue, Swift.Error>) {
        claim(result, drop: nil)
    }

    /// The claim: whoever nils `userdata` under the lock owns the tidy-up.
    private func claim(
        _ result: Result<MessagePackValue, Swift.Error>,
        drop: ((UnsafeMutablePointer<colyseus_room_t>, UInt32) -> Void)?
    ) {
        lock.lock()
        guard let pointer = userdata, let continuation else { lock.unlock(); return }
        userdata = nil
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        if let drop, requestId != 0 { drop(room, requestId) }
        lock.unlock()

        // Outside the lock: resuming runs the caller's code, and the release
        // can be the last one holding us.
        timer?.cancel()
        Colyseus.runtime.deliver { continuation.resume(with: result) }
        releasePointer(pointer, as: PendingRequest.self)
    }
}

private let requestReplyTrampoline: @convention(c) (
    colyseus_request_outcome_t, UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { outcome, data, length, reason, userdata in
    guard let pending = borrowObject(userdata, as: PendingRequest.self) else { return }

    var reply = MessagePackValue.null
    if let data, length > 0 {
        reply = (try? MessagePack.decode(Data(bytes: data, count: length))) ?? .null
    }

    let result: Result<MessagePackValue, Swift.Error>
    switch outcome {
    case COLYSEUS_REQUEST_OK:
        result = .success(reply)
    case COLYSEUS_REQUEST_REJECTED:
        // The reason the server authored, handed on whole rather than
        // stringified, so a caller can branch on it.
        result = .failure(Colyseus.Error.requestRejected(reason: reply))
    case COLYSEUS_REQUEST_CLOSED:
        result = .failure(Colyseus.Error.roomClosed(
            code: 0, reason: String(nullableCString: reason) ?? "connection closed"))
    default:
        // FAULTED: a sanitized { name, message, code }, never the raw reason.
        let map = reply.map ?? [:]
        result = .failure(Colyseus.Error.requestFailed(
            name: map["name"]?.string ?? "Error",
            message: map["message"]?.string ?? "request failed",
            code: map["code"]))
    }
    pending.settleFromCallback(result)
}
