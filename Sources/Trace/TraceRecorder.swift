import Foundation
import HaruspecCore
import os

/// The runtime capture surface that instrumented code calls into.
///
/// It records the "structured signals" — method entry/exit, notifications, state changes and
/// signpost intervals — and, crucially, *canonicalizes at capture time*: object pointers become
/// first-seen symbolic ids, OS threads become logical threads, and time becomes a logical clock.
/// That is what lets two independent runs of the same spec produce diffable traces.
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

    /// The traced calls still in progress, per thread; see ``CallStacks``.
    private var calls = CallStacks()

    // Symbolic identity, assigned in first-seen order for run-stability. Covers traced subjects and
    // actor domain instances alike.
    private var identityMap: [ObjectIdentifier: Int] = [:]
    private var nextIdentity = 1

    /// Mirrors intervals to Instruments too, so the same run is inspectable with Apple tooling.
    private let signposter = OSSignposter(subsystem: "com.haruspec.trace", category: "interval")

    /// The audit's source map for this capture, picked up from the ambient binding (see `TraceOrigins`).
    /// Held here rather than looked up per call because a traced method can run on a thread with no
    /// task — the same reason `TraceContext` keeps a thread-local beside its task-local.
    private let origins: OriginCollector?

    /// Creates a recorder for one capture, stamping every event with `clock`. The audit's origin
    /// collector is read from the ambient binding here, once, because a traced method may later
    /// run on a thread with no task to read it from.
    ///
    /// - Parameters:
    ///   - name: The capture's name, carried into the trace and every report about it.
    ///   - clock: The time source for event ordering; defaults to wall time, and tests inject a
    ///     virtual clock to make sequences deterministic.
    public init(name: String, clock: TraceClock = WallClock()) {
        self.name = name
        self.clock = clock
        origins = TraceOrigins.collector
    }

    // MARK: - Public recording API

    /// Registers where a traced label is declared. Emitted by the stamped forwarder and double into
    /// every instrumented body, so a label registers exactly when it is reached under capture. Cheap when
    /// nothing is collecting (a nil check), and idempotent — the collector is a set.
    public func noteOrigin(_ label: String, symbol: String? = nil, source: String? = nil) {
        origins?.note(TraceOrigin(label: label, symbol: symbol, source: source))
    }

    /// Records a function or method entry and deepens call nesting by one. Every `call` expects a
    /// matching `ret`; the pairing is what turns the flat event list back into a call tree.
    ///
    /// - Parameters:
    ///   - label: The event label, as `"<type>.<method>"`.
    ///   - subject: The instance the call was made on; `nil` for a static or free function.
    ///   - args: The arguments, canonicalized and keyed by internal parameter name; `nil` records none.
    ///   - isolation: The actor the caller runs on, defaulted at the call site; `nil` means no actor.
    /// - Returns: The call, which a forwarder binds around its body with ``TraceContext/withOpenCall(_:_:)``.
    @discardableResult
    public func call(
        _ label: String,
        subject: AnyObject? = nil,
        args: CanonicalValue? = nil,
        isolation: (any Actor)? = #isolation
    ) -> TraceContext.OpenCall {
        lock.lock(); defer { lock.unlock() }
        let seq = seqCounter
        appendLocked(isolation: isolation, kind: .call, label: label, subject: subject, payload: args)
        depth += 1
        return TraceContext.OpenCall(seq: seq, domain: events[events.count - 1].domain)
    }

    /// Records a function or method return and shallows call nesting by one, never below zero. The
    /// counterpart of `call`; an unmatched return is tolerated rather than trapped.
    ///
    /// - Parameters:
    ///   - label: The event label, matching the `call` it closes.
    ///   - subject: The instance the call was made on; `nil` for a static or free function.
    ///   - value: The return value, canonicalized; `nil` for `Void` or a value not recorded.
    ///   - isolation: The actor the caller runs on, defaulted at the call site; `nil` means no actor.
    public func ret(
        _ label: String,
        subject: AnyObject? = nil,
        value: CanonicalValue? = nil,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        depth = max(0, depth - 1)
        appendLocked(isolation: isolation, kind: .ret, label: label, subject: subject, payload: value)
    }

    /// Records a posted notification / broadcast side effect — an observable product behavior, so it
    /// lands in the durable **semantic** tier (its value contract survives code-symbol renames).
    public func notification(
        _ name: String,
        subject: AnyObject? = nil,
        payload: CanonicalValue? = nil,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            isolation: isolation,
            kind: .notification,
            label: name,
            subject: subject,
            payload: payload,
            tier: .semantic
        )
    }

    /// Records an observable state / property mutation (KVO) — a durable **semantic**-tier side effect.
    public func stateChange(
        _ label: String,
        subject: AnyObject? = nil,
        value: CanonicalValue? = nil,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            isolation: isolation,
            kind: .stateChange,
            label: label,
            subject: subject,
            payload: value,
            tier: .semantic
        )
    }

    /// Records a property value the harness itself read back at the capture boundary — the state
    /// contract's gate (the harness did the reading, so no side's instrumentation is being trusted).
    /// Semantic tier, like every observable product behavior.
    public func snapshot(
        _ label: String,
        subject: AnyObject? = nil,
        value: CanonicalValue? = nil,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            isolation: isolation,
            kind: .snapshot,
            label: label,
            subject: subject,
            payload: value,
            tier: .semantic
        )
    }

    /// Records an outbound call to a **spied collaborator** — a real side effect leaving the SUT across a
    /// declared boundary, so it lands in the durable **semantic** tier.
    ///
    /// - Parameters:
    ///   - label: The collaborator's stable public API as `<Class>.<selector>`, not an internal code
    ///     symbol.
    ///   - subject: The collaborator instance the call was made on; `nil` for a static or free function.
    ///   - args: The arguments, canonicalized; `nil` records none.
    ///   - isolation: The actor the caller runs on, defaulted at the call site; `nil` means no actor.
    ///
    /// Unlike `call`, it does *not* nest depth: a spied effect is a leaf observation, not a call frame
    /// the SUT's own trace descends into.
    public func effect(
        _ label: String,
        subject: AnyObject? = nil,
        args: CanonicalValue? = nil,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            isolation: isolation,
            kind: .effect,
            label: label,
            subject: subject,
            payload: args,
            tier: .semantic
        )
    }

    /// Records a virtual timer's surviving fire — the temporal contract a deferred pipeline states
    /// in code (a debounce's quiet period, a delay's interval), carried as data because under
    /// virtual time the requested delay is *declared at the seam*, never measured. Semantic tier:
    /// how long a pipeline waits before answering is behavior a user feels, so a changed delay
    /// gates like any value.
    public func timerFired(
        delay: CanonicalValue,
        subject: AnyObject? = nil,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            isolation: isolation,
            kind: .timer,
            label: "timer",
            subject: subject,
            payload: delay,
            tier: .semantic
        )
    }

    /// Records an application-defined custom telemetry event (structural tier; droppable via `ignoredKinds`).
    public func custom(
        _ label: String,
        subject: AnyObject? = nil,
        payload: CanonicalValue? = nil,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            isolation: isolation,
            kind: .custom,
            label: label,
            subject: subject,
            payload: payload
        )
    }

    /// Records a payload-free **temporal marker** (the semantic tier): a domain-milestone signpost used
    /// to pin ordering / temporal coupling across refactors that reshuffle the structural tier.
    /// Deliberately carries no payload — see ``Haruspec/marker`` for why.
    ///
    /// - Parameters:
    ///   - label: The milestone's name.
    ///   - subject: The instance the milestone belongs to; `nil` when there is none.
    ///   - isolation: The actor the caller runs on, defaulted at the call site; `nil` means no actor.
    public func marker(_ label: String, subject: AnyObject? = nil, isolation: (any Actor)? = #isolation) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(
            isolation: isolation,
            kind: .marker,
            label: label,
            subject: subject,
            payload: nil,
            tier: .semantic
        )
    }

    /// Times a unit of work as a signpost interval; the measured duration is a budgeted trace field.
    @discardableResult
    public func interval<T>(
        _ label: String,
        subject: AnyObject? = nil,
        isolation: (any Actor)? = #isolation,
        _ body: () throws -> T
    ) rethrows -> T {
        let state = signposter.beginInterval("interval", id: signposter.makeSignpostID())
        let start = clock.now()
        defer { signposter.endInterval("interval", state) }
        let result = try body()
        let elapsed = clock.now() - start
        lock.lock(); defer { lock.unlock() }
        appendSignpostLocked(isolation: isolation, label: label, subject: subject, durationTicks: elapsed)
        return result
    }

    /// How many events have been recorded so far: progress, for a watchdog.
    var eventCount: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }

    /// A snapshot of the trace captured so far.
    public func trace() -> Trace {
        lock.lock(); defer { lock.unlock() }
        return Trace(name: name, events: events)
    }

    /// Advances the underlying clock when it is a `ManualClock` (used to model deterministic work cost
    /// in tests); a no-op under a `WallClock`.
    public func advanceClock(_ ticks: Int64) {
        (clock as? ManualClock)?.advance(ticks)
    }

    /// The traced call in progress on this thread, if any — the cause a seam records when it hands
    /// work to another queue or task. Read at the *enqueue*, which is the only moment both ends of the
    /// edge are known.
    public func enclosingCallSeq() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return calls.enclosing()?.seq
    }

    /// The sequence number the next event will carry: the floor held work binds, so a call it opens
    /// encloses and a call already open on its thread does not.
    var nextSeq: Int {
        lock.lock(); defer { lock.unlock() }
        return seqCounter
    }

    /// The current clock reading, in ticks. Used by a timed forwarder's generated timing.
    public func now() -> Int64 {
        clock.now()
    }

    /// Records a pre-measured signpost interval (the duration was computed by the caller). Used by a
    /// timed forwarder (`@Haruspec(_:timed:)`), which brackets the whole forwarded call itself.
    public func signpost(
        _ label: String,
        subject: AnyObject? = nil,
        durationTicks: Int64,
        isolation: (any Actor)? = #isolation
    ) {
        lock.lock(); defer { lock.unlock() }
        appendSignpostLocked(isolation: isolation, label: label, subject: subject, durationTicks: durationTicks)
    }

    // MARK: - Locked helpers (callers already hold `lock`)

    private func appendLocked(
        isolation: (any Actor)?,
        kind: EventKind,
        label: String,
        subject: AnyObject?,
        payload: CanonicalValue?,
        tier: EventTier = .structural
    ) {
        let domain = attributedDomainLocked(isolation, kind: kind)
        appendLocked(TraceEvent(
            seq: seqCounter,
            kind: kind,
            label: label,
            domain: domain,
            subject: symbolicIDLocked(subject),
            payload: payload,
            depth: depth,
            tier: tier,
            spawnedBy: TraceContext.consumePendingSpawnCause(in: domain),
            op: TraceContext.activeOp
        ))
    }

    /// Only a `.signpost` carries a duration, so the timed path is its own entry point rather than a
    /// `durationTicks:` every other kind has to pass `nil` to.
    private func appendSignpostLocked(
        isolation: (any Actor)?,
        label: String,
        subject: AnyObject?,
        durationTicks: Int64
    ) {
        let domain = attributedDomainLocked(isolation, kind: .signpost)
        appendLocked(TraceEvent(
            seq: seqCounter,
            kind: .signpost,
            label: label,
            domain: domain,
            subject: symbolicIDLocked(subject),
            durationTicks: durationTicks,
            depth: depth,
            spawnedBy: TraceContext.consumePendingSpawnCause(in: domain),
            op: TraceContext.activeOp
        ))
    }

    /// The domain an event is *attributed* to, which is not always the one it executed in.
    ///
    /// A notification travels through Foundation and a collaborator call through a decorator; both
    /// arrive one frame from the subject, isolated to nothing, and would resolve to `ambient` however
    /// they were captured. But the work that caused them is on the stack, and its domain is the honest
    /// answer: an effect belongs to whatever emitted it.
    ///
    /// Only `ambient` inherits. An event that resolved to an actor or a queue knows its own domain and
    /// is never overridden by its caller's.
    private func attributedDomainLocked(_ isolation: (any Actor)?, kind: EventKind) -> ConcurrencyDomain {
        var domain = domainLocked(isolation)
        if domain == .ambient, let enclosing = calls.enclosing()?.domain {
            domain = enclosing
        }
        switch kind {
        case .call:
            calls.push(TraceContext.OpenCall(seq: seqCounter, domain: domain))
        case .ret:
            calls.pop()
        default:
            break
        }
        return domain
    }

    /// Resolves the domain for an event, reusing `symbolicIDLocked` so an actor that is also a traced
    /// subject carries one identity in both places.
    private func domainLocked(_ isolation: (any Actor)?) -> ConcurrencyDomain {
        DomainResolver.resolve(isolation: isolation, instanceID: symbolicIDLocked)
    }

    private func symbolicIDLocked(_ subject: AnyObject?) -> Int? {
        subject.map { symbolicIDLocked($0) }
    }

    private func symbolicIDLocked(_ subject: AnyObject) -> Int {
        let key = ObjectIdentifier(subject)
        if let existing = identityMap[key] {
            return existing
        }
        let assigned = nextIdentity
        nextIdentity += 1
        identityMap[key] = assigned
        return assigned
    }

    private func appendLocked(_ event: TraceEvent) {
        events.append(event)
        seqCounter += 1
    }
}
