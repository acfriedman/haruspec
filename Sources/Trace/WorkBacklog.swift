import Foundation
import HaruspecCore

/// How a stamped scheduling protocol orders the work it is handed: the fact a production queue
/// states when it is created (`DISPATCH_QUEUE_SERIAL`, `.concurrent`, the main queue), stated on the
/// stamp instead because under test the queue is never created.
///
/// It is the subject's requirement, so it rides the type the subject depends on: a port that needs a
/// concurrent queue where the baseline needed a serial one depends on a different protocol, and the
/// diff sees a different domain.
public enum ScheduleDiscipline: Sendable, Equatable {
    /// One item at a time, in enqueue order. The queue's order is a contract.
    case serial
    /// Items may run in any order. The queue's order is scheduler noise.
    case concurrent
    /// The main queue: serial, and the domain `main`. Its work runs on the main thread.
    case main

    /// The domain the work handed to a queue of this discipline records on.
    ///
    /// - Parameter label: The stamped protocol's trace label, which names a serial or concurrent
    ///   queue's domain.
    /// - Returns: `.main`, or a queue domain named by `label`.
    func domain(label: String) -> ConcurrencyDomain {
        switch self {
        case .serial: .queue(label, serial: true)
        case .concurrent: .queue(label, serial: false)
        case .main: .main
        }
    }
}

/// How far a capture lets held work run in a gap between two operations: a *settle point*.
///
/// A capture with no settle points runs every operation first and the held work only after the
/// last one, which is the most impatient user there is: no operation ever meets an earlier one's
/// work landed, and the clock never moves between them. A settle point lets the work land. Held,
/// running nothing, is the absence of one, which is why it has no case here.
public enum Settle: String, Sendable, CaseIterable, Codable {
    /// Runs the work that is ready now, and the work that work hands on, but leaves the clock where
    /// it is: the queues caught up while the user kept going. A timer still waiting stays held.
    case ready
    /// Runs everything, timers included, advancing virtual time until the backlog is empty: the
    /// user paused.
    case elapsed
}

/// The work a capture's scheduling doubles were handed, held until the engine runs it.
///
/// A stamped scheduling protocol (`@Haruspec(schedules: .serial)`) is the project's own thread seam:
/// production conforms a real queue to it, and under test its double hands every enqueue here
/// instead of to a thread. Nothing runs until the engine drains the backlog, and then it runs one
/// item at a time, in enqueue order, on the draining task. The engine drains at the capture's
/// settle points (a gap between two operations its settle schedule lets work land in, see
/// ``Settle``) and after the last operation. Each settle schedule is one legal schedule of the
/// program, and the same one every run, so seamed work is stable by construction.
///
/// Holding the work at the enqueue is what makes the three facts a trace needs exact:
///
/// - **Reachability:** each item runs with the capture's recorder bound, so the events it records
///   reach the trace however the subject handed it off.
/// - **Quiescence:** the capture has settled when the backlog is empty. There is no thread to wait
///   for, so "has the work finished?" is a question about this list.
/// - **Happens-before:** the enqueueing call and op are read at the enqueue, the one moment both ends
///   of the edge are in hand, and the item's first event in each domain claims the call as its cause.
///
/// Delayed work runs on virtual time. It becomes ready only when nothing else is, in deadline order,
/// and the clock jumps to its deadline. A debounce therefore fires once the input has settled, which
/// is the settled point a capture snapshots, on both sides of a diff alike. Each fire records a
/// `.timer` event carrying the requested delay in milliseconds: the delay is declared data in hand at
/// the enqueue, never a measurement, so a retimed debounce diverges deterministically.
///
/// Work gated on a `DispatchGroup` (a `notify`) becomes ready when the group is empty. The group is
/// probed without blocking, so the gate is checked on the draining task like any other readiness.
public final class WorkBacklog: @unchecked Sendable {
    /// The backlog of the capture in progress, bound around a capture's ops so a derived op waiting
    /// on a completion block can run the held work that will deliver it.
    @TaskLocal public static var current: WorkBacklog?

    /// The domain of the held work running now, which ``DomainResolver`` reads ahead of any queue
    /// label: the work runs on the draining task, but it ran *as* the queue it was handed to.
    @TaskLocal static var entered: Entered?

    /// The seam domain bound around held work, and whether the work could leave it.
    struct Entered: Sendable {
        /// The domain of the queue or spawner the work was handed to.
        let domain: ConcurrencyDomain
        /// Whether the work is a task, which can hop to another executor mid-body. A block runs
        /// where it was entered, start to finish.
        let isTask: Bool
        /// The queue the work is running on, which a `sync` onto the same serial queue would wait
        /// for forever.
        let queue: ObjectIdentifier
    }

    /// Runs after each held item, on the draining task, attributed to the item's op. A capture reads
    /// its observed state here: between items is where another queue's observer could see it.
    public var settled: (() async -> Void)?

