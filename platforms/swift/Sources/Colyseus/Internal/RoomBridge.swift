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
/// Room events run on whatever thread called ``Colyseus/pump()`` — with
/// inbound traffic serialized (the default) that is the caller's own thread,
/// so a handler sees the state it was told about and nothing has moved on.
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

    private var room: UnsafeMutablePointer<colyseus_room_t>?

    func install(on room: UnsafeMutablePointer<colyseus_room_t>, userdata: UnsafeMutableRawPointer) {
        self.room = room
        armTransport()

        colyseus_room_on_join(room, { userdata in
            borrowObject(userdata, as: RoomBridge.self)?.join.emit(())
        }, userdata)

        colyseus_room_on_state_change(room, { userdata in
            borrowObject(userdata, as: RoomBridge.self)?.stateChange.emit(())
        }, userdata)

        colyseus_room_on_error(room, { code, message, userdata in
            borrowObject(userdata, as: RoomBridge.self)?
                .error.emit(CodeMessage(code: code, message: String(nullableCString: message) ?? ""))
        }, userdata)

        colyseus_room_on_leave(room, { code, reason, userdata in
            borrowObject(userdata, as: RoomBridge.self)?
                .leave.emit(CodeMessage(code: code, message: String(nullableCString: reason) ?? ""))
        }, userdata)

        colyseus_room_on_drop(room, { code, reason, userdata in
            borrowObject(userdata, as: RoomBridge.self)?
                .drop.emit(CodeMessage(code: code, message: String(nullableCString: reason) ?? ""))
        }, userdata)

        colyseus_room_on_reconnect(room, { userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self) else { return }
            // Reconnecting swaps in a fresh transport, so the wrap that
            // serializes inbound traffic has to go back on.
            bridge.armTransport()
            bridge.reconnect.emit(())
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

            bridge.messages.emit(messageType, payload)
            bridge.anyMessage.emit((type: messageType, payload: payload))
        }, userdata)

        colyseus_room_on_message_any_with_type_bytes(room, { type, data, length, userdata in
            guard let bridge = borrowObject(userdata, as: RoomBridge.self),
                  let type = String(nullableCString: type)
            else { return }

            let bytes = data.map { Data(bytes: $0, count: length) } ?? Data()
            bridge.byteMessages.emit(Colyseus.MessageType(wireType: type), bytes)
        }, userdata)
    }

    /// Queue inbound frames so they are decoded inside `pump()` rather than on
    /// the transport's thread. Also the seam injected latency rides on.
    func armTransport() {
        guard let room, Colyseus.serializedInbound else { return }
        colyseus_netdelay_wrap(room, true)
    }
}

/// A C callback that fires exactly once, carrying a Swift completion.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private var completion: (@Sendable (Result<Value, Swift.Error>) -> Void)?
    private let lock = NSLock()

    init(_ completion: @escaping @Sendable (Result<Value, Swift.Error>) -> Void) {
        self.completion = completion
    }

    /// Settles once; later calls are dropped. Some C paths can report both a
    /// failure and a close for the same operation.
    func finish(_ result: Result<Value, Swift.Error>) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()

        guard let completion else { return }
        Colyseus.runtime.deliver { completion(result) }
    }
}
