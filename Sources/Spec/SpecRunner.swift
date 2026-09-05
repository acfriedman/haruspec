import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

/// The outcome of a spec run: the resolved verdict *with the coverage it was measured over*, how
/// much was explored, and — for an order-dependent divergence — the failing call sequence: shrunk to
/// minimal by `verify(against:)`, but the *raw recorded ordering* on `verify(replaying:)`, which never
/// shrinks (a shrunk variant has no recorded golden to diff against).
/// `Codable`, so a verify run is writable as a `result.json` artifact a reviewer can read and reproduce.
public struct SpecVerdict: Codable, Sendable {
    /// The artifact's version stamp — `SpecPlan`'s discipline applied to the verdict side (see
    /// `supportedSchemaVersion` in SpecVerdictSerialization.swift). An unstamped `result.json`
    /// predates the qualification block and is refused with "re-run", never part-decoded.
    public let schemaVersion: Int
    /// The diff + coverage pair carrying the *resolved* verdict (see `VerificationResult`): an
    /// EQUIVALENT the replay can't stand behind (an op or seam fell back to live) downgrades to
    /// CANNOT-VERIFY; a DIVERGED always stands.
    public let result: VerificationResult
    public let orderingsExplored: Int
    public let failingOrder: [String]?
    /// Declared `.after` preconditions the failing order broke, as `"removeMug after addMug"`. That
    /// stratum is explored on purpose, so a divergence here is a finding about a defensive path — worth
    /// separating from one on the surface the author described. Empty on an in-order failure, `nil`
    /// where no order was reported at all.
    public let violatedPreconditions: [String]?
    /// The generated input that triggered a divergence (its varied seam values are the counterexample).
    public let counterexample: CassetteData?
    /// The budget spent and the surface it covered.
    public let exploration: Exploration
    /// What the verdict was measured over — the disclaimer's feeds, rendered as the qualification
    /// block on every surface (see Qualification.swift). No default: an empty qualification would
    /// claim a surface of nothing, which is a statement, not an absence.
    public let qualification: Qualification
    /// How the verdict behaved across repeated replays. `.singleRun` where repetition never happened
    /// (the live differential, a one-pass replay) — reported as unmeasured, never as reproduced.
    public let stability: Stability
    /// Channels the spec and check site declared acceptable as uncaptured, carried on the verdict so
    /// *every* audit path resolves the same declarations — the env-driven audit inside a verify and
    /// an explicit `audited(against:)` afterwards must not disagree. `nil` on artifacts recorded
    /// before the field existed; treated as none declared.
    public let acceptedBlindSpots: [String]?

    public init(
        schemaVersion: Int = SpecVerdict.supportedSchemaVersion,
        result: VerificationResult,
        orderingsExplored: Int,
        failingOrder: [String]?,
        counterexample: CassetteData?,
        exploration: Exploration,
        qualification: Qualification,
        violatedPreconditions: [String]? = nil,
        stability: Stability = .singleRun,
        acceptedBlindSpots: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.result = result
        self.orderingsExplored = orderingsExplored
        self.failingOrder = failingOrder
        self.counterexample = counterexample
        self.exploration = exploration
        self.qualification = qualification
        self.violatedPreconditions = violatedPreconditions
        self.stability = stability
        self.acceptedBlindSpots = acceptedBlindSpots
    }

    /// The resolved verdict, with stability applied above coverage: disagreeing replays flip *any*
    /// underlying verdict to UNSTABLE — a coin flip reported as red (or green) would spend the gate's
    /// credibility on noise. `result.verdict` keeps run 1's underlying verdict for forensics.
    public var verdict: TraceDiff.Verdict {
        stability.isStable ? result.verdict : .unstable
    }

    public var diff: TraceDiff {
        result.diff
    }

    /// The declared interrogation surface (`op:` boundaries + seams) and how much of it was exercised.
    public var coverage: Coverage {
        result.coverage
    }
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
    /// is the oracle, so no expected output is needed. Stops at (and shrinks) the first divergence.
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

