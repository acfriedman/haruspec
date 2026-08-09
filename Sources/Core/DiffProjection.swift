import Foundation

/// The `.perDomain` comparison: project each trace onto its concurrency domains and compare the
/// projections, never the one recorded interleaving.
///
/// The rules, per bucket:
///  - the **same ordered domain** on both sides keeps the sequence comparison — a serial context's
///    order is a runtime guarantee, so missing / reordered / value / timing all still mean something;
///  - the **same unordered domain** on both sides is compared as a **multiset** — a concurrent
///    bucket's internal order is whichever branch finished first, so only content and counts carry
///    signal;
///  - events left unmatched by their own bucket reconcile **across** domains by
///    signature-minus-domain (the existing `domainMigration`), with relative order never compared —
///    which is also where "ordered baseline bucket, unordered candidate bucket" lands, compared as a
///    multiset because either side being unordered means a sequence assertion would be invented, not
///    checked;
///  - a migration out of an ordered domain into an unordered one additionally reports the dropped
///    guarantee itself, once per domain pair, as **`orderingRelaxed`** — gating until the change
///    declares it (`Intent.expectedOrderingRelaxations`).
extension BehavioralDiff {
    /// Events no bucket could pair — the raw material of cross-domain reconciliation.
    private struct Leftovers {
        var baseline: [TraceEvent] = []
        var candidate: [TraceEvent] = []
    }

    /// One ordered→unordered migration, aggregated per domain pair: the guarantee was dropped once,
    /// however many events it carried.
    private struct Relaxation {
        let origin: ConcurrencyDomain
        let destination: ConcurrencyDomain
        var count: Int
        var firstBaselineSeq: Int
        var firstCandidateSeq: Int
    }

    static func comparePerDomain(
        baseline: [TraceEvent],
        candidate: [TraceEvent],
        spec: Tolerance,
        into divergences: inout [Divergence]
    ) {
        var domains: [ConcurrencyDomain] = []
        var seen = Set<ConcurrencyDomain>()
        var baselineBuckets: [ConcurrencyDomain: [TraceEvent]] = [:]
        var candidateBuckets: [ConcurrencyDomain: [TraceEvent]] = [:]
        for event in baseline {
            if seen.insert(event.domain).inserted {
                domains.append(event.domain)
            }
            baselineBuckets[event.domain, default: []].append(event)
        }
        for event in candidate {
            if seen.insert(event.domain).inserted {
                domains.append(event.domain)
            }
            candidateBuckets[event.domain, default: []].append(event)
        }

        var leftovers = Leftovers()
        for domain in domains {
            let bucketBaseline = baselineBuckets[domain] ?? []
            let bucketCandidate = candidateBuckets[domain] ?? []
            if domain.isOrdered {
                compareOrderedBucket(
                    bucketBaseline,
                    bucketCandidate,
                    spec: spec,
                    into: &divergences,
                    leftovers: &leftovers
                )
            } else {
                compareUnorderedBucket(
                    bucketBaseline,
                    bucketCandidate,
                    spec: spec,
                    into: &divergences,
                    leftovers: &leftovers
                )
            }
        }

        reconcileAcrossDomains(leftovers, spec: spec, into: &divergences)
    }

    /// The structural-tier advisory rule, derived from the spec — the projection's spelling of the
    /// closure `compare` builds for the total-order path.
    private static func isAdvisory(_ tier: EventTier, under spec: Tolerance) -> Bool {
        spec.structuralComparison == .advisory && tier == .structural
    }

    // MARK: - Within one domain

