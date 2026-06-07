
import CColyseus
import Foundation

/// Heap-allocated context for client matchmaking callbacks.
/// Holds the success/error closures and is released after the callback fires.
final class ClientContext {
    let onSuccess: (ColyseusRoom) -> Void
    let onError:   (Int32, String) -> Void

    init(onSuccess: @escaping (ColyseusRoom) -> Void,
         onError:   @escaping (Int32, String) -> Void) {
        self.onSuccess = onSuccess
        self.onError   = onError
    }

    func retain() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    static func consume(_ ptr: UnsafeMutableRawPointer) -> ClientContext {
        Unmanaged<ClientContext>.fromOpaque(ptr).takeRetainedValue()
    }
}
