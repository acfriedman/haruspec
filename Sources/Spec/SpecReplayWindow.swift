import Foundation
import HaruspecCore
import HaruspecSeams

// The two pieces of sweep-wide bookkeeping a verify loop keeps as it walks probes: which declared
// changes it has seen hold (`IntentSweep`), and — once a probe fails — every further failing case
// within a bounded window (`RedWindow`). A sweep compares many probes but reports one verdict, and
// both of these are facts about the sweep, not about any one probe.

/// The failing cases a replay collects once it has seen its first red. The first case the
/// schedule reaches is the golden template, and on a derived spec that is often a run that undoes
/// itself (add, then remove the same item), whose `null → 0` divergences teach nothing — so the
/// sweep keeps walking `SpecDefaults.redProbeWindow` more probes, keeps every failing one, and
/// reports the richest.
struct RedWindow {
    struct Entry {
        let probe: SpecProbe
        let replay: Cassette
        let diff: TraceDiff
    }

    private var entries: [Entry] = []
    private var walkedAfterFirst = 0

    /// Whether the sweep may replay one more probe: always, until the first red; then until the
    /// window is spent. Counts the probe it admits.
    mutating func admits() -> Bool {
        guard !entries.isEmpty else {
            return true
        }
        guard walkedAfterFirst < SpecDefaults.redProbeWindow else {
            return false
        }
        walkedAfterFirst += 1
        return true
    }

    mutating func note(probe: SpecProbe, replay: Cassette, diff: TraceDiff) {
        entries.append(Entry(probe: probe, replay: replay, diff: diff))
    }

    var cases: FailingCases {
        FailingCases(
            probes: entries.map {
                DivergentProbe(
                    ordering: $0.probe.ordering,
                    inputs: $0.probe.cassette,
                    divergences: $0.diff.divergences
                )
            },
            walkedAfterFirst: walkedAfterFirst
        )
    }

    /// The case the verdict reports — the richest — or `nil` when nothing failed.
    var reported: Entry? {
        guard let richest = cases.richest else {
            return nil
        }
        return entries.first { $0.probe.ordering == richest.ordering && $0.probe.cassette == richest.inputs }
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

        mutating func observe(_ diff: TraceDiff, ordering: [String], inputs: CassetteData) {
            unobservedAcross = unobservedAcross
                .map { $0.intersection(diff.unobservedIntent) } ?? Set(diff.unobservedIntent)
            if intendedRepresentative == nil, diff.intendedCount > 0 {
                intendedRepresentative = diff
            }
            for divergence in diff.divergences where divergence.classification == .intended {
                for declaration in intent.declarationsMatching(divergence, inputs: inputs.tracks)
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
