import Foundation
import HaruspecCore
import HaruspecSeams

// A recorded plan, read through the build that is replaying it. The plan pins what *was* explored;
// what that means today — which probes can still replay, what the ordering denominator is, what the
// verdict may claim it covered — is a fact about the current declarations, so it is re-derived here
// rather than trusted from the artifact. Same rule the qualification block follows.

extension Spec {
    /// The plan read through the current build: which recorded probes can replay at all, and the
    /// exploration/qualification the verdict will carry either way — resolved once per pass, shared
    /// by both exits so a divergence and a hold describe the same surface.
    func replaySurface(of plan: SpecPlan) -> ReplaySurface<S> {
        let opsByLabel = Dictionary(uniqueKeysWithValues: operations.map { ($0.label, $0) })
        let planOps = orderedUnion(plan.probes.map(\.ordering))
        let replayable = plan.probes.filter { $0.ordering.allSatisfy { opsByLabel[$0] != nil } }
        return ReplaySurface(
            opsByLabel: opsByLabel,
            planOps: planOps,
            missingOps: planOps.filter { opsByLabel[$0] == nil },
            replayable: replayable,
            distinctOrderings: Set(plan.probes.map(\.ordering)).count,
            variedInputs: plan.probes.contains { $0.cassette != plan.probes.first?.cassette },
            exploration: exploration(recordedIn: plan),
            qualification: replayQualification(of: plan, operations: planOps.count, probes: replayable.count)
        )
    }

    /// What the recorded plan covered, read through the surface the *current* build declares: the plan
    /// pins the orderings that were explored, but the denominator — and whether an ordering counts as
    /// out-of-order — comes from this build's constraints, so a replay reports the same fraction a live
    /// verify would, and a spec that softened an `.after` since recording says so.
    private func exploration(recordedIn plan: SpecPlan) -> Exploration {
        let orderings = Set(plan.probes.map(\.ordering))
        let available = exploreOrdering
            ? countLinearExtensions(operations, repeating: orderingRepeats, limit: SpecDefaults.orderingCountLimit)
            : (count: 1, exact: true)
        let variants = Swift.max(1, plan.probes.count / Swift.max(1, orderings.count))
        // The boundary schedule is deterministic from (declared domains × the golden template), and
        // the plan's first probe *is* the golden — so the count is recomputed here rather than stored,
        // the same way the ordering denominator is: read through the current build's declarations.
        let goldenTracks = plan.probes.first?.cassette.tracks ?? [:]
        // The same merge the record's plan applied: packaged sweeps the golden reached are part of
        // the recomputed schedule, or a replayed plan would report fewer edges than it recorded.
        let domains = seamDomains.merging(resourceSweeps(reaching: goldenTracks.keys)) { declared, _ in declared }
        let generator = Set(domains.keys).isDisjoint(with: goldenTracks.keys)
            ? nil
            : DomainSeamGenerator(domains: domains, seed: plan.seed, golden: goldenTracks)
        return Exploration(
            orderingsExplored: orderings.count,
            orderingsAvailable: Swift.max(available.count, orderings.count),
            orderingsAreExact: available.exact,
            variantsPerOrdering: variants,
            outOfOrderExplored: outOfOrderCount(among: Array(orderings)),
            boundaryEdgesScheduled: generator?.scheduledBoundaryEdges ?? 0,
            // `variants` is derived from probe counts (deduped at record), so these can undercount by
            // one near the boundary — never overcount, which is the honest direction for a coverage claim.
            boundaryEdgesCovered: generator?.boundaryEdgesCovered(within: variants) ?? 0,
            combinedVariantsCovered: generator?.combinedVariantsCovered(within: variants) ?? 0
        )
    }

    /// When *no* probe was replayable there is nothing to diff; an empty comparison stands in so the
    /// coverage gaps (every op unrecorded) can carry the CANNOT-VERIFY.
    func emptyDiff(golden: String) -> TraceDiff {
        BehavioralDiff.compare(
            baseline: Trace(name: "\(golden).golden", events: []),
            candidate: Trace(name: name, events: []),
            tolerances: tolerances
        )
    }
}

/// One replay pass's resolved view of a plan (see `replaySurface(of:)`).
struct ReplaySurface<S> {
    let opsByLabel: [String: Op<S>]
    let planOps: [String]
    let missingOps: [String]
    let replayable: [SpecProbe]
    let distinctOrderings: Int
    let variedInputs: Bool
    let exploration: Exploration
    let qualification: Qualification
}

/// The union of several label sequences, keeping first-seen order (deterministic gap reporting).
func orderedUnion(_ sequences: [[String]]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for sequence in sequences {
        for label in sequence where seen.insert(label).inserted {
            result.append(label)
        }
    }
    return result
}
