import Foundation
import HaruspecAudit
import HaruspecTrace

/// An `OperationQueue` whose operations the capture holds, as a stamped scheduling double's work is:
/// what a spec hands a subject that takes an injected queue, from ``SeamContext/operationQueue(_:)``.
///
/// Foundation runs an operation on a thread of its own and delivers its `completionBlock` on yet
/// another, so neither reaches the capture. This queue starts each operation as held work instead,
/// and owns the completion: it takes the block before the start, so Foundation has nothing to
/// deliver, and runs it as held work of its own once the operation finishes.
///
/// - An operation starts once it is ready (its dependencies have finished, or it was cancelled) and
///   the queue has room under `maxConcurrentOperationCount`: the highest `queuePriority` first, then
///   in the order added. A cancelled operation starts too, skips ``Foundation/Operation/main()``, and still completes.
/// - An asynchronous operation keeps its place until it reports `isFinished`, which it does from later
///   held work. A serial queue starts nothing else meanwhile.
/// - A finished operation leaves ``operations`` first, then its completion runs, then the next one
///   starts. Foundation races the three; this is one legal order, the same on every run.
/// - Work records on the queue's domain. A ``HeldScheduler/Queue/main`` queue records on `main` and runs on the main
///   thread. Otherwise the domain is `queue(serial):<label>` while `maxConcurrentOperationCount` is 1
///   and `queue(concurrent):<label>` while it is not, read as each operation starts: a subject that
///   sets the count gets the queue it asked for.
/// - `isSuspended` holds back starts, and ``cancelAllOperations()``, ``addBarrierBlock(_:)`` and the
///   block form of ``addOperation(_:)`` behave as Foundation's do. `underlyingQueue` is ignored: the
///   capture runs the work.
/// - A wait traps, naming the call. ``waitUntilAllOperationsAreFinished()`` and
///   ``addOperations(_:waitUntilFinished:)`` with `true` would wait on work that runs only once the
///   capture drains, after the subject returns. ``Foundation/Operation/waitUntilFinished()`` belongs to the
///   operation, so no queue can catch it: it hangs.
public final class HeldOperationQueue: OperationQueue, QueueNaming, @unchecked Sendable {
    /// The queue a held operation queue stands in for, which names its domain.
    ///
    /// A serial queue starts with a `maxConcurrentOperationCount` of 1, a concurrent one with
    /// Foundation's default.
    public typealias Queue = HeldScheduler.Queue

    private let backlog: WorkBacklog
    private let label: String
    private let isMain: Bool

    /// `NSLock` rather than `Synchronization.Mutex`, matching `WorkBacklog`: the package still supports
    /// macOS 13. Nothing the subject wrote runs with it held.
    private let lock = NSLock()
    /// The operations added and not yet completed, in the order added.
    private var entries: [Entry] = []
    private var holdsStarts = false

    /// Creates a queue whose operations the capture holds in `backlog`.
    ///
    /// - Parameters:
    ///   - queue: The queue it stands in for.
    ///   - backlog: The capture's held work.
    /// - Precondition: A serial or concurrent queue's label is non-empty.
    init(_ queue: Queue, backlog: WorkBacklog) {
        let (label, discipline) = queue.named
        self.backlog = backlog
        self.label = label
        isMain = discipline == .main
        super.init()
        name = label
        if discipline != .concurrent {
            maxConcurrentOperationCount = 1
        }
    }

    // swiftlucid:exempt implements QueueNaming.naming(_:), documented on the protocol
    public func naming(_ label: String) -> String {
        "context.operationQueue(.\(discipline == .concurrent ? "concurrent" : "serial")(\"\(label)\"))"
    }

    // MARK: - Adding work

    // swiftlucid:exempt overrides OperationQueue.addOperation(_:), documented on the type
    override public func addOperation(_ operation: Operation) {
        precondition(
            !operation.isExecuting && !operation.isFinished,
            "an operation can't be added to a queue once it has started"
        )
        add(Entry(operation, isBarrier: false, cause: WorkBacklog.causeHere()))
    }

    // swiftlucid:exempt overrides OperationQueue.addOperation(_:), documented on the type
    override public func addOperation(_ block: @escaping @Sendable () -> Void) {
        addOperation(BlockOperation(block: block))
    }

    // swiftlucid:exempt overrides OperationQueue.addOperations(_:waitUntilFinished:), documented on the type
    override public func addOperations(_ operations: [Operation], waitUntilFinished wait: Bool) {
        precondition(
            !wait || operations.isEmpty,
            """
            addOperations(_:waitUntilFinished: true) on a held queue would wait forever: its operations \
            run only when the capture drains them, after the subject returns. Pass false, and carry on \
            from a completion block or a dependent operation.
            """
        )
        operations.forEach(addOperation)
    }