    /// The most items one drain runs before giving up: a timer that re-arms itself on every fire has
    /// no settled point, and the drain says so rather than spinning.
    public static let stepLimit = 10000

    private enum Body {
        case sync(() -> Void)
        case async(() async -> Void)
    }

    private struct Item {
        let seq: Int
        /// The double the work was handed to, which `runSync` drains its own work from.
        let queue: ObjectIdentifier
        let discipline: ScheduleDiscipline
        let domain: ConcurrencyDomain
        let body: Body
        /// Virtual seconds; `nil` for work ready at once.
        let deadline: Double?
        /// The delay the work was handed over with, recorded when it fires; `nil` for undelayed work.
        let delay: TimeInterval?
        /// The group whose emptying releases this work; `nil` for work not gated on one.
        let group: DispatchGroup?
        /// The traced call that enqueued the work, its happens-before cause.
        let cause: Int?
        /// The declared op the enqueue ran under, which the work's events are attributed to.
        let op: OpIdentity?

        func isReady(at now: Double) -> Bool {
            if let deadline, deadline > now {
                return false
            }
            // A gated item is released (ungated, re-enqueued) once its group empties.
            return group == nil
        }
    }

    /// One held item's run, carried onto the main actor. The project's work is not `Sendable`, and
    /// needn't be: the backlog runs one item at a time, so nothing else touches it meanwhile.
    private struct Job: @unchecked Sendable {
        let run: () -> Void
    }

    // `NSLock` rather than `Synchronization.Mutex`, matching `TraceRecorder`: the package still
    // supports macOS 13, where `Mutex` does not exist.
    private let lock = NSLock()
    private var items: [Item] = []
    private var taken = 0
    /// The queue each domain belongs to in this capture; see ``DomainOwners``.
    private var owners = DomainOwners()
    private var nextSeq = 0
    private var virtualNow: Double = 0

    public init() {}