    /// The sequence comparison, scoped to one ordered domain: LCS-align, compare aligned pairs, and
    /// classify equal-signature leftovers as `reordered` — within this bucket order IS the contract.
    private static func compareOrderedBucket(
        _ baseline: [TraceEvent],
        _ candidate: [TraceEvent],
        spec: Tolerance,
        into divergences: inout [Divergence],
        leftovers: inout Leftovers
    ) {
        let baselineSig = baseline.map(signature)
        let candidateSig = candidate.map(signature)
        let matched = longestCommonSubsequence(baselineSig, candidateSig)
        let matchedBaseline = Set(matched.map(\.0))
        let matchedCandidate = Set(matched.map(\.1))

        for (baselineIndex, candidateIndex) in matched {
            compareAligned(
                baseline[baselineIndex],
                candidate[candidateIndex],
                spec: spec,
                isAdvisory: isAdvisory(baseline[baselineIndex].tier, under: spec),
                into: &divergences
            )
        }

        var unmatchedInsertions = candidate.indices.filter { !matchedCandidate.contains($0) }
        for baselineIndex in baseline.indices where !matchedBaseline.contains(baselineIndex) {
            if let slot = unmatchedInsertions.firstIndex(where: { candidateSig[$0] == baselineSig[baselineIndex] }) {
                let candidateIndex = unmatchedInsertions.remove(at: slot)
                if !spec.isUnordered(label: baseline[baselineIndex].label) {
                    divergences.append(
                        Divergence(
                            kind: .reordered,
                            label: baseline[baselineIndex].label,
                            baselineSeq: baseline[baselineIndex].seq,
                            candidateSeq: candidate[candidateIndex].seq,
                            detail: "event order changed within \(baseline[baselineIndex].domain) "
                                + "(baseline #\(baseline[baselineIndex].seq) "
                                + "→ candidate #\(candidate[candidateIndex].seq))",
                            isAdvisory: isAdvisory(baseline[baselineIndex].tier, under: spec)
                        )
                    )
                }
                compareAligned(
                    baseline[baselineIndex],
                    candidate[candidateIndex],
                    spec: spec,
                    isAdvisory: isAdvisory(baseline[baselineIndex].tier, under: spec),
                    into: &divergences
                )
            } else {
                leftovers.baseline.append(baseline[baselineIndex])
            }
        }
        for candidateIndex in unmatchedInsertions {
            leftovers.candidate.append(candidate[candidateIndex])
        }
    }

    /// The multiset comparison, scoped to one unordered domain: match by content, ignore order
    /// entirely, keep counts exact. Content-identical pairs match first; whatever is left pairs in
    /// recorded order so a genuine value change reads as `valueMismatch` rather than dissolving into
    /// a missing/unexpected pair; a count imbalance spills over for cross-domain reconciliation.
    private static func compareUnorderedBucket(
        _ baseline: [TraceEvent],
        _ candidate: [TraceEvent],
        spec: Tolerance,
        into divergences: inout [Divergence],
        leftovers: inout Leftovers
    ) {
        var candidateBySignature: [Signature: [TraceEvent]] = [:]
        for event in candidate {
            candidateBySignature[signature(event), default: []].append(event)
        }

        var baselineBySignature: [Signature: [TraceEvent]] = [:]
        var signatureOrder: [Signature] = []
        for event in baseline {
            let sig = signature(event)
            if baselineBySignature[sig] == nil {
                signatureOrder.append(sig)
            }
            baselineBySignature[sig, default: []].append(event)
        }

        for sig in signatureOrder {
            var unmatched = candidateBySignature.removeValue(forKey: sig) ?? []
            var unpaired: [TraceEvent] = []
            var pairs: [(TraceEvent, TraceEvent)] = []
            for event in baselineBySignature[sig] ?? [] {
                if let index = unmatched.firstIndex(where: { payloadsMatch(event, $0, spec: spec) }) {
                    pairs.append((event, unmatched.remove(at: index)))
                } else {
                    unpaired.append(event)
                }
            }
            while !unpaired.isEmpty, !unmatched.isEmpty {
                pairs.append((unpaired.removeFirst(), unmatched.removeFirst()))
            }
            for (baselineEvent, candidateEvent) in pairs {
                compareAligned(
                    baselineEvent,
                    candidateEvent,
                    spec: spec,
                    isAdvisory: isAdvisory(baselineEvent.tier, under: spec),
                    into: &divergences
                )
            }
            leftovers.baseline.append(contentsOf: unpaired)
            leftovers.candidate.append(contentsOf: unmatched)
        }
        for events in candidateBySignature.values {
            leftovers.candidate.append(contentsOf: events)
        }
    }

    // MARK: - Across domains

