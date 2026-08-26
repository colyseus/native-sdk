import CColyseus
import Foundation

/// Namespace for the SDK, and the home of the runtime controls that are
/// process-wide rather than per-room.
public enum Colyseus {

    // MARK: - Where your code runs

    /// The queue every callback, event and completion is delivered on.
    ///
    /// Defaults to the main queue, which is where a game's frame loop lives.
    /// Set it before creating a client; changing it with rooms open moves
    /// later deliveries but not ones already in flight.
    public static var callbackQueue: DispatchQueue {
        get { runtime.callbackQueue }
        set { runtime.callbackQueue = newValue }
    }

    /// Local monotonic milliseconds — the timebase everything in the SDK
    /// measures against.
    ///
    /// This is the same clock ``Colyseus/RoomClock/now`` reads, available
    /// without a room: a shell that switches between rooms still has to drive
    /// one frame loop, and ``Colyseus/Predict/tick(_:)`` will not accept wall
    /// time (an epoch millisecond count is not a duration from anything the
    /// prediction layer knows about).
    public static var now: Double { colyseus_room_clock_now(nil) }

    // MARK: - Pumping

    /// Release inbound traffic, decode it, advance reconnection, and deliver
    /// everything that came of it.
    ///
    /// Call this once per frame from your render loop, having first turned
    /// ``autoPump`` off. Doing so keeps decoding, prediction and drawing on one
    /// thread and inside one frame:
    ///
    /// ```swift
    /// override func update(_ currentTime: TimeInterval) {
    ///     Colyseus.pump()
    ///     let steps = predict.tick(room.clock.now)
    ///     ...
    /// }
    /// ```
    public static func pump() {
        // Serialized because the inbound queue pops under its own lock but
        // DELIVERS outside it: two pumps at once would decode on two threads,
        // which is the thing serialized inbound exists to prevent. Waiting on
        // a join pumps too, and that can overlap an app's frame loop.
        runtime.pumpLock.lock()
        defer { runtime.pumpLock.unlock() }

        colyseus_netdelay_pump()
        colyseus_reconnect_poll()
    }

    /// Whether the SDK pumps on its own timer (on by default, ~60 Hz).
    ///
    /// Turn it off in an app with a frame loop and call ``pump()`` there
    /// instead — two pumps racing each other put decoding back on a second
    /// thread, which is the thing serialized inbound exists to prevent.
    public static var autoPump: Bool {
        get { runtime.autoPump }
        set { runtime.autoPump = newValue }
    }

    /// How often the automatic pump fires. Ignored while ``autoPump`` is off.
    public static var autoPumpInterval: TimeInterval {
        get { runtime.autoPumpInterval }
        set { runtime.autoPumpInterval = newValue }
    }

    /// Packets held by the latency injector across every room, both directions.
    public static var packetsInFlight: Int {
        Int(colyseus_netdelay_in_flight())
    }

    /// Whether inbound traffic is queued and released inside ``pump()``
    /// (the default) rather than decoded on the transport's own thread.
    ///
    /// Leaving this on is what makes the SDK single-threaded from your side:
    /// schema decoding, input acks and prediction writes all happen while you
    /// are inside `pump()`. It is also the seam ``Colyseus/Room/setLatency(delayMs:jitterMs:)``
    /// injects into, so turning it off disables that too.
    public static var serializedInbound: Bool {
        get { runtime.serializedInbound }
        set { runtime.serializedInbound = newValue }
    }

    static let runtime = Runtime()
}

/// Process-wide SDK state. One instance, held by ``Colyseus``.
final class Runtime: @unchecked Sendable {
    let pumpLock = NSLock()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var _callbackQueue: DispatchQueue = .main
    private var _autoPump = true
    private var _autoPumpInterval: TimeInterval = 1.0 / 60.0
    private var _serializedInbound = true
    private var _defaultRequestTimeout: TimeInterval = 10

    var callbackQueue: DispatchQueue {
        get { lock.withLock { _callbackQueue } }
        set {
            lock.withLock { _callbackQueue = newValue }
            restartTimerIfRunning()
        }
    }

    var autoPump: Bool {
        get { lock.withLock { _autoPump } }
        set {
            lock.withLock { _autoPump = newValue }
            if newValue { startTimerIfNeeded() } else { stopTimer() }
        }
    }

    var autoPumpInterval: TimeInterval {
        get { lock.withLock { _autoPumpInterval } }
        set {
            lock.withLock { _autoPumpInterval = max(newValue, 0.001) }
            restartTimerIfRunning()
        }
    }

    var serializedInbound: Bool {
        get { lock.withLock { _serializedInbound } }
        set { lock.withLock { _serializedInbound = newValue } }
    }

    var defaultRequestTimeout: TimeInterval {
        get { lock.withLock { _defaultRequestTimeout } }
        set { lock.withLock { _defaultRequestTimeout = max(newValue, 0) } }
    }

    /// Run `body` on the callback queue, or inline when already on it.
    ///
    /// The inline path matters: a game that pumps from its frame loop expects
    /// the state it just decoded to be readable in the same frame, not one
    /// dispatch later.
    func deliver(_ body: @escaping @Sendable () -> Void) {
        let queue = callbackQueue
        if isCurrent(queue) {
            body()
        } else {
            queue.async(execute: body)
        }
    }

    /// The pump timer only exists while at least one room is open — an idle
    /// process should not wake 60 times a second.
    func roomOpened() {
        lock.withLock { openRooms += 1 }
        startTimerIfNeeded()
    }

    func roomClosed() {
        let remaining = lock.withLock { () -> Int in
            openRooms = max(0, openRooms - 1)
            return openRooms
        }
        if remaining == 0 { stopTimer() }
    }

    private var openRooms = 0

    private func startTimerIfNeeded() {
        let (shouldRun, queue, interval) = lock.withLock {
            (_autoPump && openRooms > 0 && timer == nil, _callbackQueue, _autoPumpInterval)
        }
        guard shouldRun else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { Colyseus.pump() }
        source.resume()
        lock.withLock { timer = source }
    }

    private func stopTimer() {
        let source = lock.withLock { () -> DispatchSourceTimer? in
            defer { timer = nil }
            return timer
        }
        source?.cancel()
    }

    private func restartTimerIfRunning() {
        guard lock.withLock({ timer != nil }) else { return }
        stopTimer()
        startTimerIfNeeded()
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}

/// `DispatchQueue.main` is the only queue we can ask about cheaply and
/// reliably; for anything else a specific-key probe is needed, and callers who
/// set a custom queue are pumping from it themselves anyway.
private func isCurrent(_ queue: DispatchQueue) -> Bool {
    queue === DispatchQueue.main && Thread.isMainThread
}
