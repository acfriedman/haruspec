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

/// The golden template, the baseline that recorded it, and everything resolved off it.
private struct GoldenSurface<S> {
    let baseline: (SeamContext) -> S
    let golden: CassetteData
    let plan: ExplorationPlan<S>
    let qualification: Qualification
}

public extension BaselinedSpec {
    /// Differentially verifies a candidate against the bound baseline over the *same* generated inputs
    /// (call orderings × seam values). The baseline is the oracle, so no expected output is needed.
    ///
    /// - Parameters:
    ///   - candidate: Builds a fresh candidate per capture from the capture's context.
    ///   - intent: The deltas this candidate is meant to produce; `.none` asks for parity.
    /// - Returns: The verdict over the whole explored surface.
    ///
    /// A divergence does not stop the sweep: every probe runs, and the richest failing case is shrunk
    /// and reported.
    func verify(
        candidate: @escaping (SeamContext) -> S,
        declaring intent: Intent = .none
    ) async -> SpecVerdict {
        await spec.collectingOrigins(declaring: intent) {
            await spec.differentialVerdict(baseline: baseline, candidate: candidate, declaring: intent)
        }
    }
}

extension Spec {
    /// Sweeps the explored surface comparing `candidate` to `baseline`.
    ///
    /// - Parameters:
    ///   - baseline: Builds a fresh baseline per capture.
    ///   - candidate: Builds a fresh candidate per capture.
    ///   - intent: The deltas the candidate is meant to produce; `.none` asks for parity.
    /// - Returns: The verdict over the whole explored surface.
    func differentialVerdict(
        baseline: @escaping (SeamContext) -> S,
        candidate: @escaping (SeamContext) -> S,
        declaring intent: Intent
    ) async -> SpecVerdict {
        let surface = await goldenSurface(baseline: baseline)
        let (golden, plan, qualification) = (surface.golden, surface.plan, surface.qualification)

        // Sweep-wide intent facts (disclosure + unobserved intersection) — see `IntentSweep`.
        var sweep = IntentSweep(intent: intent)
        var reds = RedCases<DivergedRun>()
        for (order, cassette) in plan.runs() {
            let run = await compare(
                make: baseline,
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
            make: baseline,
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

    /// Returns the red exit of the live sweep, unstable when the baseline disagrees with itself
    /// over the failing input.
    ///
    /// - Parameters:
    ///   - run: The failing comparison the sweep reports.
    ///   - failingCases: Every failing case the sweep found.
    ///   - candidate: Builds a fresh candidate per capture.
    ///   - surface: The golden surface the sweep explored, with the baseline that recorded it.
    ///   - intent: The deltas the candidate is meant to produce.
    /// - Returns: The diverged verdict, or an unstable one carrying what the baseline could not
    ///   reproduce.
    ///
    /// A stable red has the reported case's order shrunk, what exposed it pinned, and every failing
    /// case carried; an unstable one reports its order unshrunk. Makes no unobserved-intent claim:
    /// the reported diff is one case's, and a declaration it did not match may have held in another.
    private func divergedLiveVerdict(
        run: DivergedRun,
        failingCases: FailingCases,
        candidate: @escaping (SeamContext) -> S,
        surface: GoldenSurface<S>,
        declaring intent: Intent
    ) async -> SpecVerdict {
        var diff = run.diff
        diff.unobservedIntent = []
        let stability = await selfCheck(baseline: surface.baseline, order: run.order, cassette: run.cassette)
        var shrunk = run.order
        if stability.isStable {
            shrunk = await shrink(
                baseline: surface.baseline,
                candidate: candidate,
                failing: run.order,
                cassette: run.cassette,
                declaring: intent
            )
        }
        let coverage = plannedCoverage(replay: run.candidateReplay, domainHeld: false, plan: surface.plan)
        // A settle schedule is part of what failed, so a red names its order whenever either the
        // ordering or the schedule was explored.
        let explored = exploreOrdering || surface.plan.settleSchedulesPerOrdering > 1
        let failing = explored ? shrunk.map(\.label) : nil
        return SpecVerdict(
            result: VerificationResult(diff: diff, coverage: coverage),
            orderingsExplored: surface.plan.orderings.count,
            failingOrder: failing,
            counterexample: surface.plan.domains.isEmpty ? nil : run.cassette,
            exploration: surface.plan.exploration,
            qualification: surface.qualification,
            violatedPreconditions: failing.map(preconditionViolations(in:)),
            stability: stability,
            failingCases: failingCases
        )
    }

    /// A failing comparison of the live sweep, with everything the diverged exit needs to pin it.
    private struct DivergedRun {
        let diff: TraceDiff
        let candidateReplay: Cassette
        let order: [Op<S>]
        let cassette: CassetteData
    }

    // MARK: - Hidden machinery

    /// One replay's coverage against the plan's varied surface — the plan's domains, not the
    /// declaration's, so packaged resource sweeps earn the same credit an authored `Seam` does.
    private func plannedCoverage(replay: Cassette, domainHeld: Bool, plan: ExplorationPlan<S>) -> Coverage {
        coverage(replays: [replay], domainHeld: domainHeld, sweptSeams: Array(plan.domains.keys))
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

    /// Records the golden template — the declared order under live seams, the template every variation
    /// is derived from — and resolves the explored surface plus the qualification measured off it.
    ///
    /// - Parameter baseline: Builds a fresh baseline per capture.
    /// - Returns: The baseline, its golden cassette, the exploration plan, and the qualification.
    private func goldenSurface(baseline: @escaping (SeamContext) -> S) async -> GoldenSurface<S> {
        let recording = Cassette(recordingPreferring: goldenReadings)
        let goldenCapture = await captured(make: baseline, order: explorationOrder(), cassette: recording)
        let goldenTrace = goldenCapture.trace
        let golden = recording.snapshot()
        let plan = explorationPlan(golden: golden, heldWorkAtGaps: goldenCapture.heldWorkAtGaps)
        let qualification = liveQualification(
            goldenTrace: goldenTrace,
            golden: golden,
            exploration: plan.exploration
        )
        return GoldenSurface(baseline: baseline, golden: golden, plan: plan, qualification: qualification)
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

    /// Delta-debugs the failing call sequence: drops ops that aren't needed to reproduce → the minimal
    /// order that still diverges (the "localize" the north star asks for, applied to sequencing).
    ///
    /// - Parameters:
    ///   - baseline: Builds a fresh baseline per capture.
    ///   - candidate: Builds a fresh candidate per capture.
    ///   - failing: An op sequence that diverges under `cassette`.
    ///   - cassette: The seam readings the failure was found under.
    ///   - intent: The deltas the candidate is meant to produce.
    /// - Returns: The shortest subsequence of `failing` found that still diverges.
    ///
    /// Settle steps shrink the same way: dropping one turns its gap back to held, so the red keeps
    /// only the settle points it needs. A dropped op can strand a step at either end or leave two
    /// side by side, which `normalizedSettles` folds back into one per gap.
    private func shrink(
        baseline: @escaping (SeamContext) -> S,
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
            trial = normalizedSettles(trial)
            if trial.contains(where: { $0.settle == nil }), await diverges(
                baseline: baseline,
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

    private func diverges(
        baseline: (SeamContext) -> S,
        candidate: (SeamContext) -> S,
        order: [Op<S>],
        cassette: CassetteData,
        declaring intent: Intent
    ) async -> TraceDiff? {
        let diff = await compare(
            make: baseline,
            candidate: candidate,
            order: order,
            cassette: cassette,
            declaring: intent
        ).diff
        return diff.isEquivalent ? nil : diff
    }

    /// One differential run. The diff is already intent-classified: with a declared intent the loop
    /// must not stop on an intended-only divergence set, so classification lives here, not at exits.
    func compare(
        make: (SeamContext) -> S,
        candidate: (SeamContext) -> S,
        order: [Op<S>],
        cassette: CassetteData,
        declaring intent: Intent
    ) async -> ProbeComparison {
        let baselineReplay = Cassette(replaying: cassette)
        let baseline = await capture(make: make, order: order, cassette: baselineReplay)
        // The candidate is answered as the baseline was, call by call, whatever order it asks in.
        let replay = Cassette(replaying: baselineReplay.snapshot())
        let candidateTrace = await capture(make: candidate, order: order, cassette: replay)
        let evidence = ProbeEvidence(
            inputs: cassette.tracks,
            baseline: baseline,
            candidate: candidateTrace,
            comparison: comparison
        )
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidateTrace,
            comparison: comparison
        )
        .classified(against: intent, evidence: evidence)
        return ProbeComparison(diff: diff, candidateReplay: replay, evidence: evidence)
    }
}
