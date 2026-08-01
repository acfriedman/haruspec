import Foundation

/// Source of monotonic "ticks" for signpost intervals.
///
/// Abstracting the clock is what makes captured timing *replayable*: production capture uses a real
/// wall clock, while tests inject a `ManualClock` so interval durations are exact and deterministic
/// (no clock jitter to canonicalize away).
public protocol TraceClock: Sendable {
    func now() -> Int64
}

/// Real monotonic time in nanoseconds.
public struct WallClock: TraceClock {
    public init() {}
    public func now() -> Int64 {
        Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
    }
}

/// A deterministic clock advanced explicitly by the code under test to model representative "cost".
public final class ManualClock: TraceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: Int64

    public init(start: Int64 = 0) {
        ticks = start
    }

    public func now() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return ticks
    }

    public func advance(_ delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        ticks += delta
    }
}
