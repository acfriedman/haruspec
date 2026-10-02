import Foundation
import HaruspecCore
import HaruspecSeams

// The two pieces of sweep-wide bookkeeping a verify loop keeps as it walks probes: which declared
// changes it has seen hold (`IntentSweep`), and every failing case (`RedCases`). A sweep compares
// many probes but reports one verdict, and both of these are facts about the sweep, not about any
// one probe.

/// Every failing case a sweep walks, and which one the verdict reports (the richest).
/// A red does not stop the sweep, because a bug that fails nearly every probe would end it before a
/// quieter bug is reached.
///
/// `Run` is whatever the sweep needs to build its verdict from the reported case.
struct RedCases<Run> {
    private var runs: [Run] = []
    private var probes: [DivergentProbe] = []
    private var walkedAfterFirst = 0

    /// Notes one walked probe, keeping it when it failed.
    ///
    /// - Parameters:
    ///   - run: What the verdict is built from, should this case be the reported one.
    ///   - ordering: The op labels the probe ran, in order.
    ///   - inputs: The seam values the probe ran with.
    ///   - diff: The probe's classified diff.
    mutating func observe(_ run: Run, ordering: [String], inputs: CassetteData, diff: TraceDiff) {
        if !probes.isEmpty {
            walkedAfterFirst += 1
        }
        guard !diff.isEquivalent else {
            return
        }
        runs.append(run)
        probes.append(DivergentProbe(ordering: ordering, inputs: inputs, divergences: diff.divergences))
    }

    var cases: FailingCases {
        FailingCases(probes: probes, walkedAfterFirst: walkedAfterFirst)
    }

    /// The run behind the case the verdict reports — the richest — or `nil` when nothing failed.
    var reported: Run? {
        cases.richestIndex.map { runs[$0] }
    }
}

/// One replayed probe, with what the red exit pins from it.
struct ReplayedRun {
    let probe: SpecProbe
    let replay: Cassette
    let diff: TraceDiff
}

extension RedCases where Run == ReplayedRun {
    /// Notes one replayed probe, keeping it when it failed.
    ///
    /// - Parameter run: The replayed probe and its classified diff.
    mutating func observe(_ run: ReplayedRun) {
        observe(run, ordering: run.probe.ordering, inputs: run.probe.cassette, diff: run.diff)
    }
}

extension Spec {
    /// Sweep-wide intent bookkeeping shared by the replay and live verify loops: a sweep compares
    /// many probes but reports one diff, and intent facts are sweep-wide, not per-probe.
    ///
    /// Two corrections it applies to the reported diff:
    ///  - **disclosure** — a green-by-declaration verdict must show what it absorbed, and the
    ///    reported probe may be clean while a later probe carried the change; the first absorbing
    ///    diff is preferred.
    ///  - **unobserved intersection** — a declaration is observed if ANY probe matched it, so the
    ///    sweep-wide unobserved set is the intersection of the per-probe ones.
    struct IntentSweep {
        private let intent: Intent
        private var intendedRepresentative: TraceDiff?
        private var unobservedAcross: Set<String>?
        /// Where each declaration was first seen to hold, in first-seen order.
        private(set) var observations: [IntentObservation] = []

        init(intent: Intent) {
            self.intent = intent
        }

        /// The run's evidence is what the declarations re-match against, so the observation names the
        /// declaration that actually absorbed each divergence.
        mutating func observe(_ run: ProbeComparison, ordering: [String], inputs: CassetteData) {
            let diff = run.diff
            unobservedAcross = unobservedAcross
                .map { $0.intersection(diff.unobservedIntent) } ?? Set(diff.unobservedIntent)
            if intendedRepresentative == nil, diff.intendedCount > 0 {
                intendedRepresentative = diff
            }
            var evidence = run.evidence
            evidence.divergences = diff.divergences
            for divergence in diff.divergences where divergence.classification == .intended {
                for declaration in intent.declarationsMatching(divergence, evidence: evidence)
                    where !observations.contains(where: { $0.declaration == declaration }) {
                    observations.append(IntentObservation(
                        declaration: declaration,
                        divergence: divergence,
                        ordering: ordering,
                        inputs: inputs
                    ))
                }
            }
        }

        /// The diff the verdict should carry: the first absorbing diff when one exists (else
        /// `fallback`), its unobserved list corrected to the sweep-wide intersection.
        func settle(_ fallback: TraceDiff) -> TraceDiff {
            var diff = intendedRepresentative ?? fallback
            if let unobservedAcross {
                diff.unobservedIntent = diff.unobservedIntent.filter(unobservedAcross.contains)
            }
            return diff
        }
    }
}
