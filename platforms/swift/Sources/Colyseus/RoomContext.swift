
import CColyseus
import Foundation

/// Heap-allocated context passed as `userdata` to every C callback.
/// Holds a weak reference to the owning ColyseusRoom so that we can
/// dispatch back to Swift without retaining the room.
///
/// Lifetime: one `RoomContext` is created per room and released in
/// `ColyseusRoom.deinit` via `releaseContext()`.
final class RoomContext {
    weak var room: ColyseusRoom?
    init(_ room: ColyseusRoom) { self.room = room }

    /// Returns an opaque pointer suitable for passing to C as `userdata`.
    /// Caller is responsible for releasing via `releaseContext()`.
    func retain() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    /// Releases the context previously retained by `retain()`.
    static func release(_ ptr: UnsafeMutableRawPointer) {
        Unmanaged<RoomContext>.fromOpaque(ptr).release()
    }

    static func from(_ ptr: UnsafeMutableRawPointer?) -> RoomContext? {
        guard let p = ptr else { return nil }
        return Unmanaged<RoomContext>.fromOpaque(p).takeUnretainedValue()
    }
}
