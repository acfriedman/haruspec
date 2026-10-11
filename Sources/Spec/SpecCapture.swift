import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

// The capture primitive every run shares: one (system, ordering, cassette) driven to a trace. A
// verify, a record and a replay all differ only in what they hand it.

extension Spec {
    /// Drives one (system, ordering, cassette) and returns its behavior trace — the recorder, interceptor,
    /// and ambient context the developer never touches. (Internal: `record`/`verify(replaying:)` drive
    /// the same primitive across a build boundary.)
    func capture(make: (SeamContext) -> S, order: [Op<S>], cassette: Cassette) async -> Trace {
        await captured(make: make, order: order, cassette: cassette).trace
    }

    /// One capture's trace, and whether a settle point would have had anything to land.
    struct Captured {
        let trace: Trace
        /// Whether held work was waiting when an operation returned and another was still to run.
        ///
        /// That is the only place a settle step can change anything. A subject whose seamed work
        /// all lands inside its own operations (a `sync`, a completion it waits for) gives settle
        /// points nothing to explore.
        let heldWorkAtGaps: Bool
    }

    /// ``capture(make:order:cassette:)``, reporting whether the subject held work across a gap.
    ///
    /// - Parameters:
    ///   - make: Builds the system for this capture.
    ///   - order: The ordering to drive, settle steps included.
    ///   - cassette: The seam readings to answer with.
    /// - Returns: The trace, and whether held work waited at a gap.
    func captured(make: (SeamContext) -> S, order: [Op<S>], cassette: Cassette) async -> Captured {
        for operation in order {
            Self.refuseIsolated(operation)
        }
        let recorder = TraceRecorder(name: name, clock: ManualClock())
        // The SUT posts through a center that records, so a notification takes the same path and the
        // same recorder lookup as every other kind of event. There is no second mechanism.
        let center = RecordingNotificationCenter()
        let context = SeamContext(
            notifications: center,
            cassette: cassette,
            makers: valueMakers,
            resourceMakers: specResourceMakers
        )
        // Every build records through the spec's capture boundary, however it was constructed — the
        // one choke point for baseline, candidate, record and replay alike.
        let wrap = wrapCandidate ?? StampedForwarderRegistry.wrap(S.self)
        let system = wrap(make(context))
        let sampler = StateSampler(system: system, properties: observedProperties, recorder: recorder)
        context.backlog.settled = { await sampler.sample() }
        // Task-locals are inherited across `await`, so binding once around the whole loop still
        // reaches an operation that suspends — which is what lets an op drive an actor. The op
        // identity is bound per operation, so every event — and every block or task the op spawns,
        // which the seams carry it into — is attributed to the declared op that caused it.
        await sampler.sample()
        // A settle step is the engine's, not the subject's: it lets held work land and takes no
        // position, so an op is numbered the same under every settle schedule of one ordering.
        let operationCount = order.filter { $0.settle == nil }.count
        var position = 0
        var heldWorkAtGaps = false
        // This function is nonisolated `async`, so the capture's own frames never run on main, and
        // anything recorded there got there through the subject.
        await TraceContext.$capturesOffMain.withValue(true) {
            await TraceContext.$current.withValue(recorder) {
                await WorkBacklog.$current.withValue(context.backlog) {
                    for operation in order {
                        if let settle = operation.settle {
                            await context.backlog.settle(settle, recorder: recorder)
                            continue
                        }
                        await TraceContext.$currentOp.withValue(OpIdentity(
                            label: operation.label,
                            position: position
                        )) {
                            await operation.action(system, context)
                            await sampler.sample()
                        }
                        position += 1
                        if position < operationCount, context.backlog.pendingCount > 0 {
                            heldWorkAtGaps = true
                        }
                    }
                }
            }
            // Drain what the settle schedule left held. Held work carries the op and cause it was enqueued
            // under, and runs with the recorder rebound — but it has to have run, or the snapshot is a
            // reading of a program that has not finished. Delayed work fires on virtual time once nothing
            // else is ready, so a debounce's deferred tail lands inside the capture too.
            if await context.backlog.drain(recorder: recorder) == false {
                recorder.marker("⟨haruspec: scheduled work still held at snapshot⟩")
            }
        }
        // The end-state snapshots: after quiescence (a racing read is not a reading), the harness
        // itself reads each observed property back. Harness-read on both sides by construction — the
        // state contract, which gates.
        for property in observedProperties {
            await recorder.snapshot(property.label, value: RuntimeValue.canonical(property.read(system)))
        }
        return Captured(trace: recorder.trace(), heldWorkAtGaps: heldWorkAtGaps)
    }

    /// Traps on an op whose closure is isolated to an actor, naming the fix.
    ///
    /// - Parameter operation: The op about to run.
    /// - Precondition: `operation`'s closure is nonisolated.
    private static func refuseIsolated(_ operation: Op<S>) {
        if let refusal = isolationRefusal(operation) {
            preconditionFailure(refusal)
        }
    }

    /// The teaching message for an op whose closure is isolated to an actor; `nil` for a nonisolated one.
    ///
    /// - Parameter operation: The op about to run.
    /// - Returns: The refusal naming the op, its actor, and the fix; `nil` when the op may run.
    ///
    /// A capture reads the main thread as the subject's doing, because its own frames run off main
    /// (`TraceContext.capturesOffMain`). An op closure written in a `@MainActor` context runs on main,
    /// so the subject's nonisolated code under it would read `main`, and a port that drops a main hop
    /// would pass. Every op is nonisolated instead, which also keeps the rule one sentence long.
    static func isolationRefusal(_ operation: Op<S>) -> String? {
        guard let isolation = operation.isolation else {
            return nil
        }
        let actor = isolation === MainActor.shared ? "the main actor" : "actor \(type(of: isolation))"
        return "op '\(operation.label)' runs on \(actor): its closure was written in an isolated context. "
            + "A capture reads the main thread as the subject's isolation, so an isolated op would "
            + "make the subject's nonisolated code read as isolated. Write the op where nothing "
            + "isolates it: mark the spec type `nonisolated` (needed under default MainActor "
            + "isolation), or move it out of the @MainActor type. A subject's isolated method is "
            + "still reachable from a nonisolated op with `await`."
    }
}
