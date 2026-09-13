import Foundation
import HaruspecCore

// The Combine half of the scheduling seam (property-mutation-tracing phase B, step one). A Combine
// pipeline defers its work through `Scheduler`s the dispatch seam never sees — the delivery hop in
// `receive(on:)` and, worse, the timer inside `debounce`, which fires long after quiescence and
// leaves the whole pipeline outside the capture window. The lever is the same overload preference
// that claimed `DispatchQueue.async` and `Task.init`: the scheduler-taking operators default their
// `options:`, so an overload without it wins at the common call shape and wraps the scheduler.
//
// Two behaviors, both capture-scoped (outside a capture every path is a verbatim pass-through):
//  - immediate scheduling counts as outstanding work, so quiescence waits through the pipeline —
//    the symmetry fix: a `Task`-based port was always waited on, the Combine baseline never was;
//  - `schedule(after:)` work is **virtual time**: held, then fired at quiescence, in rounds, until
//    nothing re-arms. A debounce "fires when the quiet period arrives", and quiescence is the
//    settled point — deterministic on both sides where wall-clock waiting would be neither.

/// The deferred-timer registry: work a wrapped scheduler virtualized, keyed by the capture it
/// belongs to so parallel captures cannot fire each other's timers.
public enum DeferredTimers {
    private struct Held {
        /// The requested delay, for fire ordering — `Int.max` when the scheduler's stride could
        /// not be read, so unreadable timers fire last rather than nondeterministically.
        let delayMilliseconds: Int
        let fire: () -> Void
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var pending: [ObjectIdentifier: [Held]] = [:]

    /// Holds one timer's fire action for `recorder`'s quiescence. The action must carry its own
    /// counting and recorder rebinding — at fire time the capture window's task-local is gone.
    static func hold(for recorder: TraceRecorder, delayMilliseconds: Int?, _ fire: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        pending[ObjectIdentifier(recorder), default: []]
            .append(Held(delayMilliseconds: delayMilliseconds ?? .max, fire: fire))
    }

    /// Fires every timer currently held for `recorder`; returns whether anything fired. Firing
    /// order is requested delay, then scheduling order — under virtual time there is no clock
    /// axis, and the declared delay is the deterministic stand-in for "which fires first" when
    /// independent pipelines wait different lengths. A stale debounce generation no-ops (its
    /// token is cancelled) — firing the batch is how "the quiet period arrived" resolves. Called
    /// by the capture's drain loop between quiesce rounds; a fired timer may schedule more work
    /// and more timers, so the loop comes back.
    public static func fire(for recorder: TraceRecorder) -> Bool {
        lock.lock()
        let batch = pending.removeValue(forKey: ObjectIdentifier(recorder)) ?? []
        lock.unlock()
        for held in batch.enumerated().sorted(by: { ($0.element.delayMilliseconds, $0.offset) < (
            $1.element.delayMilliseconds,
            $1.offset
        ) }) {
            held.element.fire()
        }
        return !batch.isEmpty
    }
}

#if DEBUG
    #if canImport(Combine)
        import Combine

        /// A scheduler wrapped for capture: immediate work is counted (quiescence waits through the
        /// pipeline), `schedule(after:)` becomes a virtual timer fired at quiescence, and each
        /// scheduled action runs marked as a queue entry with the capture's recorder rebound — so the
        /// events inside it carry the delivery context's domain. Outside a capture, every path
        /// forwards verbatim.
        public struct TracedScheduler<Wrapped: Scheduler>: Scheduler {
            public typealias SchedulerTimeType = Wrapped.SchedulerTimeType
            public typealias SchedulerOptions = Wrapped.SchedulerOptions

            let wrapped: Wrapped

            init(wrapping wrapped: Wrapped) {
                self.wrapped = wrapped
            }

            public var now: SchedulerTimeType {
                wrapped.now
            }

            public var minimumTolerance: SchedulerTimeType.Stride {
                wrapped.minimumTolerance
            }

            public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) {
                guard let recorder = TraceContext.active else {
                    return wrapped.schedule(options: options, action)
                }
                let body = CombineSeam.rebinding(action, for: recorder)
                DispatchSeam.beginCountedForSwift()
                wrapped.schedule(options: options, body)
            }

            /// The virtual-time path: under capture the delay is not waited out — the action is held
            /// and fired at quiescence, on the wrapped scheduler. Counting starts at *fire*, never
            /// while held: a held timer outstanding would deadlock the very quiescence that fires it.
            /// The requested delay is declared data in hand at the seam (never measured), so each
            /// surviving fire records it as a `.timer` event — a retimed pipeline diverges on the
            /// delay value, deterministically.
            public func schedule(
                after date: SchedulerTimeType,
                tolerance: SchedulerTimeType.Stride,
                options: SchedulerOptions?,
                _ action: @escaping () -> Void
            ) {
                guard let recorder = TraceContext.active else {
                    return wrapped.schedule(after: date, tolerance: tolerance, options: options, action)
                }
                let delay = delayMilliseconds(until: date)
                let body = CombineSeam.rebinding(recorded(delay, on: recorder, action), for: recorder)
                DeferredTimers.hold(for: recorder, delayMilliseconds: delay) {
                    DispatchSeam.beginCountedForSwift()
                    wrapped.schedule(options: options, body)
                }
            }

