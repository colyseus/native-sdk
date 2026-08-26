import Foundation

/// Cancels a handler registered with one of the `on…` methods.
///
/// Cancelling is optional — handlers die with the room — but a handler that
/// outlives what it draws needs to be taken off explicitly.
public final class Subscription: Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() { onCancel() }
}

/// The C API keeps ONE handler per room event, overwriting on re-registration.
/// Every binding has to add the fan-out itself; this is ours.
final class Emitter<Payload>: @unchecked Sendable {
    private var handlers: [(id: Int, body: (Payload) -> Void)] = []
    private var nextID = 0
    private let lock = NSLock()

    func add(_ body: @escaping (Payload) -> Void) -> Subscription {
        lock.lock()
        let id = nextID
        nextID += 1
        handlers.append((id: id, body: body))
        lock.unlock()

        return Subscription { [weak self] in self?.remove(id) }
    }

    func emit(_ payload: Payload) {
        // Copied under the lock so a handler may add or cancel handlers.
        lock.lock()
        let current = handlers
        lock.unlock()

        for handler in current { handler.body(payload) }
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlers.isEmpty
    }

    func removeAll() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }

    private func remove(_ id: Int) {
        lock.lock()
        handlers.removeAll { $0.id == id }
        lock.unlock()
    }
}
