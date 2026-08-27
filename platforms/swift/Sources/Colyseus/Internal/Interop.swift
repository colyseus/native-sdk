import CColyseus
import Foundation

// MARK: - Passing Swift objects through C userdata

/// Retains `object` and returns the pointer to hand a C callback as userdata.
/// Balance it with `Unretain` (one delivery) or `Release` (teardown).
@inlinable
func retainedPointer<T: AnyObject>(_ object: T) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(object).toOpaque()
}

/// Reads the object back without consuming the retain — for callbacks that
/// fire many times.
@inlinable
func borrowObject<T: AnyObject>(_ pointer: UnsafeMutableRawPointer?, as _: T.Type = T.self) -> T? {
    guard let pointer else { return nil }
    return Unmanaged<T>.fromOpaque(pointer).takeUnretainedValue()
}

/// Reads the object back and consumes the retain — for one-shot callbacks.
@inlinable
func consumeObject<T: AnyObject>(_ pointer: UnsafeMutableRawPointer?, as _: T.Type = T.self) -> T? {
    guard let pointer else { return nil }
    return Unmanaged<T>.fromOpaque(pointer).takeRetainedValue()
}

/// Drops a retain taken by `retainedPointer` without delivering anything.
@inlinable
func releasePointer<T: AnyObject>(_ pointer: UnsafeMutableRawPointer?, as _: T.Type) {
    guard let pointer else { return }
    Unmanaged<T>.fromOpaque(pointer).release()
}

// MARK: - Strings

extension String {
    /// Reads a C string, treating NULL as nil rather than as "".
    init?(nullableCString pointer: UnsafePointer<CChar>?) {
        guard let pointer else { return nil }
        self.init(cString: pointer)
    }
}

/// Borrows C strings for the duration of `body`, in order.
///
/// `withCString` nests, and nesting it by hand for three or four arguments
/// buries the call being made. This flattens it.
func withCStrings<R>(_ strings: [String?], _ body: ([UnsafePointer<CChar>?]) -> R) -> R {
    func step(_ index: Int, _ collected: [UnsafePointer<CChar>?]) -> R {
        if index == strings.count { return body(collected) }
        guard let string = strings[index] else {
            return step(index + 1, collected + [nil])
        }
        return string.withCString { pointer in
            step(index + 1, collected + [pointer])
        }
    }
    return step(0, [])
}

// MARK: - Mutable state that outlives one thread

/// A lock-guarded box. The SDK's shared state is touched from the transport
/// thread, the HTTP worker and the caller's queue, and none of it is hot
/// enough to justify anything finer-grained.
final class Guarded<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value {
        get { withLock { $0 } }
        set { withLock { $0 = newValue } }
    }
}
