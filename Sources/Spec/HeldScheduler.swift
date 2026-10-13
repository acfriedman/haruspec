import Combine
import Foundation
import HaruspecTrace

/// A Combine scheduler whose work the capture holds, as a stamped scheduling double's is. It is
/// what a spec hands a subject that takes an injected `Scheduler`, from ``SeamContext/scheduler(_:)``.
///
/// Its time and option types are `DispatchQueue`'s, so it stands in wherever a subject takes a
/// `DispatchQueue` scheduler, a generic one constrained to its time type, or a type-erased one
/// such as CombineSchedulers' `AnySchedulerOf<DispatchQueue>`.
///
/// - The immediate form is held and run in enqueue order, recording on the queue's domain: `main`
///   for ``Queue/main``, run on the main thread; `queue(serial):<label>` or
///   `queue(concurrent):<label>` otherwise.
/// - `now` is the capture's virtual time, so an operator that reads the clock (`measureInterval`,
///   `throttle`, `timeout`) reads the same instant on every run, on both sides of a diff.
/// - The delayed form is held on virtual time: it fires once nothing else is ready, recording a
///   `timer` event with the delay it was handed, so a retimed `debounce` diverges deterministically.
/// - The repeating form re-arms on virtual time until it is cancelled. One that never is stops at
///   the backlog's step limit, leaving the held-work marker.
///
/// A copy is the same queue; two calls to ``SeamContext/scheduler(_:)`` are two queues, even with
/// one label. Of `SchedulerOptions`, only `group` has meaning under test, and only on the immediate
/// form, where `DispatchQueue` honors it too: the work is in the group until it has run.
public struct HeldScheduler: Scheduler, Sendable {
    // gloss:exempt implements Scheduler.SchedulerTimeType; DispatchQueue's, documented on the type
    public typealias SchedulerTimeType = DispatchQueue.SchedulerTimeType
    // gloss:exempt implements Scheduler.SchedulerOptions; DispatchQueue's, documented on the type
    public typealias SchedulerOptions = DispatchQueue.SchedulerOptions

    /// The queue a scheduler stands in for, which names the domain its work records on.
    public enum Queue: Sendable, Equatable {
        /// The main queue: serial, run on the main thread, the domain `main`.
        case main
        /// A serial queue, one item at a time, in the domain `queue(serial):<label>`.
        case serial(String)
        /// A concurrent queue, whose order is noise, in the domain `queue(concurrent):<label>`.
        case concurrent(String)
    }

    /// The uptime `now` reads at virtual time zero. Fixed, so a reading is the same every run, and
    /// non-zero, which `DispatchTime` reads as "now".
    private static let epoch: UInt64 = 1_000_000_000

    private let backlog: WorkBacklog
    private let identity = Identity()
    private let label: String
    private let discipline: ScheduleDiscipline

    /// Creates a scheduler that holds its work in `backlog`.
    ///
    /// - Parameters:
    ///   - queue: The queue it stands in for.
    ///   - backlog: The capture's held work.
    /// - Precondition: A serial or concurrent queue's label is non-empty.
    init(_ queue: Queue, backlog: WorkBacklog) {
        self.backlog = backlog
        switch queue {
        case .main:
            (label, discipline) = ("main", .main)
        case let .serial(label):
            (self.label, discipline) = (Self.checked(label), .serial)
        case let .concurrent(label):
            (self.label, discipline) = (Self.checked(label), .concurrent)
        }
    }

    /// Returns `label`, trapping when it is empty.
    ///
    /// - Parameter label: A serial or concurrent queue's label.
    /// - Returns: `label`, which names the queue's domain.
    private static func checked(_ label: String) -> String {
        precondition(
            !label.isEmpty,
            "a held scheduler's queue needs a label, which names its domain: .serial(\"uploads\")"
        )
        return label
    }

    // gloss:exempt implements Scheduler.now, documented on the type
    public var now: SchedulerTimeType {
        let nanoseconds = UInt64((backlog.virtualTime * 1_000_000_000).rounded())
        return SchedulerTimeType(DispatchTime(uptimeNanoseconds: Self.epoch + nanoseconds))
    }

