import Dispatch
import Foundation

// The Swift half of the GCD seam — the counterpart to the preprocessing seam
// (`Sources/DispatchSeam/haruspec_dispatch.h`), which cannot reach Swift because Swift has no
// preprocessor.
//
// The lever is overload resolution rather than the preprocessor. `DispatchQueue.async`'s real member
// is `async(group:qos:flags:execute:)` with every parameter but the last defaulted, and Swift
// **prefers a candidate that requires no default arguments to be inserted**. So an overload taking
// only `execute:` wins at `queue.async { … }` — the overwhelmingly common shape — with no call-site
// change, which is the same bargain the C seam strikes.
//
// Coverage is exact and worth stating plainly: every *proper subset* of the defaulted parameters can
// be claimed by its own overload, and each is preferred over the real member for the same reason.
// Only the fully-specified `async(group:qos:flags:execute:)` is unreachable — an overload matching it
// exactly would be ambiguous rather than preferred. That call is rare, and it degrades to today's
// behaviour (uncaptured) rather than to anything wrong.
//
// Like the C seam, each overload is a strict pass-through when no capture is active: `seamWrap`
// returns the block untouched and nothing is counted.
//
// **Debug-only, by construction.** An overload on a Dispatch type enters the resolution set of every
// consumer that imports Haruspec, which is a real cost to impose unconditionally — so it does not
// exist in a release build at all. That mirrors the C half's build-setting gate and the `#if DEBUG`
// guard `@Traced` already emits: instrumentation is a debug-configuration property throughout.
#if DEBUG
    public extension DispatchQueue {
        func async(execute work: @escaping @Sendable () -> Void) {
            async(group: nil, qos: .unspecified, flags: [], execute: DispatchSeam.seamWrap(work))
        }

        func async(qos: DispatchQoS, execute work: @escaping @Sendable () -> Void) {
            async(group: nil, qos: qos, flags: [], execute: DispatchSeam.seamWrap(work))
        }

        func async(flags: DispatchWorkItemFlags, execute work: @escaping @Sendable () -> Void) {
            async(group: nil, qos: .unspecified, flags: flags, execute: DispatchSeam.seamWrap(work))
        }

        func async(group: DispatchGroup, execute work: @escaping @Sendable () -> Void) {
            async(group: group, qos: .unspecified, flags: [], execute: DispatchSeam.seamWrap(work))
        }

        func async(
            qos: DispatchQoS,
            flags: DispatchWorkItemFlags,
            execute work: @escaping @Sendable () -> Void
        ) {
            async(group: nil, qos: qos, flags: flags, execute: DispatchSeam.seamWrap(work))
        }

        func asyncAfter(deadline: DispatchTime, execute work: @escaping @Sendable () -> Void) {
            asyncAfter(deadline: deadline, qos: .unspecified, flags: [], execute: DispatchSeam.seamWrap(work))
        }
    }

    /// The creation half of the Swift seam: `DispatchQueue.init` defaults everything but `label`, so
    /// these overloads win at the two common creation shapes and record the queue's ordering
    /// discipline — the fact stated only here, and needed later to decide whether the queue's order
    /// is a contract (serial) or scheduler noise (concurrent). Delegating with every parameter
    /// spelled out resolves to the real initializer, which no overload here claims.
    public extension DispatchQueue {
        convenience init(label: String) {
            DispatchSeam.registerQueue(label: label, serial: true)
            self.init(label: label, qos: .unspecified, attributes: [], autoreleaseFrequency: .inherit, target: nil)
        }

        convenience init(label: String, attributes: DispatchQueue.Attributes) {
            DispatchSeam.registerQueue(label: label, serial: !attributes.contains(.concurrent))
            self.init(
                label: label,
                qos: .unspecified,
                attributes: attributes,
                autoreleaseFrequency: .inherit,
                target: nil
            )
        }
    }

    /// The same lever, applied to `Task`. `Task.init` defaults `priority:`, so an overload claiming
    /// only `operation:` is preferred at `Task { … }`.
    ///
    /// The problem here is **counting**, not reaching: a task inherits task-locals, so the recorder is
    /// already found — but nothing marks the work outstanding, so an unawaited task races the trace
    /// snapshot. A task whose value is awaited was never the problem, because awaiting it *is*
    /// quiescence; fire-and-forget is, and fire-and-forget is `Success == Void`.
    ///
    /// `detached` needs the wrapper for both reasons: it inherits nothing, so it is uncounted *and*
    /// unreachable. One wrapper serves both, since rebinding a recorder a task already inherited is a
    /// no-op.
    public extension Task where Failure == Never, Success == Void {
        init(operation: @escaping @Sendable () async -> Void) {
            self.init(priority: nil, operation: DispatchSeam.seamWrapTask(operation))
        }

        static func detached(operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
            Task.detached(priority: nil, operation: DispatchSeam.seamWrapTask(operation))
        }
    }

#endif

public extension DispatchSeam {
    /// Wrap a Swift closure so it carries the enqueueing context and counts as outstanding work — the
    /// same contract as the C shim's `haruspec_seam_wrap`, reached from Swift instead of from a block.
    /// Wrap an unawaited task's body so it counts as outstanding work, and so a *detached* task —
    /// which inherits nothing — still finds the recorder its spawn site had.
    static func seamWrapTask(
        _ operation: @escaping @Sendable () async -> Void
    ) -> @Sendable () async -> Void {
        guard let recorder = acquireForSwift() else { return operation }
        // Read at the enqueue: this is the only moment both ends of the edge are in hand.
        let cause = recorder.enclosingCallSeq()
        return {
            await TraceContext.$current.withValue(recorder) {
                await TraceContext.$pendingSpawnCause.withValue(TraceContext.SpawnCause(cause)) {
                    await operation()
                }
            }
            finishForSwift()
        }
    }

    static func seamWrap(
        _ work: @escaping @Sendable () -> Void,
        named: String? = nil,
        serial: Bool? = nil
    ) -> @Sendable () -> Void {
        guard let recorder = acquireForSwift() else { return work }
        let cause = recorder.enclosingCallSeq()
        return {
            markingQueueEntry(named: named, serial: serial) {
                TraceContext.withThreadRecorder(recorder, spawnedBy: cause) { work() }
            }
            finishForSwift()
        }
    }
}
