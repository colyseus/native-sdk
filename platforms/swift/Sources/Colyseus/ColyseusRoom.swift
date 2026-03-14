
import CColyseus
import Foundation

/// Wraps a `colyseus_room_t*`.
/// All public event closures are invoked on the **main queue**.
public final class ColyseusRoom {

    let raw: UnsafeMutablePointer<colyseus_room_t>
    private let ownsRaw: Bool
    private var ctxPtr: UnsafeMutableRawPointer?
    private var dynamicVtable: UnsafeMutablePointer<colyseus_dynamic_vtable_t>?

    // MARK: - Public callbacks

    public var onJoin:        (() -> Void)?
    public var onLeave:       ((Int32, String) -> Void)?
    public var onError:       ((Int32, String) -> Void)?
    public var onStateChange: ((SchemaState) -> Void)?
    public var onMessage:     ((String, MessageValue) -> Void)?
    public var onMessageRaw:  ((String, Data) -> Void)?

    // MARK: - Lifecycle

    init(raw: UnsafeMutablePointer<colyseus_room_t>, owns: Bool = true) {
        self.raw = raw
        self.ownsRaw = owns
    }

    deinit {
        if let p = ctxPtr { RoomContext.release(p) }
        if ownsRaw { colyseus_room_free(raw) }
        if let v = dynamicVtable { colyseus_dynamic_vtable_free(v) }
    }

    // MARK: - Internal setup

    func installCallbacks() {
        let ctx = RoomContext(self)
        let ptr = ctx.retain()
        ctxPtr = ptr

        colyseus_room_on_join(raw, { ud in
            guard let r = RoomContext.from(ud)?.room else { return }
            DispatchQueue.main.async { r.onJoin?() }
        }, ptr)

        colyseus_room_on_leave(raw, { code, reason, ud in
            guard let r = RoomContext.from(ud)?.room else { return }
            let s = reason.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { r.onLeave?(code, s) }
        }, ptr)

        colyseus_room_on_error(raw, { code, msg, ud in
            guard let r = RoomContext.from(ud)?.room else { return }
            let s = msg.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { r.onError?(code, s) }
        }, ptr)

        colyseus_room_on_state_change(raw, { ud in
            guard let r = RoomContext.from(ud)?.room else { return }
            guard let statePtr = colyseus_room_get_state(r.raw) else { return }
            let state = SchemaWalker.walk(statePtr)
            DispatchQueue.main.async { r.onStateChange?(state) }
        }, ptr)

        // Single wildcard handler for all message types (encoded bytes path).
        colyseus_room_on_message_any_with_type_encoded(raw, { msgType, data, length, ud in
            guard let r = RoomContext.from(ud)?.room else { return }
            let t = msgType.map { String(cString: $0) } ?? ""
            guard let data = data else { return }
            let bytes = Data(bytes: data, count: length)
            if let readerPtr = colyseus_message_reader_create(data, length) {
                let decoded = MessageReader(readerPtr).decode()
                DispatchQueue.main.async {
                    r.onMessage?(t, decoded)
                    r.onMessageRaw?(t, bytes)
                }
            } else {
                DispatchQueue.main.async { r.onMessageRaw?(t, bytes) }
            }
        }, ptr)
    }

    // MARK: - Dynamic schema

    /// Opt-in to dynamic schema decoding. Call before the room connects.
    /// After joining, `state` and `onStateChange` will be populated.
    public func enableDynamicSchema() {
        guard dynamicVtable == nil else { return }
        guard let vtable = colyseus_dynamic_vtable_create("SwiftDynamic") else { return }
        dynamicVtable = vtable
        withUnsafePointer(to: vtable.pointee.base) { basePtr in
            colyseus_room_set_state_type(raw, basePtr)
        }
    }

    // MARK: - Properties

    public var roomId: String?           { colyseus_room_get_id(raw).map { String(cString: $0) } }
    public var sessionId: String?        { colyseus_room_get_session_id(raw).map { String(cString: $0) } }
    public var name: String?             { colyseus_room_get_name(raw).map { String(cString: $0) } }
    public var reconnectionToken: String?{ colyseus_room_get_reconnection_token(raw).map { String(cString: $0) } }
    public var isConnected: Bool         { colyseus_room_is_connected(raw) }

    public var state: SchemaState? {
        colyseus_room_get_state(raw).map { SchemaWalker.walk($0) }
    }

    // MARK: - Send

    public func send(type: String, _ message: MessageBuilder) {
        colyseus_room_send(raw, type, message.raw)
    }

    public func send(type: Int32, _ message: MessageBuilder) {
        colyseus_room_send_int(raw, type, message.raw)
    }

    public func send(type: String, encoded data: Data) {
        data.withUnsafeBytes {
            colyseus_room_send_encoded(raw, type, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count)
        }
    }

    public func send(type: Int32, encoded data: Data) {
        data.withUnsafeBytes {
            colyseus_room_send_int_encoded(raw, type, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count)
        }
    }

    public func sendBytes(type: String, _ data: Data) {
        data.withUnsafeBytes {
            colyseus_room_send_bytes(raw, type, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count)
        }
    }

    public func sendBytes(type: Int32, _ data: Data) {
        data.withUnsafeBytes {
            colyseus_room_send_int_bytes(raw, type, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count)
        }
    }

    // MARK: - Leave

    public func leave(consented: Bool = true) {
        colyseus_room_leave(raw, consented)
    }
}
