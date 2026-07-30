import Foundation
import HaruspecCore

/// The ambient recorder that `@Traced` methods record into.
///
/// Using a task-local means an instrumented type needs **no recorder property** — capture is turned
/// on around a scenario with `TraceContext.$current.withValue(recorder) { … }`, and every `@Traced`
/// method inside that dynamic scope records to it. Outside a capture window `current` is nil and the
/// generated code is a cheap nil-check, so instrumentation can ship in production.
///
/// Caveat (v0): a task-local does not automatically cross a manual thread hop (e.g. `DispatchQueue`);
/// capturing across such hops needs explicit propagation, a later refinement.
public enum TraceContext {
    @TaskLocal public static var current: TraceRecorder?
}

/// Explicit, ambient-aware hooks for the few things a body macro can't infer from a signature:
/// timing regions and temporal markers. Each is a no-op when no capture is active.
public enum Haruspec {
    /// Measure a region as a signpost interval, recording to the ambient recorder if present.
    @discardableResult
    public static func interval<T>(_ label: String, subject: AnyObject? = nil, _ body: () throws -> T) rethrows -> T {
        if let recorder = TraceContext.current {
            return try recorder.interval(label, subject: subject, body)
        }
        return try body()
    }

    /// Advance the capture's deterministic clock to model representative work cost (no-op under a
    /// wall clock or with no active capture). Used to make interval durations reproducible in tests.
    public static func simulateCost(_ ticks: Int64) {
        TraceContext.current?.advanceClock(ticks)
    }

    /// Record a payload-free **temporal marker** (the semantic tier) against the ambient recorder — a
    /// signpost at a domain milestone (`Haruspec.marker("checkout_completed")`) for pinning ordering and
    /// temporal coupling across refactors that reshuffle the structural tier (e.g. imperative →
    /// reactive). It carries no payload by design: verify *values* through production seams
    /// (notification userInfo, return values, KVO), not through instrumentation you authored — so the
    /// oracle checks real behavior, not itself.
    public static func marker(_ label: String, subject: AnyObject? = nil) {
        TraceContext.current?.marker(label, subject: subject)
    }
}
