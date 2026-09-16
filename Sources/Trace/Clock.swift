import Foundation

/// Source of monotonic "ticks" for signpost intervals.
///
/// Abstracting the clock is what makes captured timing *replayable*: production capture uses a real
/// wall clock, while tests inject a `ManualClock` so interval durations are exact and deterministic
/// (no clock jitter to canonicalize away).
public protocol TraceClock: Sendable {
    /// Returns the clock's current reading in ticks. Only differences between readings carry meaning;
    /// an interval's duration is the reading at exit minus the reading at entry.
    ///
    /// - Returns: A tick count that never decreases between two calls on the same clock.
    func now() -> Int64
}

/// Real monotonic time in nanoseconds.
public struct WallClock: TraceClock {
    /// Creates a clock over the process's monotonic uptime.
    public init() {}
    // gloss:exempt implements TraceClock.now(), documented on the protocol
    public func now() -> Int64 {
        Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
    }
}

/// A deterministic clock advanced explicitly by the code under test to model representative "cost".
public final class ManualClock: TraceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: Int64

    /// Creates a clock reading `start` that moves only when ``advance(_:)`` is called.
    ///
    /// - Parameter start: The first reading ``now()`` returns; zero by default.
    public init(start: Int64 = 0) {
        ticks = start
    }

    // gloss:exempt implements TraceClock.now(), documented on the protocol
    public func now() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return ticks
    }

    /// Moves the clock forward by `delta` ticks. Modeling cost this way is what makes a recorded
    /// duration exact and reproducible across runs.
    ///
    /// - Parameter delta: Ticks to add; keep it non-negative so the clock stays monotonic.
    public func advance(_ delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        ticks += delta
    }
}
