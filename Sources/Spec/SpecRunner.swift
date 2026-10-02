import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

/// One differential run: the classified diff, the candidate's replay cassette (so the verdict can
/// carry the coverage it was measured over), and the probe's evidence (so the sweep can re-match
/// declarations against what the probe left behind).
struct ProbeComparison {
    var diff: TraceDiff
    let candidateReplay: Cassette
    let evidence: ProbeEvidence
}

/// The golden template and everything resolved off it (see `goldenSurface()`).
private struct GoldenSurface<S> {
    let golden: CassetteData
    let plan: ExplorationPlan<S>
    let qualification: Qualification
}

public extension Spec {
    /// Differentially verifies a candidate implementation against this spec's baseline: runs both
    /// against the *same* generated inputs (call orderings × seam values) and diffs. The baseline branch
    /// is the oracle, so no expected output is needed. A divergence does not stop the sweep: every
    /// probe runs, and the richest failing case is shrunk and reported (`RedCases`).
    ///
    /// `declaring` is the *candidate's* intent — the deltas this particular port is meant to produce.
    /// It rides the verification call rather than the spec because the spec declares the subject's
    /// behavior, which every candidate shares; what a given port changes is a fact about that port.
    func verify(
        against candidate: @escaping (SeamContext) -> S,
        declaring intent: Intent = .none
    ) async -> SpecVerdict {
        await collectingOrigins(declaring: intent) {
            await differentialVerdict(against: candidate, declaring: intent)
        }
    }

    private func differentialVerdict(
        against candidate: @escaping (SeamContext) -> S,
        declaring intent: Intent
    ) async -> SpecVerdict {
        let surface = await goldenSurface()
        let (golden, plan, qualification) = (surface.golden, surface.plan, surface.qualification)

        // Sweep-wide intent facts (disclosure + unobserved intersection) — see `IntentSweep`.
        var sweep = IntentSweep(intent: intent)
        var reds = RedCases<DivergedRun>()
        for (index, order) in plan.orderings.enumerated() {
            for cassette in plan.cassettes(forOrdering: index) {
                let run = await compare(
                    make: makeSystem,
                    candidate: candidate,
                    order: order,
                    cassette: cassette,
                    declaring: intent
                )
                sweep.observe(run, ordering: order.map(\.label), inputs: cassette)
                reds.observe(
                    DivergedRun(diff: run.diff, candidateReplay: run.candidateReplay, order: order, cassette: cassette),
                    ordering: order.map(\.label),
                    inputs: cassette,
                    diff: run.diff
                )
            }
        }
        if let reported = reds.reported {
            return await divergedLiveVerdict(
                run: reported,
                failingCases: reds.cases,
                candidate: candidate,
                surface: surface,
                declaring: intent
            )
        }
        // Held across the whole explored surface: the swept seams earn domain-coverage credit.
        var representative = await compare(
            make: makeSystem,
            candidate: candidate,
            order: operations,
            cassette: golden,
            declaring: intent
        )
        sweep.observe(representative, ordering: operations.map(\.label), inputs: golden)
        representative.diff = sweep.settle(representative.diff)
        let coverage = plannedCoverage(replay: representative.candidateReplay, domainHeld: true, plan: plan)
        return SpecVerdict(
            result: VerificationResult(diff: representative.diff, coverage: coverage),
            orderingsExplored: plan.orderings.count,
            failingOrder: nil,
            counterexample: nil,
            exploration: plan.exploration,
            qualification: qualification,
            intentObservations: sweep.observations
        )
    }

    /// A failing comparison of the live sweep, with everything the diverged exit needs to pin it.
    private struct DivergedRun {
        let diff: TraceDiff
        let candidateReplay: Cassette
        let order: [Op<S>]
        let cassette: CassetteData
    }

    /// The red exit of the live sweep: shrinks the reported case's order, pins what exposed it, and
    /// carries every failing case.
    ///
    /// Makes no unobserved-intent claim: the reported diff is one case's, and a declaration it did
    /// not match may have held in another.
    private func divergedLiveVerdict(
        run: DivergedRun,
        failingCases: FailingCases,
        candidate: @escaping (SeamContext) -> S,
        surface: GoldenSurface<S>,
        declaring intent: Intent
    ) async -> SpecVerdict {
        var diff = run.diff
        diff.unobservedIntent = []
        let shrunk = await shrink(
            candidate: candidate,
            failing: run.order,
            cassette: run.cassette,
            declaring: intent
        )
        let coverage = plannedCoverage(replay: run.candidateReplay, domainHeld: false, plan: surface.plan)
        let failing = exploreOrdering ? shrunk.map(\.label) : nil
        return SpecVerdict(
            result: VerificationResult(diff: diff, coverage: coverage),
            orderingsExplored: surface.plan.orderings.count,
            failingOrder: failing,
            counterexample: surface.plan.domains.isEmpty ? nil : run.cassette,
            exploration: surface.plan.exploration,
            qualification: surface.qualification,
            violatedPreconditions: failing.map(preconditionViolations(in:)),
            failingCases: failingCases
        )
    }

