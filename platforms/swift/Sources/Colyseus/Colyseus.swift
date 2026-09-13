import CColyseus
import Foundation

/// Namespace for the SDK, and the home of the runtime controls that are
/// process-wide rather than per-room.
public enum Colyseus {

    // MARK: - Where your code runs

    /// The queue the automatic pump runs on — and so, while ``autoPump`` is
    /// on, the queue every callback, event and completion arrives on.
    ///
    /// Defaults to the main queue, which is where a game's frame loop lives.
    /// Set it before creating a client. With ``autoPump`` off, callbacks run
    /// wherever you call ``pump()`` instead.
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

    /// Run the SDK, and deliver everything that came of it.
    ///
    /// Nothing in the SDK runs on a thread of its own: matchmaking replies,
    /// socket reads and schema decoding, injected latency and reconnection
    /// all advance inside this call. Every room callback runs inside it too,
    /// on the calling thread — `onJoin`, `onStateChange`, messages, schema
    /// callbacks, `onError`, `onDrop`, `onReconnect` and `onLeave`. Nothing is
    /// delivered between pumps, so state read on the pumping thread never
    /// changes under you.
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
    ///
    /// A call from inside a callback returns without doing anything.
    public static func pump() {
        runtime.pump(external: true)
    }

    /// Whether the SDK pumps on its own timer, on ``callbackQueue`` (on by
    /// default, ~60 Hz).
    ///
    /// Turn it off in an app with a frame loop and call ``pump()`` there
    /// instead; pumping from two threads splits your callbacks between them.
    /// Until that loop is running, awaiting a join, a reconnect or an HTTP
    /// call pumps for you, so `try await client.joinOrCreate(...)` finishes
    /// with no loop at all.
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

    /// Always true: inbound traffic is decoded inside ``pump()`` and nowhere
    /// else, so there is no longer anything to switch off.
    @available(*, deprecated, message: "Inbound traffic is always decoded inside Colyseus.pump(); this setting does nothing.")
    public static var serializedInbound: Bool {
        get { true }
        set {}
    }

    static let runtime = Runtime()
}

/// Process-wide SDK state. One instance, held by ``Colyseus``.
final class Runtime: @unchecked Sendable {
    /// Held for a whole pump, and by anything that must not overlap one.
    private let pumpLock = NSLock()
    /// Guards everything below.
    private let lock = NSLock()
    private var pumpingThread: pthread_t?
    private var held: [@Sendable () -> Void] = []
    private var lastExternalPump: TimeInterval = -.infinity
    private var activity = 0
    private var timer: DispatchSourceTimer?
    private var _callbackQueue: DispatchQueue = .main
    private var _autoPump = true
    private var _autoPumpInterval: TimeInterval = 1.0 / 60.0
    private var _defaultRequestTimeout: TimeInterval = 10

    /// How long the app's own pumps may pause before an await pumps for it.
    /// Short enough that a tool with no loop joins promptly; long enough that
    /// a frame loop's ordinary gap between frames doesn't hand a pump away.
    private static let assistAfter: TimeInterval = 0.1

    init() {
        // The core reads the mode per socket and request, when it starts —
        // this has to run before the first connect.
        colyseus_set_polled(true)
    }

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

    var defaultRequestTimeout: TimeInterval {
        get { lock.withLock { _defaultRequestTimeout } }
        set { lock.withLock { _defaultRequestTimeout = max(newValue, 0) } }
    }

    // MARK: - Pumping

    /// Whether the calling thread is inside ``pump(external:)`` right now.
    var isPumpingThread: Bool {
        lock.withLock { pumpingThread.map { pthread_equal($0, pthread_self()) != 0 } ?? false }
    }

    /// One pump. `external` is the app's (or the timer's), as opposed to one
    /// an await runs because nobody else is pumping.
    func pump(external: Bool) {
        // From a callback: the lock isn't recursive, and the core ignores a
        // nested poll anyway.
        if isPumpingThread { return }

        pumpLock.lock()
        defer { pumpLock.unlock() }

        let earlier = lock.withLock { () -> [@Sendable () -> Void] in
            pumpingThread = pthread_self()
            if external { lastExternalPump = ProcessInfo.processInfo.systemUptime }
            defer { held.removeAll() }
            return held
        }
        defer { lock.withLock { pumpingThread = nil } }

        // Held events happened before anything this poll reads.
        for body in earlier { body() }
        colyseus_poll()
    }

    /// Run `body` with no pump in flight on another thread — for the room
    /// calls that tear down or rewire what a pump reads.
    func exclusive<R>(_ body: () throws -> R) rethrows -> R {
        if isPumpingThread { return try body() }
        pumpLock.lock()
        defer { pumpLock.unlock() }
        return try body()
    }

    /// Hand `body` to the pumping thread: now when this is that thread,
    /// otherwise at the start of the next pump.
    ///
    /// What arrives here off a pump is a close the core reported
    /// synchronously: `leave(consented: false)`, `dropConnection()`, a room
    /// freed while connected.
    func deliver(_ body: @escaping @Sendable () -> Void) {
        if isPumpingThread { return body() }
        lock.withLock { held.append(body) }
        startTimerIfNeeded()
    }

    // MARK: - Waiting on the core

    /// Suspend until `isDone`, which some pump will make true.
    ///
    /// With ``Colyseus/autoPump`` on, the timer pumps. With it off the app
    /// does — and until its loop is running (no pump for `assistAfter`), this
    /// pumps instead, so an await never depends on a loop that isn't there.
    func wait(until isDone: @Sendable () -> Bool) async throws {
        begin()
        defer { end() }

        while !isDone() {
            if shouldAssist {
                pump(external: false)
                if isDone() { return }
            }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    /// Start a C call whose callback settles `completion`, and await it.
    func perform<Value: Sendable>(_ completion: Completion<Value>, _ start: () -> Void) async throws -> Value {
        start()
        try await wait { completion.result != nil }
        return try completion.result!.get() // wait returned, so it settled
    }

    private var shouldAssist: Bool {
        lock.withLock {
            !_autoPump && ProcessInfo.processInfo.systemUptime - lastExternalPump > Self.assistAfter
        }
    }

    // MARK: - The automatic pump

    /// Something needs pumping: an open room, or an await in flight. The
    /// timer only runs while there is — an idle process should not wake 60
    /// times a second.
    func begin() {
        lock.withLock { activity += 1 }
        startTimerIfNeeded()
    }

    /// The timer notices on its next tick, after one more pump has delivered
    /// whatever the last thing left behind — a closed room's `onLeave`.
    func end() {
        lock.withLock { activity = max(0, activity - 1) }
    }

    private func startTimerIfNeeded() {
        lock.withLock {
            guard _autoPump, activity > 0 || !held.isEmpty, timer == nil else { return }

            let source = DispatchSource.makeTimerSource(queue: _callbackQueue)
            source.schedule(deadline: .now() + _autoPumpInterval, repeating: _autoPumpInterval)
            source.setEventHandler { [weak self] in
                Colyseus.pump()
                self?.stopTimerIfIdle()
            }
            source.resume()
            timer = source
        }
    }

    private func stopTimerIfIdle() {
        let source = lock.withLock { () -> DispatchSourceTimer? in
            guard activity == 0, held.isEmpty else { return nil }
            defer { timer = nil }
            return timer
        }
        source?.cancel()
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
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