    /// The capture's virtual time, in seconds since the capture began: the deadline of the latest
    /// delayed work to fire, and zero before any has.
    public var virtualTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return virtualNow
    }

    /// How many items are held, ready or not.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    /// The happens-before cause of work handed over at one moment: the traced call that handed it over.
    ///
    /// Inside held work that no traced call encloses, it is that work's own cause, carried forward. Work
    /// one held item hands on was caused by whatever caused the item, so a completion held from inside
    /// an operation still names the call that queued the operation, however many hops away it lands.
    public struct Cause: Sendable, Equatable {
        /// The sequence number of the causing call's event; `nil` when no traced call caused the work.
        let seq: Int?
    }

    /// Returns the cause work handed over here and now would carry.
    ///
    /// - Returns: The traced call open here; inside held work no call encloses, that work's cause; or
    ///   no cause, outside both.
    ///
    /// A seam that holds work later than its subject handed it over (an operation queue waiting on a
    /// dependency) reads this at the hand-off and passes it to
    /// ``enqueue(on:label:discipline:after:notifying:causedBy:_:)``.
    public static func causeHere() -> Cause {
        Cause(seq: TraceContext.active?.enclosingCallSeq() ?? TraceContext.pendingSpawnCause?.origin)
    }

    // MARK: - Enqueue (what a scheduling double does)

    /// Holds synchronous work handed to `queue`.
    ///
    /// - Parameters:
    ///   - queue: The double the work was handed to.
    ///   - label: The double's trace label, which names its domain.
    ///   - discipline: How the double's protocol orders its work.
    ///   - delay: Seconds of virtual time before the work is ready; `nil` for ready at once.
    ///   - group: A group whose emptying releases the work; `nil` for work not gated on one.
    ///   - cause: The work's happens-before cause, read earlier with ``causeHere()``; `nil` for the
    ///     cause at this enqueue.
    ///   - work: The work.
    public func enqueue(
        on queue: AnyObject,
        label: String,
        discipline: ScheduleDiscipline,
        after delay: TimeInterval? = nil,
        notifying group: DispatchGroup? = nil,
        causedBy cause: Cause? = nil,
        _ work: @escaping () -> Void
    ) {
        hold(
            queue: queue,
            label: label,
            discipline: discipline,
            body: .sync(work),
            delay: delay,
            group: group,
            cause: cause
        )
    }

    /// Holds an unstructured task's operation handed to `queue`: the project's `Task { … }`, spawned
    /// through its own seam.
    ///
    /// - Parameters:
    ///   - queue: The double the operation was handed to.
    ///   - label: The double's trace label, which names its domain.
    ///   - discipline: How the double's protocol orders its work.
    ///   - operation: The task's body.
    public func spawn(
        on queue: AnyObject,
        label: String,
        discipline: ScheduleDiscipline,
        _ operation: @escaping () async -> Void
    ) {
        let body = Body.async(operation)
        hold(queue: queue, label: label, discipline: discipline, body: body, delay: nil, group: nil, cause: nil)
    }

    /// Runs `work` as `queue` would run a `sync`: after every ready item already held for that queue,
    /// then inline, on the caller's thread.
    ///
    /// - Parameters:
    ///   - queue: The double the work was handed to.
    ///   - label: The double's trace label, which names its domain.
    ///   - discipline: How the double's protocol orders its work.
    ///   - work: The work, which runs before this returns.
    public func runSync(
        on queue: AnyObject,
        label: String,
        discipline: ScheduleDiscipline,
        _ work: () -> Void
    ) {
        let recorder = TraceContext.active
        if let refusal = Self.syncRefusal(onto: queue, label: label, discipline: discipline) {
            preconditionFailure(refusal)
        }
        lock.withLock { owners.claimOrTrap(discipline.domain(label: label), for: queue) }
        // The sync waits behind what is on the queue *now*. Work released while it waits (a group
        // emptying) is enqueued behind it, as GCD would enqueue it.
        let ahead = readySeqs(on: ObjectIdentifier(queue))
        while let item = take(where: { ahead.contains($0.seq) }) {
            guard case let .sync(body) = item.body else {
                preconditionFailure("a sync on \(label) reached async work; the stamp rejects that protocol shape")
            }
            invoke(body, of: item, recorder: recorder)
        }
        let entered = Entered(domain: discipline.domain(label: label), isTask: false, queue: ObjectIdentifier(queue))
        Self.$entered.withValue(entered) { work() }
    }

    // MARK: - Drain (what the engine does)

    /// Runs held work until none is left that can run.
    ///
    /// - Parameter recorder: The capture's recorder, bound around each item.
    /// - Returns: `true` when the backlog emptied; `false` when work is left that nothing will
    ///   release (a group that never empties) or the drain hit ``stepLimit``.
    @discardableResult
    public func drain(recorder: TraceRecorder?) async -> Bool {
        await settle(.elapsed, recorder: recorder)
    }

    /// Runs held work as far as a settle point lets it: everything for ``Settle/elapsed``, only what
    /// is ready without moving the clock for ``Settle/ready``.
    ///
    /// - Parameters:
    ///   - settle: How far the work may run.
    ///   - recorder: The capture's recorder, bound around each item.
    /// - Returns: `true` when the backlog settled as far as asked: empty for ``Settle/elapsed``,
    ///   nothing ready for ``Settle/ready``; `false` when an elapsed settle leaves work nothing will
    ///   release, or either hits ``stepLimit``.
    @discardableResult
    public func settle(_ settle: Settle, recorder: TraceRecorder?) async -> Bool {
        let advancing = settle == .elapsed
        var steps = 0
        while await step(recorder: recorder, advancingClock: advancing) {
            steps += 1
            if steps >= Self.stepLimit {
                return false
            }
        }
        return advancing ? pendingCount == 0 : true
    }

    /// Runs the next item: the earliest ready one, or, when none is ready and `advancingClock`
    /// allows, the delayed one with the earliest deadline, advancing virtual time to it.
    ///
    /// - Parameters:
    ///   - recorder: The capture's recorder, bound around the item.
    ///   - advancingClock: Whether virtual time may jump to a deadline when nothing is ready.
    /// - Returns: `false` when nothing could run.
    public func step(recorder: TraceRecorder?, advancingClock: Bool = true) async -> Bool {
        guard let item = takeNext(advancingClock: advancingClock) else { return false }
        switch item.body {
        case let .sync(body):
            let job = Job { self.invoke(body, of: item, recorder: recorder) }
            if item.discipline == .main {
                // Main-queue work runs on the main thread, as it would have: code inside it may
                // assume main (UIKit, `MainActor.assumeIsolated`). Still one item at a time.
                await MainActor.run { job.run() }
            } else {
                job.run()
            }
        case let .async(operation):
            let scope = Self.heldScope(recorder ?? TraceContext.current)
            await TraceContext.$current.withValue(recorder ?? TraceContext.current) {
                await TraceContext.$currentOp.withValue(item.op) {
                    await TraceContext.$pendingSpawnCause.withValue(TraceContext.SpawnCause(item.cause)) {
                        await TraceContext.$callScope.withValue(scope) {
                            let entered = Entered(domain: item.domain, isTask: true, queue: item.queue)
                            await Self.$entered.withValue(entered) {
                                await operation()
                            }
                        }
                    }
                }
            }
        }
        if let settled {
            await TraceContext.$currentOp.withValue(item.op) {
                await settled()
            }
        }
        return true
    }

    // MARK: - Internals

    private func hold(
        queue: AnyObject,
        label: String,
        discipline: ScheduleDiscipline,
        body: Body,
        delay: TimeInterval?,
        group: DispatchGroup?,
        cause: Cause?
    ) {
        // Read at the enqueue: the only moment the enqueueing call and op are both in hand.
        let cause = (cause ?? Self.causeHere()).seq
        let op = TraceContext.activeOp
        lock.lock(); defer { lock.unlock() }
        owners.claimOrTrap(discipline.domain(label: label), for: queue)
        items.append(Item(
            seq: nextSeq,
            queue: ObjectIdentifier(queue),
            discipline: discipline,
            domain: discipline.domain(label: label),
            body: body,
            deadline: delay.map { virtualNow + max(0, $0) },
            delay: delay,
            group: group,
            cause: cause,
            op: op
        ))
        nextSeq += 1
    }

    /// Runs one synchronous item with the capture bound: the recorder, the op it was enqueued under,
    /// its spawn cause, and the domain it was handed to.
    private func invoke(_ body: () -> Void, of item: Item, recorder: TraceRecorder?) {
        let recorder = recorder ?? TraceContext.active
        TraceContext.$current.withValue(recorder) {
            TraceContext.$currentOp.withValue(item.op) {
                TraceContext.$pendingSpawnCause.withValue(TraceContext.SpawnCause(item.cause)) {
                    TraceContext.$callScope.withValue(Self.heldScope(recorder)) {
                        Self.$entered.withValue(Entered(domain: item.domain, isTask: false, queue: item.queue)) {
                            if let delay = item.delay {
                                TraceContext.active?.timerFired(
                                    delay: .int(Int64((delay * 1000).rounded())),
                                    isolation: nil
                                )
                            }
                            body()
                        }
                    }
                }
            }
        }
    }

    /// The call scope held work runs in: no call encloses it, so a call still open on the draining
    /// thread is not its cause, but a call it opens itself is.
    ///
    /// - Parameter recorder: The capture's recorder, whose next sequence number is the scope's floor.
    /// - Returns: A scope with no call, floored at the work's first event.
    private static func heldScope(_ recorder: TraceRecorder?) -> TraceContext.CallScope {
        TraceContext.CallScope(call: nil, floor: recorder?.nextSeq ?? 0)
    }
}