        for (index, order) in plan.orderings.enumerated() {
            for cassette in plan.cassettes(forOrdering: index) {
                let run = await compare(
                    make: makeSystem,
                    candidate: candidate,
                    order: order,
                    cassette: cassette,
                    declaring: intent
                )
                guard run.diff.isEquivalent else {
                    let shrunk = await shrink(
                        candidate: candidate,
                        failing: order,
                        cassette: cassette,
                        declaring: intent
                    )
                    let coverage = plannedCoverage(replay: run.candidateReplay, domainHeld: false, plan: plan)
                    let failing = exploreOrdering ? shrunk.map(\.label) : nil
                    return SpecVerdict(
                        result: VerificationResult(diff: run.diff, coverage: coverage),
                        orderingsExplored: plan.orderings.count,
                        failingOrder: failing,
                        counterexample: plan.domains.isEmpty ? nil : cassette,
                        exploration: plan.exploration,
                        qualification: qualification,
                        violatedPreconditions: failing.map(preconditionViolations(in:))
                    )
                }
            }
        }
        // Held across the whole explored surface: the swept seams earn domain-coverage credit.
        let representative = await compare(
            make: makeSystem,
            candidate: candidate,
            order: operations,
            cassette: golden,
            declaring: intent
        )
        let coverage = plannedCoverage(replay: representative.candidateReplay, domainHeld: true, plan: plan)
        return SpecVerdict(
            result: VerificationResult(diff: representative.diff, coverage: coverage),
            orderingsExplored: plan.orderings.count,
            failingOrder: nil,
            counterexample: nil,
            exploration: plan.exploration,
            qualification: qualification
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
        let recording = Cassette()
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
        let system = make(context)
        // The system states what its instrumentation can see of property writes (`@Traced` = full,
        // `@TracedForwarder` = boundary), and the trace carries it — the diff needs both sides'
        // answers before it may compare write timelines.
        recorder.declareMutationCapture((system as? MutationCapturing)?.mutationCapture ?? .none)
        // Task-locals are inherited across `await`, so binding once around the whole loop still
        // reaches an operation that suspends — which is what lets an op drive an actor.
        await TraceContext.$current.withValue(recorder) {
            for operation in order {
                await operation.action(system, context)
            }
        }
        // Drain *after* the window, not inside it. Work the ops dispatched carries the recorder the
        // seam captured at enqueue, so it records whether or not the window is still open — but it has
        // to have finished, or the snapshot is a race rather than a reading.
        if await DispatchSeam.quiesce() == false {
            recorder.marker("⟨haruspec: work still outstanding at snapshot⟩")
        }
        // The end-state snapshots: after quiescence (a racing read is not a reading), the harness
        // itself reads each observed property back. Harness-read on both sides by construction, so
        // they compare under every `MutationCapture` capability — the state contract that stays
        // gating even while write *order* is advisory.
        for property in observedProperties {
            await recorder.snapshot(property.label, value: RuntimeValue.canonical(property.read(system)))
        }
        return recorder.trace()
    }

    /// One differential run, keeping the candidate's replay cassette so the verdict can carry the
    /// coverage it was measured over. The diff is already intent-classified: with a declared intent the
    /// loop must not stop on an intended-only divergence set, so classification lives here, not at exits.
    private func compare(
        make: (SeamContext) -> S,
        candidate: (SeamContext) -> S,
        order: [Op<S>],
        cassette: CassetteData,
        declaring intent: Intent
    ) async -> (diff: TraceDiff, candidateReplay: Cassette) {
        let baseline = await capture(make: make, order: order, cassette: Cassette(replaying: cassette))
        let replay = Cassette(replaying: cassette)
        let candidateTrace = await capture(make: candidate, order: order, cassette: replay)
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidateTrace,
            tolerances: effectiveTolerances
        )
        .classified(against: intent)
        return (diff, replay)
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
