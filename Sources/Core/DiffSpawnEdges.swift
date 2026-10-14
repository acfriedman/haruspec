import Foundation

/// The happens-before pass: compare the **constraints** the recorded spawn edges imply, never the
/// raw edges. An edge disappearing is not by itself a lost ordering — an actor port replaces
/// `dispatch_async` with `await`, and the constraint survives *more* strongly, as program order
/// inside one ordered domain. So the recorded facts admit two steps of proof that X happens-before Y:
///
///  1. a **spawn edge** — Y's work was enqueued by X, or
///  2. **program order in an ordered domain** — X and Y share a domain whose order is a runtime
///     guarantee, X first,
///
/// and happens-before is transitive, so any chain of those steps from X to Y proves it too: a
/// completion two hops from the call that queued its work is still after that call.
///
/// A baseline constraint the candidate can prove neither way is **`orderingLost`** — a dropped
/// synchronization, said from a passing run, which is the claim dynamic race detection cannot make.
/// A candidate constraint the baseline had neither way is **`orderingAdded`** — new synchronization,
/// the awaited port of fire-and-forget work. Both are real behavioral changes, so both follow the
/// `spawnEdges` policy: **red until declared** by default, through `Intent.expectedOrderingLosses`
/// and `expectedOrderingAdditions`.
///
/// Honest limit, stated rather than hidden: the recorded edge set under-approximates true
/// happens-before (no lock or shared-memory edges), so a constraint the program keeps only through
/// one of those reports as lost. A spec hitting that over-report drops the policy to `.advisory`.
extension BehavioralDiff {
    static func compareSpawnEdges(
        baseline: [TraceEvent],
        candidate: [TraceEvent],
        comparison: Comparison,
        into scratch: inout DiffScratch
    ) {
        guard comparison.spawnEdges != .ignored else {
            return
        }
        let baselineBySeq = Dictionary(uniqueKeysWithValues: baseline.map { ($0.seq, $0) })
        let candidateBySeq = Dictionary(uniqueKeysWithValues: candidate.map { ($0.seq, $0) })
        var baselineOrder = HappensBefore(baseline)
        var candidateOrder = HappensBefore(candidate)
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
               !candidateOrder.precedes(spawnerCounterpart, candidateEvent) {
                scratch.divergences.append(
                    Divergence(
                        kind: .orderingLost,
                        label: baselineEvent.label,
                        baselineSeq: baselineEvent.seq,
                        candidateSeq: candidateEvent.seq,
                        detail: "synchronization dropped: \(spawner.label) → \(baselineEvent.label) "
                            + "held in baseline (spawn edge from #\(spawner.seq)); "
                            + "the candidate leaves them concurrent",
                        isAdvisory: comparison.spawnEdges == .advisory
                    )
                )
            }
            if let causeSeq = candidateEvent.spawnedBy,
               let spawner = candidateBySeq[causeSeq],
               let spawnerCounterpart = counterpartOfCandidate[causeSeq],
               !baselineOrder.precedes(spawnerCounterpart, baselineEvent) {
                scratch.divergences.append(
                    Divergence(
                        kind: .orderingAdded,
                        label: candidateEvent.label,
                        baselineSeq: baselineEvent.seq,
                        candidateSeq: candidateEvent.seq,
                        detail: "synchronization added: \(spawner.label) → \(candidateEvent.label) "
                            + "constrained in candidate, concurrent in baseline",
                        isAdvisory: comparison.spawnEdges == .advisory
                    )
                )
            }
        }
    }
}

/// What one trace's recorded facts prove happens-before: the transitive closure of its spawn edges and
/// of program order within each ordered domain.
struct HappensBefore {
    /// For each event, the events one step after it: those it spawned, and the next in its domain when
    /// that domain is ordered. Every step runs forward in sequence order.
    private let steps: [Int: [Int]]
    /// Each source asked about, and everything it reaches.
    private var reached: [Int: Set<Int>] = [:]

    /// Builds the steps from `events`, in recorded order.
    ///
    /// - Parameter events: One trace's events.
    init(_ events: [TraceEvent]) {
        var steps: [Int: [Int]] = [:]
        var lastInDomain: [ConcurrencyDomain: Int] = [:]
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if let cause = event.spawnedBy {
                steps[cause, default: []].append(event.seq)
            }
            guard event.domain.isOrdered else { continue }
            if let previous = lastInDomain[event.domain] {
                steps[previous, default: []].append(event.seq)
            }
            lastInDomain[event.domain] = event.seq
        }
        self.steps = steps
    }

    /// Returns whether the recorded facts prove `earlier` happens-before `later`.
    ///
    /// - Parameters:
    ///   - earlier: The event that would come first.
    ///   - later: The event that would come after it.
    /// - Returns: `true` when a chain of spawn edges and ordered program order leads from `earlier` to
    ///   `later`.
    mutating func precedes(_ earlier: TraceEvent, _ later: TraceEvent) -> Bool {
        guard earlier.seq < later.seq else { return false }
        if let known = reached[earlier.seq] {
            return known.contains(later.seq)
        }
        var seen: Set<Int> = []
        var frontier = [earlier.seq]
        while let next = frontier.popLast() {
            for step in steps[next] ?? [] where seen.insert(step).inserted {
                frontier.append(step)
            }
        }
        reached[earlier.seq] = seen
        return seen.contains(later.seq)
    }
}