// MARK: - Taking held work

extension WorkBacklog {
    private func takeNext(advancingClock: Bool) -> Item? {
        lock.lock(); defer { lock.unlock() }
        releaseEmptiedGroups()
        if let index = items.firstIndex(where: { $0.isReady(at: virtualNow) }) {
            taken += 1
            return items.remove(at: index)
        }
        guard advancingClock else {
            return nil
        }
        // Nothing ready: jump the clock to the earliest deadline. Ties keep enqueue order.
        let delayed = items.indices.filter { items[$0].deadline != nil }
        guard let earliest = delayed.min(by: { items[$0].deadline! < items[$1].deadline! }) else {
            return nil
        }
        virtualNow = items[earliest].deadline!
        taken += 1
        return items.remove(at: earliest)
    }

    /// The items on `queue` that are ready now, by enqueue number.
    private func readySeqs(on queue: ObjectIdentifier) -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        releaseEmptiedGroups()
        return Set(items.filter { $0.queue == queue && $0.isReady(at: virtualNow) }.map(\.seq))
    }

    /// Moves each `notify` whose group has emptied to the back of the backlog, ungated: GCD enqueues
    /// the block when the group empties, behind whatever was enqueued while it waited. Call with the
    /// lock held.
    private func releaseEmptiedGroups() {
        var released: [Item] = []
        items.removeAll { item in
            guard let group = item.group, group.wait(timeout: .now()) == .success else { return false }
            released.append(item)
            return true
        }
        for item in released {
            items.append(Item(
                seq: nextSeq,
                queue: item.queue,
                discipline: item.discipline,
                domain: item.domain,
                body: item.body,
                deadline: item.deadline,
                delay: item.delay,
                group: nil,
                cause: item.cause,
                op: item.op
            ))
            nextSeq += 1
        }
    }

    private func take(where matches: (Item) -> Bool) -> Item? {
        lock.lock(); defer { lock.unlock() }
        guard let index = items.firstIndex(where: matches) else { return nil }
        taken += 1
        return items.remove(at: index)
    }
}

// MARK: - What a stalled capture reads

extension WorkBacklog {
    /// How many held items have been taken to run so far: progress, for a watchdog that has to tell a
    /// slow capture from a stuck one.
    var itemsTaken: Int {
        lock.lock(); defer { lock.unlock() }
        return taken
    }

    /// Describes the held work, by the domain each item records on, for a message about it.
    ///
    /// - Returns: For example `2 on queue(serial):CatalogQueue, 1 on main`; `nothing` when none is held.
    func heldSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !items.isEmpty else { return "nothing" }
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.domain.description, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.value) on \($0.key)" }.joined(separator: ", ")
    }
}
