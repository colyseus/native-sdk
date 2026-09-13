import CColyseus
import Foundation

struct CodeMessage: Sendable {
    let code: Int32
    let message: String
}

/// Handlers keyed by message type.
final class MessageRegistry<Payload>: @unchecked Sendable {
    private var emitters: [Colyseus.MessageType: Emitter<Payload>] = [:]
    private let lock = NSLock()

    func add(for type: Colyseus.MessageType, _ handler: @escaping (Payload) -> Void) -> Subscription {
        lock.lock()
        let emitter = emitters[type] ?? {
            let created = Emitter<Payload>()
            emitters[type] = created
            return created
        }()
        lock.unlock()

        return emitter.add(handler)
    }

    func emit(_ type: Colyseus.MessageType, _ payload: Payload) {
        lock.lock()
        let emitter = emitters[type]
        lock.unlock()
        emitter?.emit(payload)
    }
}

/// Everything the C room calls back into, in one object.
///
/// Room events reach handlers inside ``Colyseus/pump()``, on the thread that
/// called it: in polled mode the core fires them there, and the few it reports
/// synchronously from elsewhere — a close from `leave(consented: false)` or
/// `dropConnection()` — are held for the next pump. The C payload is copied
/// out first, since it only lives for the callback.
final class RoomBridge: @unchecked Sendable {
    let join = Emitter<Void>()
    let stateChange = Emitter<Void>()
    let error = Emitter<CodeMessage>()
    let leave = Emitter<CodeMessage>()
    let drop = Emitter<CodeMessage>()
    let reconnect = Emitter<Void>()

    let messages = MessageRegistry<MessagePackValue>()
    let byteMessages = MessageRegistry<Data>()
    let anyMessage = Emitter<(type: Colyseus.MessageType, payload: MessagePackValue)>()

    /// Set by `setLatency`. Only touched with the pump excluded or from
    /// inside one, so it needs no lock of its own.
    var hasInjectedLatency = false

    private var room: UnsafeMutablePointer<colyseus_room_t>?

    func install(on room: UnsafeMutablePointer<colyseus_room_t>, userdata: UnsafeMutableRawPointer) {
        self.room = room

        colyseus_room_on_join(room, { userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self) else { return }
            Colyseus.runtime.deliver { bridge.join.emit(()) }
        }, userdata)

        colyseus_room_on_state_change(room, { userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self) else { return }
            Colyseus.runtime.deliver { bridge.stateChange.emit(()) }
        }, userdata)

        colyseus_room_on_error(room, { code, message, userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self) else { return }
            let payload = CodeMessage(code: code, message: String(nullableCString: message) ?? "")
            Colyseus.runtime.deliver { bridge.error.emit(payload) }
        }, userdata)

        colyseus_room_on_leave(room, { code, reason, userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self) else { return }
            let payload = CodeMessage(code: code, message: String(nullableCString: reason) ?? "")
            Colyseus.runtime.deliver { bridge.leave.emit(payload) }
        }, userdata)

        colyseus_room_on_drop(room, { code, reason, userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self) else { return }
            let payload = CodeMessage(code: code, message: String(nullableCString: reason) ?? "")
            Colyseus.runtime.deliver { bridge.drop.emit(payload) }
        }, userdata)

        colyseus_room_on_reconnect(room, { userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self) else { return }
            // Before the next frame: the fresh transport arrives unwrapped.
            bridge.rewrapLatency()
            Colyseus.runtime.deliver { bridge.reconnect.emit(()) }
        }, userdata)

        // The encoded family, decoded in Swift: the core's own reader flattens
        // nested maps and arrays and gives up past 8 KB.
        colyseus_room_on_message_any_with_type_encoded(room, { type, data, length, userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self),
                  let type = String(nullableCString: type)
            else { return }

            let bytes = data.map { Data(bytes: $0, count: length) } ?? Data()
            let payload = (try? MessagePack.decode(bytes)) ?? .null
            let messageType = Colyseus.MessageType(wireType: type)

            Colyseus.runtime.deliver {
                bridge.messages.emit(messageType, payload)
                bridge.anyMessage.emit((type: messageType, payload: payload))
            }
        }, userdata)

        colyseus_room_on_message_any_with_type_bytes(room, { type, data, length, userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self),
                  let type = String(nullableCString: type)
            else { return }

            let bytes = data.map { Data(bytes: $0, count: length) } ?? Data()
            let messageType = Colyseus.MessageType(wireType: type)
            Colyseus.runtime.deliver { bridge.byteMessages.emit(messageType, bytes) }
        }, userdata)
    }

    /// Reconnecting swaps in a fresh transport, and injected latency rides a
    /// wrap around the old one.
    private func rewrapLatency() {
        guard let room, hasInjectedLatency else { return }
        colyseus_netdelay_wrap(room, false)
    }
}

/// The result a one-shot C callback settles, for ``Runtime/perform(_:_:)`` to
/// pick up. The callback retains it through userdata, so a caller that stopped
/// waiting (cancelled) leaves nothing dangling.
final class Completion<Value>: @unchecked Sendable {
    private var settled: Result<Value, Swift.Error>?
    private let lock = NSLock()

    /// Settles once; later calls are dropped. Some C paths can report both a
    /// failure and a close for the same operation.
    func finish(_ result: Result<Value, Swift.Error>) {
        lock.lock()
        defer { lock.unlock() }
        if settled == nil { settled = result }
    }

    var result: Result<Value, Swift.Error>? {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }
}

/// A matchmaking call on its way through C userdata.
///
/// The room is built inside the callback, not after the await resumes: by
/// then a pump may already have dispatched its first frames to handlers that
/// weren't installed yet.
final class PendingJoin: @unchecked Sendable {
    private let open: (UnsafeMutablePointer<colyseus_room_t>) -> Void
    private let fail: (Swift.Error) -> Void

    init<State: SchemaRef>(_ completion: Completion<Colyseus.Room<State>>) {
        open = { completion.finish(.success(Colyseus.Room<State>(raw: $0))) }
        fail = { completion.finish(.failure($0)) }
    }

    func opened(_ raw: UnsafeMutablePointer<colyseus_room_t>) { open(raw) }
    func failed(_ error: Swift.Error) { fail(error) }
}