    // MARK: - Hidden machinery

    /// One replay's coverage against the plan's varied surface — the plan's domains, not the
    /// declaration's, so packaged resource sweeps earn the same credit an authored `Seam` does.
    private func plannedCoverage(replay: Cassette, domainHeld: Bool, plan: ExplorationPlan<S>) -> Coverage {
        coverage(replays: [replay], domainHeld: domainHeld, sweptSeams: Array(plan.domains.keys))
    }

    /// Records the golden template — the declared order under live seams, the template every variation
    /// is derived from — and resolves the explored surface plus the qualification measured off it.
    private func goldenSurface() async -> GoldenSurface<S> {
        let recording = Cassette(recordingPreferring: goldenReadings)
        let goldenTrace = await capture(make: makeSystem, order: explorationOrder(), cassette: recording)
        let golden = recording.snapshot()
        let plan = explorationPlan(golden: golden)
        let qualification = liveQualification(
            goldenTrace: goldenTrace,
            golden: golden,
            exploration: plan.exploration
        )
        return GoldenSurface(golden: golden, plan: plan, qualification: qualification)
    }

    /// The longest call sequence exploration can produce: the declared ops, each repeated as far as
    /// `Ordering(repeating:)` allows. The golden cassette is recorded over *this* rather than the
    /// declared order, so every explored ordering has enough recorded seam readings — a shorter one
    /// just consumes a prefix of each track. Recording over the declared order instead would leave a
    /// repeated op's second read with nothing to replay, which surfaces as an `.unrecorded` gap and
    /// downgrades an otherwise-equivalent verdict to CANNOT-VERIFY.
    func explorationOrder() -> [Op<S>] {
        guard exploreOrdering else {
            return operations
        }
        return operations.flatMap { operation in
            Array(repeating: operation, count: operation.occurrences(default: orderingRepeats).upperBound)
        }
    }

    /// Drives one (system, ordering, cassette) and returns its behavior trace — the recorder, interceptor,
    /// and ambient context the developer never touches. (Internal: `record`/`verify(replaying:)` drive
    /// the same primitive across a build boundary.)
    func capture(make: (SeamContext) -> S, order: [Op<S>], cassette: Cassette) async -> Trace {
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
        // Task-locals are inherited across `await`, so binding once around the whole loop still
        // reaches an operation that suspends — which is what lets an op drive an actor. The op
        // identity is bound per operation, so every event — and every block or task the op spawns,
        // which the seams carry it into — is attributed to the declared op that caused it.
        await TraceContext.$current.withValue(recorder) {
            for (position, operation) in order.enumerated() {
                await TraceContext.$currentOp.withValue(OpIdentity(label: operation.label, position: position)) {
                    await operation.action(system, context)
                }
            }
        }
        // Drain *after* the window, not inside it. Work the ops dispatched carries the recorder the
        // seam captured at enqueue, so it records whether or not the window is still open — but it has
        // to have finished, or the snapshot is a race rather than a reading. Drained in rounds: a
        // quiesced round may leave virtual timers holding a pipeline's deferred tail (a debounce),
        // which fire only at quiescence — the settled point is a round that releases nothing further.
        var rounds = 0
        while true {
            if await DispatchSeam.quiesce() == false {
                recorder.marker("⟨haruspec: work still outstanding at snapshot⟩")
                break
            }
            rounds += 1
            if rounds > SpecDefaults.maxTimerRounds {
                recorder.marker("⟨haruspec: deferred timers still re-arming at snapshot⟩")
                break
            }
            guard DeferredTimers.fire(for: recorder) else { break }
        }
        // The end-state snapshots: after quiescence (a racing read is not a reading), the harness
        // itself reads each observed property back. Harness-read on both sides by construction — the
        // state contract, which gates.
        for property in observedProperties {
            await recorder.snapshot(property.label, value: RuntimeValue.canonical(property.read(system)))
        }
        return recorder.trace()
    }

