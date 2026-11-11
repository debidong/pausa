import Darwin
import Foundation

/// Explicit clock abstraction separating sleep-inclusive monotonic time from awake-only uptime
/// and wall-clock time, while allowing deterministic injection in unit tests.
struct PausaClock: Sendable {
    /// Monotonic seconds that keep advancing while the Mac is asleep (`CLOCK_MONOTONIC` on Darwin).
    /// Used by `AppController` / `Scheduler` so sleep duration in `handleAway` is measured accurately.
    var continuousNow: @Sendable () -> Double

    /// Monotonic seconds of awake system uptime (`CLOCK_UPTIME_RAW` / `systemUptime`), which pauses
    /// while the Mac sleeps. Used for live countdowns, hold-to-skip gestures and detector grace windows.
    var uptimeNow: @Sendable () -> Double

    /// Wall-clock date (`Date()`), used for schedule windows, persisted quit-to-launch gaps and logs.
    var wallNow: @Sendable () -> Date

    static let system = PausaClock(
        continuousNow: { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 },
        uptimeNow: { ProcessInfo.processInfo.systemUptime },
        wallNow: { Date() }
    )
}