            /// The cancellable form is where the timers that matter actually live — **`debounce`
            /// schedules each value's quiet-period wait through here** (measured: one `interval`
            /// call per upstream value, cancelled when a newer value supersedes it). Virtualized
            /// like the single-shot form, honoring the cancellation: a superseded generation's held
            /// timer is dead by the time quiescence fires the batch, so exactly the surviving wait
            /// delivers. A genuinely repeating cadence gets one virtual tick, not a spin — there is
            /// no honest quiescence point for "forever", and one settled tick is the deterministic
            /// reading of "the cadence was live".
            public func schedule(
                after date: SchedulerTimeType,
                interval: SchedulerTimeType.Stride,
                tolerance: SchedulerTimeType.Stride,
                options: SchedulerOptions?,
                _ action: @escaping () -> Void
            ) -> Cancellable {
                guard let recorder = TraceContext.active else {
                    return wrapped.schedule(
                        after: date,
                        interval: interval,
                        tolerance: tolerance,
                        options: options,
                        action
                    )
                }
                // The declared stride, never a clock difference: a date-derived reading costs a
                // second `now` read after the operator's own, and shrinks under load (300 → 299).
                let delay = milliseconds(of: interval)
                let body = CombineSeam.rebinding(recorded(delay, on: recorder, action), for: recorder)
                let token = VirtualTimerToken()
                DeferredTimers.hold(for: recorder, delayMilliseconds: delay) {
                    guard !token.isCancelled else { return }
                    DispatchSeam.beginCountedForSwift()
                    wrapped.schedule(options: options, body)
                }
                return token
            }

            /// The one-shot form's delay: read off the fire date, which costs one `now` read —
            /// rounding absorbs sub-half-millisecond jitter, the best available when the call
            /// declared no stride.
            private func delayMilliseconds(until date: SchedulerTimeType) -> Int? {
                milliseconds(of: wrapped.now.distance(to: date))
            }

            /// A stride as whole milliseconds, normalized across the stock schedulers (nanosecond
            /// `Int` strides and second `Double` strides). Pure — no clock read, so a declared
            /// stride records as data, never as measurement. `nil` for a scheduler whose stride
            /// exposes neither, which fires last and records its absence honestly.
            func milliseconds(of stride: SchedulerTimeType.Stride) -> Int? {
                if let nanoseconds = stride.magnitude as? Int {
                    return Int((Double(nanoseconds) / 1_000_000).rounded())
                }
                if let seconds = stride.magnitude as? Double {
                    return Int((seconds * 1000).rounded())
                }
                return nil
            }

            /// Prefixes `action` with the `.timer` event carrying the requested delay — recorded at
            /// fire, inside the marked queue entry, so the event lands in the delivery domain and
            /// only the *surviving* generation records (a cancelled one never runs).
            private func recorded(
                _ delayMilliseconds: Int?,
                on recorder: TraceRecorder,
                _ action: @escaping () -> Void
            ) -> () -> Void {
                let delay: CanonicalValue = delayMilliseconds
                    .map { .int(Int64($0)) } ?? .string("unreadable stride")
                return {
                    recorder.timerFired(delay: delay)
                    action()
                }
            }
        }

        /// The overloads that claim the scheduler-taking operators — each real member defaults
        /// `options:`, so the candidate without it is preferred at the common call shape, and the
        /// scheduler travels on wrapped. `#if DEBUG` for the same reason the Dispatch overloads are:
        /// entering every importer's resolution set is a debug-configuration property.
        public extension Publisher {
            func receive<S: Scheduler>(on scheduler: S) -> Publishers.ReceiveOn<Self, TracedScheduler<S>> {
                receive(on: TracedScheduler(wrapping: scheduler), options: nil)
            }

            func subscribe<S: Scheduler>(on scheduler: S) -> Publishers.SubscribeOn<Self, TracedScheduler<S>> {
                subscribe(on: TracedScheduler(wrapping: scheduler), options: nil)
            }

            func debounce<S: Scheduler>(
                for dueTime: S.SchedulerTimeType.Stride,
                scheduler: S
            ) -> Publishers.Debounce<Self, TracedScheduler<S>> {
                debounce(for: dueTime, scheduler: TracedScheduler(wrapping: scheduler), options: nil)
            }

            // `throttle(for:scheduler:latest:)` deliberately has no overload here: it defaults
            // nothing, so a same-shape candidate would be ambiguous rather than preferred — the
            // `sink` risk the epic card names. Its scheduler stays unwrapped for now.
            func delay<S: Scheduler>(
                for interval: S.SchedulerTimeType.Stride,
                scheduler: S
            ) -> Publishers.Delay<Self, TracedScheduler<S>> {
                delay(for: interval, tolerance: nil, scheduler: TracedScheduler(wrapping: scheduler), options: nil)
            }
        }

        /// The cancellation half of a virtual timer: Combine cancels a superseded debounce
        /// generation through the `Cancellable` it got back, and the held fire closure checks this
        /// token before scheduling anything — cancellation semantics survive virtualization intact.
        final class VirtualTimerToken: Cancellable, @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false

            var isCancelled: Bool {
                lock.lock(); defer { lock.unlock() }
                return cancelled
            }

            func cancel() {
                lock.lock(); defer { lock.unlock() }
                cancelled = true
            }
        }

        /// The wrap shared by both scheduling paths: runs the action as a marked queue entry with
        /// `recorder` rebound, and balances the count its caller began — `DispatchSeam.seamWrap`
        /// minus the `@Sendable` requirement a `Scheduler` action does not carry. The spawn cause is
        /// read here, at schedule time, the only moment both ends of the edge are in hand.
        enum CombineSeam {
            static func rebinding(_ action: @escaping () -> Void, for recorder: TraceRecorder) -> () -> Void {
                let cause = recorder.enclosingCallSeq()
                let op = TraceContext.activeOp
                return {
                    DispatchSeam.markingQueueEntry {
                        TraceContext.withThreadRecorder(recorder, spawnedBy: cause, op: op) { action() }
                    }
                    DispatchSeam.finishForSwift()
                }
            }
        }
    #endif
#endif
