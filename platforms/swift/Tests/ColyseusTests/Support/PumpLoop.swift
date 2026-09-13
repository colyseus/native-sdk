import CColyseus
import Foundation
@testable import Colyseus

/// A game's frame loop on a thread of its own: each turn runs the jobs queued
/// for it, then pumps. Tests make their SDK calls through it, the way a game
/// makes them from its update, and check which thread callbacks come back on.
final class PumpLoop: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    private var running = true
    private var pumping = true
    private var threadID: pthread_t?
    private let stopped = DispatchSemaphore(value: 0)
    /// Only touched on the loop's own thread.
    private var insidePump = false

    init() {
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            lock.withLock { threadID = pthread_self() }
            started.signal()
            run()
            stopped.signal()
        }
        thread.name = "PumpLoop"
        thread.start()
        started.wait()
    }

    var isCurrent: Bool {
        lock.withLock { threadID.map { pthread_equal($0, pthread_self()) != 0 } ?? false }
    }

    /// Whether the caller is the loop's thread, inside its `Colyseus.pump()`.
    var isInsidePump: Bool { isCurrent && insidePump }

    /// Whether each turn pumps. Setting it returns once the loop has seen the
    /// change, so after `false` no pump is in flight and none will start.
    var isPumping: Bool {
        get { lock.withLock { pumping } }
        set {
            lock.withLock { pumping = newValue }
            sync {}
        }
    }

    /// Queue `body` for the start of the loop's next turn.
    func post(_ body: @escaping () -> Void) {
        lock.withLock { jobs.append(body) }
    }

    /// Run `body` on the loop's thread, between two pumps, and wait for it.
    func sync<R>(_ body: @escaping () -> R) -> R {
        let done = DispatchSemaphore(value: 0)
        var result: R?
        post {
            result = body()
            done.signal()
        }
        done.wait()
        return result!
    }

    func stop() {
        lock.withLock { running = false }
        stopped.wait()
    }

    private func run() {
        while true {
            let (queued, alive) = lock.withLock { () -> ([() -> Void], Bool) in
                defer { jobs.removeAll() }
                return (jobs, running)
            }
            for job in queued { job() }
            guard alive else { return }

            if lock.withLock({ pumping }) {
                insidePump = true
                Colyseus.pump()
                insidePump = false
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

/// Where each callback ran, in the order they ran.
final class ThreadTrace: @unchecked Sendable {
    struct Entry: CustomStringConvertible {
        let event: String
        let onLoop: Bool
        let insidePump: Bool

        var description: String {
            let place = !onLoop ? "another thread" : insidePump ? "the loop's pump" : "the loop, outside its pump"
            return "\(event) on \(place)"
        }
    }

    private let loop: PumpLoop
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(_ loop: PumpLoop) {
        self.loop = loop
    }

    func record(_ event: String) {
        let entry = Entry(event: event, onLoop: loop.isCurrent, insidePump: loop.isInsidePump)
        lock.withLock { entries.append(entry) }
    }

    var all: [Entry] { lock.withLock { entries } }
    var count: Int { lock.withLock { entries.count } }

    func count(of event: String) -> Int {
        all.filter { $0.event == event }.count
    }

    /// Everything that ran anywhere but inside the loop's pump.
    var strays: [String] {
        all.filter { !($0.onLoop && $0.insidePump) }.map(\.description)
    }
}

/// A matchmaking call made straight through the C API, so a test can see the
/// thread its callback runs on — the Swift surface only shows the await.
final class JoinProbe: @unchecked Sendable {
    private let opened: (UnsafeMutablePointer<colyseus_room_t>) -> Void
    private let failed: (String) -> Void

    init(
        opened: @escaping (UnsafeMutablePointer<colyseus_room_t>) -> Void,
        failed: @escaping (String) -> Void
    ) {
        self.opened = opened
        self.failed = failed
    }

    func create(on client: Colyseus.Client, _ roomName: String, options: String) {
        colyseus_client_create_room(client.raw, roomName, options, probeOnRoom, probeOnError, retainedPointer(self))
    }

    func joinById(on client: Colyseus.Client, _ roomId: String) {
        colyseus_client_join_by_id(client.raw, roomId, "{}", probeOnRoom, probeOnError, retainedPointer(self))
    }

    fileprivate func open(_ room: UnsafeMutablePointer<colyseus_room_t>?) {
        if let room { opened(room) } else { failed("no room") }
    }

    fileprivate func fail(_ message: String) { failed(message) }
}

private let probeOnRoom: colyseus_client_room_callback_t = { room, userdata in
    consumeObject(userdata, as: JoinProbe.self)?.open(room)
}

private let probeOnError: colyseus_client_error_callback_t = { _, message, userdata in
    consumeObject(userdata, as: JoinProbe.self)?.fail(String(nullableCString: message) ?? "")
}