    // gloss:exempt implements Scheduler.minimumTolerance; virtual time has no slack
    public var minimumTolerance: SchedulerTimeType.Stride {
        .zero
    }

    // gloss:exempt implements Scheduler.schedule(options:_:), documented on the type
    public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) {
        guard let group = options?.group else {
            return hold(after: nil, action)
        }
        group.enter()
        hold(after: nil) {
            action()
            group.leave()
        }
    }

    // gloss:exempt implements Scheduler.schedule(after:tolerance:options:_:), documented on the type
    public func schedule(
        after date: SchedulerTimeType,
        tolerance _: SchedulerTimeType.Stride,
        options _: SchedulerOptions?,
        _ action: @escaping () -> Void
    ) {
        hold(after: delay(until: date), action)
    }

    // gloss:exempt implements Scheduler.schedule(after:interval:tolerance:options:_:), documented on the type
    public func schedule(
        after date: SchedulerTimeType,
        interval: SchedulerTimeType.Stride,
        tolerance _: SchedulerTimeType.Stride,
        options _: SchedulerOptions?,
        _ action: @escaping () -> Void
    ) -> Cancellable {
        precondition(
            interval > .zero,
            "a repeating schedule needs a positive interval; a zero one would fire forever at one instant"
        )
        let repetition = Repetition()
        let period = Self.seconds(interval)
        func arm(after delay: TimeInterval) {
            hold(after: delay) {
                guard !repetition.isCancelled else { return }
                action()
                // An action may cancel its own schedule: `debounce` does once it emits.
                guard !repetition.isCancelled else { return }
                arm(after: period)
            }
        }
        arm(after: delay(until: date))
        return repetition
    }

    /// Returns the virtual seconds from `now` until `date`.
    ///
    /// - Parameter date: A scheduled time.
    /// - Returns: The wait, never negative: a time already past is due at once.
    private func delay(until date: SchedulerTimeType) -> TimeInterval {
        Self.seconds(now.distance(to: date))
    }

    /// Hands `work` to the capture's backlog as this scheduler's queue.
    ///
    /// - Parameters:
    ///   - delay: Virtual seconds before the work is ready; `nil` for ready at once.
    ///   - work: The work.
    private func hold(after delay: TimeInterval?, _ work: @escaping () -> Void) {
        backlog.enqueue(on: identity, label: label, discipline: discipline, after: delay, work)
    }

    /// Returns `stride` in seconds.
    ///
    /// - Parameter stride: A distance between two scheduler times.
    /// - Returns: The seconds, clamped at zero.
    private static func seconds(_ stride: SchedulerTimeType.Stride) -> TimeInterval {
        max(0, TimeInterval(stride.magnitude) / 1_000_000_000)
    }

    /// The queue's identity in the backlog, shared by every copy of one scheduler.
    private final class Identity: Sendable {}

    /// The cancellation a repeating schedule returns, read before each fire.
    private final class Repetition: Cancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        /// Whether the schedule has been cancelled; a cancelled one never fires again.
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        // gloss:exempt implements Cancellable.cancel()
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }
    }
}

public extension SeamContext {
    /// Returns a Combine scheduler whose work this capture holds, for a subject that takes one.
    /// It is the double for that boundary: `Scheduler` has associated types, so no stamp can paste it.
    ///
    /// - Parameter queue: The queue the subject's scheduler stands in for, which names its domain.
    /// - Returns: A scheduler over this capture's backlog and virtual clock; see ``HeldScheduler``.
    /// - Precondition: A serial or concurrent queue's label is non-empty.
    ///
    /// ```swift
    /// .baselined { context in
    ///     PhotoUploader(scheduler: context.scheduler(.main).eraseToAnyScheduler())
    /// }
    /// ```
    func scheduler(_ queue: HeldScheduler.Queue) -> HeldScheduler {
        HeldScheduler(queue, backlog: backlog)
    }
}
