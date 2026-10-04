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

/// The work a capture's scheduling doubles were handed, held until the engine runs it.
///
/// A stamped scheduling protocol (`@Haruspec(schedules: .serial)`) is the project's own thread seam:
/// production conforms a real queue to it, and under test its double hands every enqueue here
/// instead of to a thread. Nothing runs until the engine drains the backlog, and then it runs one
/// item at a time, in enqueue order, on the draining task. That is one legal schedule of the
/// program, and the same one every run, so seamed work is stable by construction.
///
/// Holding the work at the enqueue is what makes the three facts a trace needs exact:
///
/// - **Reachability:** each item runs with the capture's recorder bound, so the events it records
///   reach the trace however the subject handed it off.
/// - **Quiescence:** the capture has settled when the backlog is empty. There is no thread to wait
///   for, so "has the work finished?" is a question about this list.
/// - **Happens-before:** the enqueueing call and op are read at the enqueue, the one moment both ends
///   of the edge are in hand, and the item's first event claims the call as its cause.
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
    @TaskLocal static var enteredDomain: ConcurrencyDomain?

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
    private var nextSeq = 0
    private var virtualNow: Double = 0

    public init() {}

    /// How many items are held, ready or not.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
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
    ///   - work: The work.
    public func enqueue(
        on queue: AnyObject,
        label: String,
        discipline: ScheduleDiscipline,
        after delay: TimeInterval? = nil,
        notifying group: DispatchGroup? = nil,
        _ work: @escaping () -> Void
    ) {
        hold(queue: queue, label: label, discipline: discipline, body: .sync(work), delay: delay, group: group)
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
        hold(queue: queue, label: label, discipline: discipline, body: .async(operation), delay: nil, group: nil)
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
        // The sync waits behind what is on the queue *now*. Work released while it waits (a group
        // emptying) is enqueued behind it, as GCD would enqueue it.
        let ahead = readySeqs(on: ObjectIdentifier(queue))
        while let item = take(where: { ahead.contains($0.seq) }) {
            guard case let .sync(body) = item.body else {
                preconditionFailure("a sync on \(label) reached async work; the stamp rejects that protocol shape")
            }
            invoke(body, of: item, recorder: recorder)
        }
        Self.$enteredDomain.withValue(discipline.domain(label: label)) { work() }
    }

    // MARK: - Drain (what the engine does)

    /// Runs held work until none is left that can run.
    ///
    /// - Parameter recorder: The capture's recorder, bound around each item.
    /// - Returns: `true` when the backlog emptied; `false` when work is left that nothing will
    ///   release (a group that never empties) or the drain hit ``stepLimit``.
    @discardableResult
    public func drain(recorder: TraceRecorder?) async -> Bool {
        var steps = 0
        while await step(recorder: recorder) {
            steps += 1
            if steps >= Self.stepLimit {
                return false
            }
        }
        return pendingCount == 0
    }

    /// Runs the next item: the earliest ready one, or, when none is ready, the delayed one with the
    /// earliest deadline, advancing virtual time to it.
    ///
    /// - Parameter recorder: The capture's recorder, bound around the item.
    /// - Returns: `false` when nothing could run.
    public func step(recorder: TraceRecorder?) async -> Bool {
        guard let item = takeNext() else { return false }
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
            await TraceContext.$current.withValue(recorder ?? TraceContext.current) {
                await TraceContext.$currentOp.withValue(item.op) {
                    await TraceContext.$pendingSpawnCause.withValue(TraceContext.SpawnCause(item.cause)) {
                        await Self.$enteredDomain.withValue(item.domain) {
                            await operation()
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
        group: DispatchGroup?
    ) {
        // Read at the enqueue: the only moment the enqueueing call and op are both in hand.
        let recorder = TraceContext.active
        let cause = recorder?.enclosingCallSeq()
        let op = TraceContext.activeOp
        lock.lock(); defer { lock.unlock() }
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
        TraceContext.$current.withValue(recorder ?? TraceContext.active) {
            TraceContext.$currentOp.withValue(item.op) {
                TraceContext.$pendingSpawnCause.withValue(TraceContext.SpawnCause(item.cause)) {
                    Self.$enteredDomain.withValue(item.domain) {
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

    private func takeNext() -> Item? {
        lock.lock(); defer { lock.unlock() }
        releaseEmptiedGroups()
        if let index = items.firstIndex(where: { $0.isReady(at: virtualNow) }) {
            return items.remove(at: index)
        }
        // Nothing ready: jump the clock to the earliest deadline. Ties keep enqueue order.
        let delayed = items.indices.filter { items[$0].deadline != nil }
        guard let earliest = delayed.min(by: { items[$0].deadline! < items[$1].deadline! }) else {
            return nil
        }
        virtualNow = items[earliest].deadline!
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
        return items.remove(at: index)
    }
}