    // swiftlucid:exempt overrides OperationQueue.addBarrierBlock(_:), documented on the type
    override public func addBarrierBlock(_ barrier: @escaping @Sendable () -> Void) {
        add(Entry(BlockOperation(block: barrier), isBarrier: true, cause: WorkBacklog.causeHere()))
    }

    // MARK: - Reading and steering it

    // swiftlucid:exempt overrides OperationQueue.operations: added and not yet finished, in the order added
    override public var operations: [Operation] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.state != .finished }.map(\.operation)
    }

    // swiftlucid:exempt overrides OperationQueue.operationCount
    override public var operationCount: Int {
        operations.count
    }

    // swiftlucid:exempt overrides OperationQueue.isSuspended, documented on the type
    override public var isSuspended: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return holdsStarts
        }
        set {
            lock.withLock { holdsStarts = newValue }
            startReady()
        }
    }

    // swiftlucid:exempt overrides OperationQueue.maxConcurrentOperationCount, documented on the type
    override public var maxConcurrentOperationCount: Int {
        didSet { startReady() }
    }

    // swiftlucid:exempt overrides OperationQueue.cancelAllOperations()
    override public func cancelAllOperations() {
        operations.forEach { $0.cancel() }
    }

    // swiftlucid:exempt overrides OperationQueue.waitUntilAllOperationsAreFinished(), documented on the type
    override public func waitUntilAllOperationsAreFinished() {
        precondition(
            operations.isEmpty,
            """
            waitUntilAllOperationsAreFinished() on a held queue would wait forever: its operations run \
            only when the capture drains them, after the subject returns. Carry on from a completion \
            block or a dependent operation instead.
            """
        )
    }

    // MARK: - Running it

    /// Takes `entry` onto the queue, and starts whatever that lets start.
    ///
    /// - Parameter entry: The operation added, and whether it is a barrier.
    /// - Precondition: The operation is not already on this queue.
    private func add(_ entry: Entry) {
        let operation = entry.operation
        // Readiness changes when a dependency finishes or the operation is cancelled, in whatever held
        // work does that; either may let it start.
        entry.readiness = operation.observe(\.isReady) { [weak self] _, _ in
            self?.startReady()
        }
        lock.withLock {
            precondition(
                !entries.contains { $0.operation === operation },
                "an operation can be added to a queue once"
            )
            entries.append(entry)
        }
        startReady()
    }

    /// Hands each operation that may start now to the backlog, in the order Foundation would pick them.
    private func startReady() {
        // Readiness and priority are the operation's to answer, so they're read without the lock.
        let waiting = lock.withLock { holdsStarts ? [] : runnable() }
        let ready = waiting.filter { $0.isBarrier || $0.operation.isReady }
        let ranked = ready.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.operation.queuePriority, rhs.element.operation.queuePriority)
                return left == right ? lhs.offset < rhs.offset : left.rawValue > right.rawValue
            }
            .map(\.element)
        let starting: [(Entry, ScheduleDiscipline)] = lock.withLock {
            var room = limit - entries.count { $0.state != .waiting }
            var claimed: [(Entry, ScheduleDiscipline)] = []
            for entry in ranked where room > 0 && entry.state == .waiting {
                entry.state = .started
                claimed.append((entry, discipline))
                room -= 1
            }
            return claimed
        }
        for (entry, discipline) in starting {
            hold(discipline, causedBy: entry.cause) { [self] in start(entry, on: discipline) }
        }
    }

    /// Returns the waiting entries the queue's order lets start, readiness aside. Call with the lock
    /// held.
    ///
    /// - Returns: None while a barrier runs; a barrier alone once everything ahead of it is done;
    ///   otherwise the waiting operations ahead of the first waiting barrier.
    private func runnable() -> [Entry] {
        guard !entries.contains(where: { $0.isBarrier && $0.state != .waiting }) else {
            return []
        }
        if let first = entries.first, first.isBarrier {
            return [first]
        }
        return Array(entries.prefix { !$0.isBarrier }.filter { $0.state == .waiting })
    }

    /// How many operations may run at once. Call with the lock held.
    private var limit: Int {
        if isMain {
            return 1
        }
        let count = maxConcurrentOperationCount
        return count == OperationQueue.defaultMaxConcurrentOperationCount ? .max : count
    }

    /// How the queue orders its work now, which names the domain an operation starting now records on.
    private var discipline: ScheduleDiscipline {
        if isMain {
            return .main
        }
        return maxConcurrentOperationCount == 1 ? .serial : .concurrent
    }

    /// Starts `entry`'s operation, as held work, having taken its completion block so that Foundation
    /// has none to deliver.
    ///
    /// - Parameters:
    ///   - entry: The entry claimed to start.
    ///   - discipline: How the queue ordered its work when the entry was claimed.
    private func start(_ entry: Entry, on discipline: ScheduleDiscipline) {
        let operation = entry.operation
        // A dependency added since the claim: back in line, as Foundation would never have started it.
        guard operation.isReady || operation.isCancelled else {
            lock.withLock { entry.state = .waiting }
            return
        }
        entry.completion = operation.completionBlock
        operation.completionBlock = nil
        entry.finishing = operation.observe(\.isFinished, options: [.initial]) { [weak self, weak entry] operation, _ in
            guard operation.isFinished, let self, let entry else { return }
            finished(entry, on: discipline)
        }
        // One that finished itself on cancel, unstarted, has nothing left to run.
        if !operation.isFinished {
            operation.start()
        }
    }

    /// Takes `entry` off ``operations`` once its operation reports finished, and holds its completion.
    ///
    /// - Parameters:
    ///   - entry: The entry whose operation finished.
    ///   - discipline: How the queue ordered its work when the operation started.
    ///
    /// It runs inside Foundation's change notification, so the completion waits for held work of its
    /// own: the subject's block never runs in the middle of the operation's `isFinished` setter.
    private func finished(_ entry: Entry, on discipline: ScheduleDiscipline) {
        let first = lock.withLock {
            guard entry.state == .started else { return false }
            entry.state = .finished
            return true
        }
        guard first else { return }
        hold(discipline, causedBy: entry.cause) { [self] in complete(entry) }
    }

    /// Hands `work` to the capture's backlog as this queue.
    ///
    /// - Parameters:
    ///   - discipline: How the queue orders its work, which names the domain the work records on.
    ///   - cause: The call that added the operation the work runs or completes.
    ///   - work: The work.
    private func hold(
        _ discipline: ScheduleDiscipline,
        causedBy cause: WorkBacklog.Cause,
        _ work: @escaping () -> Void
    ) {
        TraceOrigins.collector?.noteHeldStandIn(HeldStandIn.operationQueue.rawValue)
        backlog.enqueue(on: self, label: label, discipline: discipline, causedBy: cause, work)
    }

    /// Removes `entry`, runs its operation's completion block, then starts what its room lets start.
    ///
    /// - Parameter entry: The entry whose operation finished.
    private func complete(_ entry: Entry) {
        lock.withLock {
            entries.removeAll { $0 === entry }
        }
        entry.readiness = nil
        entry.finishing = nil
        let completion = entry.completion
        entry.completion = nil
        completion?()
        startReady()
    }

    /// Where an entry is between its add and its completion.
    private enum EntryState {
        /// Added, and not yet handed to the backlog.
        case waiting
        /// Handed to the backlog, or running: it holds one of the queue's places.
        case started
        /// Finished, its completion held: off ``HeldOperationQueue/operations``, still in its place.
        case finished
    }

    /// One operation on the queue, from its add to its completion. Its `state` changes under the
    /// queue's lock; the rest is touched only by the held work running it, one item at a time.
    private final class Entry: @unchecked Sendable {
        let operation: Operation
        let isBarrier: Bool
        /// The call that added the operation: the cause of its start and its completion, whichever held
        /// work happens to release them.
        let cause: WorkBacklog.Cause
        var state = EntryState.waiting
        /// The block taken from the operation before its start, which the queue runs once it finishes.
        var completion: (() -> Void)?
        var readiness: NSKeyValueObservation?
        var finishing: NSKeyValueObservation?

        /// Creates a waiting entry.
        ///
        /// - Parameters:
        ///   - operation: The operation added.
        ///   - isBarrier: Whether it is a barrier, which runs alone once everything ahead of it is done.
        ///   - cause: The cause at the add.
        init(_ operation: Operation, isBarrier: Bool, cause: WorkBacklog.Cause) {
            self.operation = operation
            self.isBarrier = isBarrier
            self.cause = cause
        }
    }
}

public extension SeamContext {
    /// Returns an `OperationQueue` whose operations this capture holds, for a subject that takes one.
    ///
    /// - Parameter queue: The queue the subject's stands in for, which names its domain.
    /// - Returns: A queue over this capture's backlog; see ``HeldOperationQueue``.
    /// - Precondition: A serial or concurrent queue's label is non-empty.
    ///
    /// It is the double for that boundary: the subject depends on Foundation's class, so no stamp can
    /// paste it.
    ///
    /// ```swift
    /// .baselined { context in
    ///     PhotoUploader(queue: context.operationQueue(.serial("uploads")))
    /// }
    /// ```
    func operationQueue(_ queue: HeldOperationQueue.Queue) -> HeldOperationQueue {
        HeldOperationQueue(queue, backlog: backlog)
    }
}
