import CColyseus
import Foundation

public extension Colyseus {
    /// The room's sense of time.
    ///
    /// Local time is a monotonic millisecond count; server time is an estimate
    /// built from the timestamps the server stamps onto patches, and render
    /// time is that estimate slewed so it never jumps backwards.
    ///
    /// A room whose server never calls `defineInput()` gets no timestamps, and
    /// then ``serverNow`` equals ``now`` and the round-trip figures are zero.
    /// ``Colyseus/Room/ping()`` is the fallback there.
    struct RoomClock: @unchecked Sendable {
        // An opaque C struct, so Swift sees a bare pointer.
        let raw: OpaquePointer?

        init(_ raw: OpaquePointer?) {
            self.raw = raw
        }

        /// Local monotonic milliseconds. This is the timebase
        /// ``Colyseus/Predict/tick(_:)`` expects.
        public var now: Double { raw.map(colyseus_room_clock_now) ?? 0 }

        /// Estimated server time, in the server's own milliseconds.
        public var serverNow: Double { raw.map(colyseus_room_clock_server_now) ?? 0 }

        /// Server time, slew-limited — the timeline to interpolate remote
        /// entities along. Never runs backwards, even when an estimate
        /// correction would.
        public var renderNow: Double { raw.map(colyseus_room_clock_render_now) ?? 0 }

        /// The most recent round trip, in milliseconds.
        public var rtt: Double { raw.map(colyseus_room_clock_rtt) ?? 0 }

        /// Round trip with the spikes smoothed out. Prefer this on a HUD.
        public var smoothedRtt: Double { raw.map(colyseus_room_clock_smoothed_rtt) ?? 0 }

        /// Interarrival jitter, RFC 3550's estimator.
        public var jitter: Double { raw.map(colyseus_room_clock_jitter) ?? 0 }

        /// The server timestamp on the last patch. Watch it change to detect a
        /// patch arriving.
        public var lastServerTime: Double { raw.map(colyseus_room_clock_last_server_time) ?? 0 }

        /// Measured interval between patches, in milliseconds.
        public var patchInterval: Double {
            get { raw.map(colyseus_room_clock_patch_interval) ?? 0 }
            nonmutating set { raw.map { colyseus_room_clock_set_patch_interval($0, newValue) } }
        }

        /// How fast ``renderNow`` is allowed to catch up with a corrected
        /// estimate. Larger is smoother and further behind.
        public var renderTau: Double {
            get { 0 }
            nonmutating set { raw.map { colyseus_room_clock_set_render_tau($0, newValue) } }
        }

        /// Local-to-server offset the estimate currently believes.
        public var offset: Double { raw.map(colyseus_room_clock_offset) ?? 0 }
    }
}