    /// One differential run. The diff is already intent-classified: with a declared intent the loop
    /// must not stop on an intended-only divergence set, so classification lives here, not at exits.
    private func compare(
        make: (SeamContext) -> S,
        candidate: (SeamContext) -> S,
        order: [Op<S>],
        cassette: CassetteData,
        declaring intent: Intent
    ) async -> ProbeComparison {
        let baseline = await capture(make: make, order: order, cassette: Cassette(replaying: cassette))
        let replay = Cassette(replaying: cassette)
        let candidateTrace = await capture(make: candidate, order: order, cassette: replay)
        let evidence = ProbeEvidence(
            inputs: cassette.tracks,
            baseline: baseline,
            candidate: candidateTrace,
            tolerances: tolerances
        )
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidateTrace,
            tolerances: tolerances
        )
        .classified(against: intent, evidence: evidence)
        return ProbeComparison(diff: diff, candidateReplay: replay, evidence: evidence)
    }

    private func diverges(
        candidate: (SeamContext) -> S,
        order: [Op<S>],
        cassette: CassetteData,
        declaring intent: Intent
    ) async -> TraceDiff? {
        let diff = await compare(
            make: makeSystem,
            candidate: candidate,
            order: order,
            cassette: cassette,
            declaring: intent
        ).diff
        return diff.isEquivalent ? nil : diff
    }

    /// Assembles the spec's coverage: the declared surface is the *interrogation* surface — every op
    /// (as an `op:<label>` boundary) plus every seam the replays declared. Ops all ran by construction
    /// here (the replay path is where an op can go unrecorded); seams merge across the given replays,
    /// and a seam missed anywhere is never counted exercised. `domainHeld` awards the swept seams
    /// domain-coverage credit — additive evidence, only when the property held over the surface.
    func coverage(
        replays: [Cassette],
        domainHeld: Bool,
        declaredOps: [String]? = nil,
        missingOps: [String] = [],
        sweptSeams: [String]? = nil
    ) -> Coverage {
        var declared = Set<String>(), exercised = Set<String>()
        var gaps: [Coverage.Gap] = []
        var seenGaps = Set<String>()
        for replay in replays {
            let seams = replay.coverage()
            declared.formUnion(seams.declared)
            exercised.formUnion(seams.exercised)
            for gap in seams.gaps where gap.reason == .unrecorded {
                let key = "\(gap.boundary)#\(gap.ordinal ?? -1)"
                if seenGaps.insert(key).inserted {
                    gaps.append(gap)
                }
            }
        }
        let missedSeams = Set(gaps.map(\.boundary))
        exercised.subtract(missedSeams)
        for seam in declared where !exercised.contains(seam) && !missedSeams.contains(seam) {
            gaps.append(Coverage.Gap(boundary: seam, reason: .unexercised))
        }

        let ops = declaredOps ?? operations.map(\.label)
        let opBoundaries = ops.map { "op:\($0)" }
        let exercisedOps = ops.filter { !missingOps.contains($0) }.map { "op:\($0)" }
        gaps += missingOps.map { Coverage.Gap(boundary: "op:\($0)", reason: .unrecorded) }

        // A domain declared for a key nothing read applied to nothing, and the run reports a swept
        // surface it never swept. Only knowable once the golden has been recorded — which reads is not
        // a static property of a spec — so it is caught here rather than at construction.
        let declaredDomains = Set(sweptSeams ?? Array(seamDomains.keys))
        let unmatched = declaredDomains.subtracting(declared).sorted()
        gaps += unmatched.map { Coverage.Gap(boundary: $0, reason: .unmatchedDomain) }

        let swept = domainHeld ? declaredDomains.intersection(declared) : []
        return Coverage(
            // An unmatched domain joins the declared surface: the author declared it, and leaving it out
            // would report a fraction of a surface quietly smaller than the one the spec describes.
            declared: opBoundaries + declared.sorted() + unmatched,
            exercised: exercisedOps + exercised.sorted(),
            gaps: gaps,
            domainExercised: swept.sorted()
        )
    }

    /// Delta-debugs the failing call sequence: drops ops that aren't needed to reproduce → the minimal
    /// order that still diverges (the "localize" the north star asks for, applied to sequencing).
    private func shrink(
        candidate: @escaping (SeamContext) -> S,
        failing: [Op<S>],
        cassette: CassetteData,
        declaring intent: Intent
    ) async -> [Op<S>] {
        var minimal = failing
        var index = 0
        while index < minimal.count {
            var trial = minimal
            trial.remove(at: index)
            if !trial.isEmpty, await diverges(
                candidate: candidate,
                order: trial,
                cassette: cassette,
                declaring: intent
            ) != nil {
                minimal = trial // op wasn't needed to reproduce
            } else {
                index += 1
            }
        }
        return minimal
    }
}
