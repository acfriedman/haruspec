import Foundation
import HaruspecCore

/// The ambient recorder that `@Traced` methods record into.
///
/// Using a task-local means an instrumented type needs **no recorder property** — capture is turned
/// on around a spec with `TraceContext.$current.withValue(recorder) { … }`, and every `@Traced`
/// method inside that dynamic scope records to it. Outside a capture window `current` is nil and the
/// generated code is a cheap nil-check, so instrumentation can ship in production.
///
/// A task-local does not cross a manual thread hop on its own. Swift concurrency inherits it — `Task { }`,
/// `async let`, task groups, and `DispatchQueue.sync`, which never leaves the thread — but a
/// `dispatch_async` block runs with no task at all. The GCD preprocessing seam
/// (`Sources/DispatchSeam/haruspec_dispatch.h`) closes that, and `active` is where the two bindings meet.
public enum TraceContext {
    @TaskLocal public static var current: TraceRecorder?

    private static let threadKey = "com.haruspec.trace.recorder"

    /// The recorder actually in effect, and what every capture site reads.
    ///
    /// Two bindings, because two mechanisms are needed. The task-local carries the capture window
    /// through Swift concurrency, which inherits it across `Task { }`, `async let` and task groups. The
    /// per-thread binding carries it into a block the GCD seam handed to a thread with no task at all —
    /// the case a task-local structurally cannot reach.
    ///
    /// The seam does not rebind the *task*-local: pushing one from inside a run-loop callback that is
    /// itself nested in an actor-isolated binding violates the task-local stack discipline and traps.
    /// A thread-local has no such ordering contract, which is the right shape for work that arrives on
    /// a borrowed thread.
    public static var active: TraceRecorder? {
        current ?? Thread.current.threadDictionary[threadKey] as? TraceRecorder
    }

    /// Bind `recorder` for the duration of `body` on *this thread only*, restoring whatever was there.
    /// Used by the GCD seam around each wrapped block.
    static func withThreadRecorder<T>(_ recorder: TraceRecorder, _ body: () -> T) -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[threadKey]
        dictionary[threadKey] = recorder
        defer { dictionary[threadKey] = previous }
        return body()
    }
}

/// Explicit, ambient-aware hooks for the few things a body macro can't infer from a signature:
/// timing regions and temporal markers. Each is a no-op when no capture is active.
public enum Haruspec {
    /// Measure a region as a signpost interval, recording to the ambient recorder if present.
    /// `isolation` is forwarded rather than defaulted again inside, so the domain resolves to the
    /// *app's* call site — defaulting it here would resolve every interval to this file's context.
    @discardableResult
    public static func interval<T>(
        _ label: String,
        subject: AnyObject? = nil,
        isolation: (any Actor)? = #isolation,
        _ body: () throws -> T
    ) rethrows -> T {
        if let recorder = TraceContext.active {
            return try recorder.interval(label, subject: subject, isolation: isolation, body)
        }
        return try body()
    }

    /// Advance the capture's deterministic clock to model representative work cost (no-op under a
    /// wall clock or with no active capture). Used to make interval durations reproducible in tests.
    public static func simulateCost(_ ticks: Int64) {
        TraceContext.active?.advanceClock(ticks)
    }

    /// Record a payload-free **temporal marker** (the semantic tier) against the ambient recorder — a
    /// signpost at a domain milestone (`Haruspec.marker("checkout_completed")`) for pinning ordering and
    /// temporal coupling across refactors that reshuffle the structural tier (e.g. imperative →
    /// reactive). It carries no payload by design: verify *values* through production seams
    /// (notification userInfo, return values, KVO), not through instrumentation you authored — so the
    /// oracle checks real behavior, not itself.
    public static func marker(_ label: String, subject: AnyObject? = nil, isolation: (any Actor)? = #isolation) {
        TraceContext.active?.marker(label, subject: subject, isolation: isolation)
    }
}
