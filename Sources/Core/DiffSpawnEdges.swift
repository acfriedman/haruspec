import Foundation

/// The happens-before pass: compare the **constraints** the recorded spawn edges imply, never the
/// raw edges. An edge disappearing is not by itself a lost ordering — an actor port replaces
/// `dispatch_async` with `await`, and the constraint survives *more* strongly, as program order
/// inside one ordered domain. So the recorded facts admit exactly two proofs that X happens-before Y:
///
///  1. a **spawn edge** — Y's work was enqueued by X, or
///  2. **program order in an ordered domain** — X and Y share a domain whose order is a runtime
///     guarantee, X first.
///
/// A baseline constraint the candidate can prove neither way is **`orderingLost`** — a dropped
/// synchronization, said from a passing run, which is the claim dynamic race detection cannot make.
/// A candidate constraint the baseline had neither way is **`orderingAdded`** — new synchronization,
/// the awaited port of fire-and-forget work. Both are real behavioral changes, so both follow the
/// `spawnEdges` policy: **red until declared** by default, through `Intent.expectedOrderingLosses`
/// and `expectedOrderingAdditions`.
///
/// Honest limits, stated rather than hidden: the recorded edge set under-approximates true
/// happens-before (no lock or shared-memory edges), and this pass does not chase transitive chains —
/// a constraint preserved only through an intermediate hop reports as lost. A spec hitting that
/// over-report drops the policy to `.advisory`; the rate on real subjects is an open measurement.
extension BehavioralDiff {
    static func compareSpawnEdges(
        baseline: [TraceEvent],
        candidate: [TraceEvent],
        spec: Tolerance,
        into scratch: inout DiffScratch
    ) {
        guard spec.spawnEdges != .ignored else {
            return
        }
        let baselineBySeq = Dictionary(uniqueKeysWithValues: baseline.map { ($0.seq, $0) })
        let candidateBySeq = Dictionary(uniqueKeysWithValues: candidate.map { ($0.seq, $0) })
        var counterpartOfBaseline: [Int: TraceEvent] = [:]
        var counterpartOfCandidate: [Int: TraceEvent] = [:]
        for (baselineEvent, candidateEvent) in scratch.alignedPairs {
            counterpartOfBaseline[baselineEvent.seq] = candidateEvent
            counterpartOfCandidate[candidateEvent.seq] = baselineEvent
        }

        for (baselineEvent, candidateEvent) in scratch.alignedPairs {
            // A constraint whose spawner did not survive alignment makes no claim here — the
            // spawner's absence is already reported as missing/unexpected, which subsumes it.
            if let causeSeq = baselineEvent.spawnedBy,
               let spawner = baselineBySeq[causeSeq],
               let spawnerCounterpart = counterpartOfBaseline[causeSeq],
               !constrained(spawnerCounterpart, before: candidateEvent) {
                scratch.divergences.append(
                    Divergence(
                        kind: .orderingLost,
                        label: baselineEvent.label,
                        baselineSeq: baselineEvent.seq,
                        candidateSeq: candidateEvent.seq,
                        detail: "synchronization dropped: \(spawner.label) → \(baselineEvent.label) "
                            + "held in baseline (spawn edge from #\(spawner.seq)); "
                            + "the candidate leaves them concurrent",
                        isAdvisory: spec.spawnEdges == .advisory
                    )
                )
            }
            if let causeSeq = candidateEvent.spawnedBy,
               let spawner = candidateBySeq[causeSeq],
               let spawnerCounterpart = counterpartOfCandidate[causeSeq],
               !constrained(spawnerCounterpart, before: baselineEvent) {
                scratch.divergences.append(
                    Divergence(
                        kind: .orderingAdded,
                        label: candidateEvent.label,
                        baselineSeq: baselineEvent.seq,
                        candidateSeq: candidateEvent.seq,
                        detail: "synchronization added: \(spawner.label) → \(candidateEvent.label) "
                            + "constrained in candidate, concurrent in baseline",
                        isAdvisory: spec.spawnEdges == .advisory
                    )
                )
            }
        }
    }

    /// `earlier` happens-before `later`, as far as the recorded facts can prove: a spawn edge, or
    /// program order within one ordered domain.
    private static func constrained(_ earlier: TraceEvent, before later: TraceEvent) -> Bool {
        later.spawnedBy == earlier.seq
            || (earlier.domain == later.domain && earlier.domain.isOrdered && earlier.seq < later.seq)
    }
}
