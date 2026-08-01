import Foundation
import HaruspecCore
import os

/// The runtime capture surface that instrumented code calls into.
///
/// It records the "structured signals" — method entry/exit, notifications, state changes and
/// signpost intervals — and, crucially, *canonicalizes at capture time*: object pointers become
/// first-seen symbolic ids, OS threads become logical threads, and time becomes a logical clock.
/// That is what lets two independent runs of the same scenario produce diffable traces.
///
/// Thread-safe (an `NSLock` guards all mutable state) so it can capture from concurrent code, which
/// is exactly the setting a Swift-6 concurrency migration cares about.
public final class TraceRecorder: @unchecked Sendable {
    public let name: String
    private let clock: TraceClock
    private let lock = NSLock()

    private var events: [TraceEvent] = []
    private var seqCounter = 0
    private var depth = 0

    // Canonicalization maps, assigned in first-seen order for run-stability.
    private var identityMap: [ObjectIdentifier: Int] = [:]
    private var nextIdentity = 1
    private var workerMap: [ObjectIdentifier: Int] = [:]
    private var nextWorker = 1

    /// Mirror intervals to Instruments too, so the same run is inspectable with Apple tooling.
    private let signposter = OSSignposter(subsystem: "com.haruspec.trace", category: "interval")

    public init(name: String, clock: TraceClock = WallClock()) {
        self.name = name
        self.clock = clock
    }

    // MARK: - Public recording API

    /// Record a function/method entry. Increments call-nesting depth.
    public func call(_ label: String, subject: AnyObject? = nil, args: CanonicalValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: .call, label: label, subject: subject, payload: args, duration: nil)
        depth += 1
    }

    /// Record a function/method return. Decrements call-nesting depth first.
    public func ret(_ label: String, subject: AnyObject? = nil, value: CanonicalValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        depth = max(0, depth - 1)
        appendLocked(kind: .ret, label: label, subject: subject, payload: value, duration: nil)
    }

    /// Record a posted notification / broadcast side effect — an observable product behavior, so it
    /// lands in the durable **semantic** tier (its value contract survives code-symbol renames).
    public func notification(_ name: String, subject: AnyObject? = nil, payload: CanonicalValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            kind: .notification,
            label: name,
            subject: subject,
            payload: payload,
            duration: nil,
            tier: .semantic
        )
    }

    /// Record an observable state / property mutation (KVO) — a durable **semantic**-tier side effect.
    public func stateChange(_ label: String, subject: AnyObject? = nil, value: CanonicalValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: .stateChange, label: label, subject: subject, payload: value, duration: nil, tier: .semantic)
    }

    /// Record an outbound call to a **spied collaborator** — a real side effect leaving the SUT across a
    /// declared boundary, so it lands in the durable **semantic** tier. The label is `Class.selector`
    /// (the collaborator's stable public API, not an internal code symbol), and `args` is the
    /// canonicalized argument list. Unlike `call`, it does *not* nest depth: a spied effect is a leaf
    /// observation, not a call frame the SUT's own trace descends into.
    public func effect(_ label: String, subject: AnyObject? = nil, args: CanonicalValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: .effect, label: label, subject: subject, payload: args, duration: nil, tier: .semantic)
    }

    /// Record an application-defined custom telemetry event (structural tier; droppable via `ignoredKinds`).
    public func custom(_ label: String, subject: AnyObject? = nil, payload: CanonicalValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: .custom, label: label, subject: subject, payload: payload, duration: nil)
    }

    /// Record a payload-free **temporal marker** (the semantic tier): a domain-milestone signpost used
    /// to pin ordering / temporal coupling across refactors that reshuffle the structural tier.
    /// Deliberately carries no payload — value verification rides production-observable seams
    /// (notification userInfo, return values, KVO), never hand-authored marker state.
    public func marker(_ label: String, subject: AnyObject? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: .marker, label: label, subject: subject, payload: nil, duration: nil, tier: .semantic)
    }

    /// Time a unit of work as a signpost interval; the measured duration is a *tolerant* trace field.
    @discardableResult
    public func interval<T>(_ label: String, subject: AnyObject? = nil, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval("interval", id: signposter.makeSignpostID())
        let start = clock.now()
        defer { signposter.endInterval("interval", state) }
        let result = try body()
        let elapsed = clock.now() - start
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: .signpost, label: label, subject: subject, payload: nil, duration: elapsed)
        return result
    }

    /// A snapshot of the trace captured so far.
    public func trace() -> Trace {
        lock.lock(); defer { lock.unlock() }
        return Trace(name: name, events: events)
    }

    /// Advance the underlying clock when it is a `ManualClock` (used to model deterministic work cost
    /// in tests); a no-op under a `WallClock`.
    public func advanceClock(_ ticks: Int64) {
        (clock as? ManualClock)?.advance(ticks)
    }

    /// The current clock reading, in ticks. Used by `@Timed` macro-generated timing.
    public func now() -> Int64 {
        clock.now()
    }

    /// Record a pre-measured signpost interval (the duration was computed by the caller). Used by the
    /// `@Timed` method instrumentation, which brackets the whole method itself.
    public func signpost(_ label: String, subject: AnyObject? = nil, durationTicks: Int64) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: .signpost, label: label, subject: subject, payload: nil, duration: durationTicks)
    }

    // MARK: - Locked helpers (callers already hold `lock`)

    private func appendLocked(
        kind: EventKind,
        label: String,
        subject: AnyObject?,
        payload: CanonicalValue?,
        duration: Int64?,
        tier: EventTier = .structural
    ) {
        let event = TraceEvent(
            seq: seqCounter,
            kind: kind,
            label: label,
            thread: currentThreadLocked(),
            subject: symbolicIDLocked(subject),
            payload: payload,
            durationTicks: duration,
            depth: depth,
            tier: tier
        )
        events.append(event)
        seqCounter += 1
    }

    private func symbolicIDLocked(_ subject: AnyObject?) -> Int? {
        guard let subject else { return nil }
        let key = ObjectIdentifier(subject)
        if let existing = identityMap[key] {
            return existing
        }
        let assigned = nextIdentity
        nextIdentity += 1
        identityMap[key] = assigned
        return assigned
    }

    private func currentThreadLocked() -> LogicalThread {
        if Thread.isMainThread {
            return .main
        }
        let key = ObjectIdentifier(Thread.current)
        if let existing = workerMap[key] {
            return .worker(existing)
        }
        let assigned = nextWorker
        nextWorker += 1
        workerMap[key] = assigned
        return .worker(assigned)
    }
}
