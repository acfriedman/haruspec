import Foundation
import HaruspecCore

/// The ambient recorder that stamped forwarders and doubles record into.
///
/// Using a task-local means an instrumented type needs **no recorder property** — capture is turned
/// on around a spec with `TraceContext.$current.withValue(recorder) { … }`, and every instrumented
/// method inside that dynamic scope records to it. Outside a capture window `current` is nil and the
/// generated code is a cheap nil-check, so instrumentation can ship in production.
///
/// A task-local follows Swift concurrency (`async let`, task groups, `sync`, which never leaves the
/// thread) and nothing else. Work a subject hands off reaches it because the subject hands it to its
/// own injected scheduling seam: the stamped double holds the work in the capture's ``WorkBacklog``,
/// and the engine runs it on the capture's own task with these bindings restored.
public enum TraceContext {
    @TaskLocal public static var current: TraceRecorder?

    /// The recorder actually in effect, and what every capture site reads.
    public static var active: TraceRecorder? {
        current
    }

    /// The declared op the runner is driving (`OpIdentity`), bound around each op of a capture, and
    /// rebound around held work to the op that enqueued it.
    @TaskLocal public static var currentOp: OpIdentity?

    /// The op in effect for an event recorded now — what every recording site stamps on its event.
    public static var activeOp: OpIdentity? {
        currentOp
    }

    /// A cause that has not been claimed yet. A box rather than a value because a task-local cannot be
    /// cleared once bound, and the edge belongs to the held work's *first* event — so consuming has to
    /// mutate something the binding merely points at.
    final class SpawnCause: @unchecked Sendable {
        private let lock = NSLock()
        private var cause: Int?

        init(_ cause: Int?) {
            self.cause = cause
        }

        func take() -> Int? {
            lock.lock(); defer { lock.unlock() }
            defer { cause = nil }
            return cause
        }
    }

    /// The call that enqueued the held work now running, bound by ``WorkBacklog`` around each item.
    @TaskLocal static var pendingSpawnCause: SpawnCause?

    /// Takes the pending spawn cause, if this is the first event since the held work began. Consumed
    /// rather than read: the edge belongs to the work's first event, and program order does the rest.
    static func consumePendingSpawnCause() -> Int? {
        pendingSpawnCause?.take()
    }
}

/// Explicit, ambient-aware hooks for the few things a body macro can't infer from a signature:
/// timing regions and temporal markers. Each is a no-op when no capture is active.
public enum Haruspec {
    /// Measures `body` as a signpost interval on the ambient recorder, or just runs it when no capture
    /// is active. `isolation` is taken at the caller so the interval's domain resolves to the *app's*
    /// call site, not this file's.
    ///
    /// - Parameters:
    ///   - label: The interval's event label.
    ///   - subject: The instance the region belongs to; `nil` for none.
    ///   - isolation: The actor the caller runs on, defaulted at the call site; `nil` means no actor.
    ///   - body: The region to measure.
    /// - Returns: Whatever `body` returned.
    /// - Throws: Whatever `body` threw; a region that throws records no interval.
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

    /// Advances the capture's deterministic clock to model representative work cost (no-op under a
    /// wall clock or with no active capture). Used to make interval durations reproducible in tests.
    public static func simulateCost(_ ticks: Int64) {
        TraceContext.active?.advanceClock(ticks)
    }

    /// Records a payload-free **temporal marker** (the semantic tier) against the ambient recorder — a
    /// signpost at a domain milestone (`Haruspec.marker("checkout_completed")`) for pinning ordering and
    /// temporal coupling across refactors that reshuffle the structural tier (e.g. imperative →
    /// reactive). It carries no payload by design: verify *values* through production seams
    /// (notification userInfo, return values, KVO), not through instrumentation you authored — so the
    /// oracle checks real behavior, not itself.
    public static func marker(_ label: String, subject: AnyObject? = nil, isolation: (any Actor)? = #isolation) {
        TraceContext.active?.marker(label, subject: subject, isolation: isolation)
    }
}