    /// Pair bucket leftovers by signature-minus-domain (`domainMigration`, values still the
    /// contract), classify the rest as missing/unexpected, and report each migration out of an
    /// ordered domain into an unordered one as a single `orderingRelaxed` per domain pair.
    private static func reconcileAcrossDomains(
        _ leftovers: Leftovers,
        spec: Tolerance,
        into divergences: inout [Divergence]
    ) {
        var relaxations: [Relaxation] = []
        var unmatched = leftovers.candidate.sorted { $0.seq < $1.seq }

        for event in leftovers.baseline.sorted(by: { $0.seq < $1.seq }) {
            let eventSig = signature(event).ignoringDomain
            // Content-identical counterpart first. Migrated events arrive in the *other* side's
            // scheduling order, so pairing greedily by position would manufacture value mismatches
            // between branches that both ran correctly — the exact flapping the projection removes.
            if spec.domainMigration != .ignored,
               let slot = unmatched.firstIndex(where: {
                   signature($0).ignoringDomain == eventSig && payloadsMatch(event, $0, spec: spec)
               }) ?? unmatched.firstIndex(where: { signature($0).ignoringDomain == eventSig }) {
                let counterpart = unmatched.remove(at: slot)
                recordMigration(event, counterpart, spec: spec, into: &divergences, relaxations: &relaxations)
            } else {
                divergences.append(
                    Divergence(
                        kind: .missingEvent,
                        label: event.label,
                        baselineSeq: event.seq,
                        candidateSeq: nil,
                        detail: "\(event.kind.rawValue) present in baseline, absent in candidate",
                        isAdvisory: isAdvisory(event.tier, under: spec)
                    )
                )
            }
        }
        for event in unmatched {
            divergences.append(
                Divergence(
                    kind: .unexpectedEvent,
                    label: event.label,
                    baselineSeq: nil,
                    candidateSeq: event.seq,
                    detail: "\(event.kind.rawValue) present in candidate, absent in baseline",
                    isAdvisory: isAdvisory(event.tier, under: spec)
                )
            )
        }

        // The relaxation gates regardless of tier: a dropped ordering guarantee is a property of the
        // domain, not of any one event, and the migration that carried it is advisory precisely
        // because this divergence is the one that isn't. `Intent` is the way to green.
        for relaxation in relaxations {
            divergences.append(
                Divergence(
                    kind: .orderingRelaxed,
                    label: relaxation.origin.declaredName,
                    baselineSeq: relaxation.firstBaselineSeq,
                    candidateSeq: relaxation.firstCandidateSeq,
                    detail: "ordering guarantee dropped: \(relaxation.origin) → \(relaxation.destination) "
                        + "(\(relaxation.count) event\(relaxation.count == 1 ? "" : "s"))"
                )
            )
        }
    }

    /// One migrated pair: the move disclosed once, the values still compared — and when the move left
    /// an ordered domain for an unordered one, tallied toward that pair's `orderingRelaxed`.
    private static func recordMigration(
        _ event: TraceEvent,
        _ counterpart: TraceEvent,
        spec: Tolerance,
        into divergences: inout [Divergence],
        relaxations: inout [Relaxation]
    ) {
        divergences.append(
            Divergence(
                kind: .domainMigration,
                label: event.label,
                baselineSeq: event.seq,
                candidateSeq: counterpart.seq,
                detail: "ran on a different domain (\(event.domain) → \(counterpart.domain))",
                isAdvisory: isAdvisory(event.tier, under: spec) || spec.domainMigration == .advisory
            )
        )
        compareAligned(
            event,
            counterpart,
            spec: spec,
            isAdvisory: isAdvisory(event.tier, under: spec),
            into: &divergences
        )
        guard event.domain.isOrdered, !counterpart.domain.isOrdered else { return }
        if let index = relaxations.firstIndex(where: {
            $0.origin == event.domain && $0.destination == counterpart.domain
        }) {
            relaxations[index].count += 1
        } else {
            relaxations.append(Relaxation(
                origin: event.domain,
                destination: counterpart.domain,
                count: 1,
                firstBaselineSeq: event.seq,
                firstCandidateSeq: counterpart.seq
            ))
        }
    }

    /// Whether two events' payloads are indistinguishable under the tolerance spec — the multiset
    /// matching predicate. Volatile fields are already redacted by canonicalization; the epsilon
    /// comes from the spec.
    static func payloadsMatch(_ baseline: TraceEvent, _ candidate: TraceEvent, spec: Tolerance) -> Bool {
        valueDivergences(baseline.payload ?? .null, candidate.payload ?? .null, path: "", spec: spec).isEmpty
    }
}
