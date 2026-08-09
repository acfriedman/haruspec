import Foundation

/// How a divergence relates to the change's *declared intent* (see `Intent`). Tolerated deltas
/// never become divergences at all; of those that do, `intended` ones were declared and don't gate,
/// `collateral` ones were not — the residual an extension-mode verdict fails on.
public enum DivergenceClass: String, Codable, Sendable {
    case collateral // undeclared behavioral change — gates the verdict
    case intended // declared in the intent spec as expected — reported, non-gating
}

/// One way a candidate trace departs from its baseline.
public struct Divergence: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case missingEvent // baseline had an event the candidate never produced
        case unexpectedEvent // candidate produced an event the baseline never had
        case reordered // an event moved, and its order is significant
        case domainMigration // the same event, on a different isolation domain
        case orderingRelaxed // work left an ordered domain for an unordered one — a guarantee was dropped
        case valueMismatch // an aligned event's payload differs beyond tolerance
        case timingRegression // an aligned interval got slower than its declared budget allows
    }

    public var kind: Kind
    public var label: String
    public var baselineSeq: Int?
    public var candidateSeq: Int?
    public var detail: String
    /// True when this divergence is reported but does not fail the verdict (a structural divergence
    /// under `structuralComparison == .advisory`).
    public var isAdvisory: Bool
    /// Whether the change *declared* this divergence. Defaults to `.collateral`; the intent classifier
    /// promotes declared ones to `.intended`. Parity mode leaves everything `.collateral`.
    public var classification: DivergenceClass

    /// A divergence gates the verdict iff it is neither advisory nor a declared, intended change.
    public var isGating: Bool {
        !isAdvisory && classification == .collateral
    }

    public init(
        kind: Kind,
        label: String,
        baselineSeq: Int?,
        candidateSeq: Int?,
        detail: String,
        isAdvisory: Bool = false,
        classification: DivergenceClass = .collateral
    ) {
        self.kind = kind
        self.label = label
        self.baselineSeq = baselineSeq
        self.candidateSeq = candidateSeq
        self.detail = detail
        self.isAdvisory = isAdvisory
        self.classification = classification
    }
}

/// The oracle's verdict: does the new behavior trace match the old within declared tolerances?
public struct TraceDiff: Codable, Sendable, Equatable {
    /// Three-tier by design (see `VerificationResult`): a pure trace comparison only ever *produces*
    /// `.equivalent` / `.diverged` — `BehavioralDiff.compare` never emits `.cannotVerify`, because a
    /// diff has no notion of coverage. `.cannotVerify` is the *resolved* verdict a `VerificationResult`
    /// reaches when isolation was incomplete, so it downgrades an untrustworthy EQUIVALENT rather than
    /// emit a false pass. The case lives here so both types speak one verdict vocabulary.
    public enum Verdict: String, Codable, Sendable { case equivalent, diverged, cannotVerify }

    public var verdict: Verdict
    public var baselineName: String
    public var candidateName: String
    public var divergences: [Divergence]

    public var isEquivalent: Bool {
        verdict == .equivalent
    }
}

/// The evergreen "behavioral diff" primitive. Everything else in the product is a caller of this.
///
/// Pipeline:
///  1. Canonicalize both traces under the tolerance spec (redact volatile fields, drop ignored kinds).
///  2. Align event *signatures* (kind+label+domain) with an LCS — robust to insertions,
///     deletions and moves without assuming lockstep positions.
///  3. Classify the leftovers: matched-and-moved ⇒ reordered, same event on another domain ⇒
///     domainMigration, unmatched-baseline ⇒ missing, unmatched-candidate ⇒ unexpected.
///  4. For every aligned pair, compare payload values (within numeric epsilon) and interval timing
///     (within declared budgets).
public enum BehavioralDiff {
    public static func compare(
        baseline rawBaseline: Trace,
        candidate rawCandidate: Trace,
        tolerances spec: Tolerance = .strict
    ) -> TraceDiff {
        var baseline = Canonicalizer.canonicalize(rawBaseline, spec: spec).events
        var candidate = Canonicalizer.canonicalize(rawCandidate, spec: spec).events

        // Two-tier: when the structural tier is ignored, compare only the semantic (product) events.
        if spec.structuralComparison == .ignored {
            baseline = baseline.filter { $0.tier == .semantic }
            candidate = candidate.filter { $0.tier == .semantic }
        }
        /// A structural divergence is advisory (reported, non-failing) in `.advisory` mode.
        func advisory(_ tier: EventTier) -> Bool {
            spec.structuralComparison == .advisory && tier == .structural
        }

        var divergences: [Divergence] = []

        switch spec.concurrency {
        case .totalOrder:
            compareTotalOrder(
                baseline: baseline,
                candidate: candidate,
                spec: spec,
                advisory: advisory,
                into: &divergences
            )
        case .perDomain:
            // The projection: one comparison per domain (sequence where order is a guarantee,
            // multiset where it is scheduler noise), cross-domain order dropped. `DiffProjection.swift`.
            comparePerDomain(
                baseline: baseline,
                candidate: candidate,
                spec: spec,
                into: &divergences
            )
        }

        divergences.sort { lhs, rhs in
            (lhs.baselineSeq ?? lhs.candidateSeq ?? Int.max, lhs.candidateSeq ?? Int.max)
                < (rhs.baselineSeq ?? rhs.candidateSeq ?? Int.max, rhs.candidateSeq ?? Int.max)
        }

        // Only gating divergences decide the verdict (non-advisory, and — after an optional intent
        // pass — not a declared, intended change).
        let diverged = divergences.contains(where: \.isGating)
        return TraceDiff(
            verdict: diverged ? .diverged : .equivalent,
            baselineName: rawBaseline.name,
            candidateName: rawCandidate.name,
            divergences: divergences
        )
    }

    /// The `.totalOrder` comparison: one LCS over the whole interleaving, then reconciliation of
    /// whatever failed to align. This is the original pipeline (steps 2–4), unchanged.
    private static func compareTotalOrder(
        baseline: [TraceEvent],
        candidate: [TraceEvent],
        spec: Tolerance,
        advisory: (EventTier) -> Bool,
        into divergences: inout [Divergence]
    ) {
        let baselineSig = baseline.map(signature)
        let candidateSig = candidate.map(signature)

        let matched = longestCommonSubsequence(baselineSig, candidateSig)
        let matchedBaseline = Set(matched.map(\.0))
        let matchedCandidate = Set(matched.map(\.1))

        // 4a. Aligned (in-order) pairs: compare values + timing.
        for (baselineIndex, candidateIndex) in matched {
            compareAligned(
                baseline[baselineIndex],
                candidate[candidateIndex],
                spec: spec,
                isAdvisory: advisory(baseline[baselineIndex].tier),
                into: &divergences
            )
        }

        reconcileUnmatched(
            Alignment(
                baseline: baseline,
                candidate: candidate,
                baselineSig: baselineSig,
                candidateSig: candidateSig,
                matchedBaseline: matchedBaseline,
                matchedCandidate: matchedCandidate
            ),
            spec: spec,
            advisory: advisory,
            into: &divergences
        )
    }

    // MARK: - Aligned-pair comparison

    static func compareAligned(
        _ baseline: TraceEvent,
        _ candidate: TraceEvent,
        spec: Tolerance,
        isAdvisory: Bool,
        into out: inout [Divergence]
    ) {
        for path in valueDivergences(baseline.payload ?? .null, candidate.payload ?? .null, path: "", spec: spec) {
            out.append(
                Divergence(
                    kind: .valueMismatch,
                    label: baseline.label,
                    baselineSeq: baseline.seq,
                    candidateSeq: candidate.seq,
                    detail: path,
                    isAdvisory: isAdvisory
                )
            )
        }
        if let budget = spec.timingBudget(for: baseline.label),
           let base = baseline.durationTicks, let cand = candidate.durationTicks, cand - base > budget {
            out.append(
                Divergence(
                    kind: .timingRegression,
                    label: baseline.label,
                    baselineSeq: baseline.seq,
                    candidateSeq: candidate.seq,
                    detail: "duration \(base)→\(cand) ticks exceeds budget +\(budget) (Δ=\(cand - base))",
                    isAdvisory: isAdvisory
                )
            )
        }
    }

    /// Structural, tolerance-aware value comparison. Returns one message per differing leaf path.
    /// Internal rather than private: the projection's multiset matching uses it as its predicate.
    static func valueDivergences(
        _ baseline: CanonicalValue,
        _ candidate: CanonicalValue,
        path: String,
        spec: Tolerance
    ) -> [String] {
        if let baselineNumber = numeric(baseline), let candidateNumber = numeric(candidate) {
            return abs(baselineNumber - candidateNumber) <= spec.numericEpsilon
                ? [] : [mismatch(path, baseline, candidate)]
        }
        switch (baseline, candidate) {
        case (.null, .null):
            return []
        case let (.bool(baselineBool), .bool(candidateBool)):
            return baselineBool == candidateBool ? [] : [mismatch(path, baseline, candidate)]
        case let (.string(baselineString), .string(candidateString)):
            return baselineString == candidateString ? [] : [mismatch(path, baseline, candidate)]
        case let (.array(baselineArray), .array(candidateArray)):
            guard baselineArray.count == candidateArray.count else {
                return ["\(label(path)): array length "
                    + "baseline=\(baselineArray.count) candidate=\(candidateArray.count)"]
            }
            return baselineArray.indices.flatMap {
                valueDivergences(baselineArray[$0], candidateArray[$0], path: "\(label(path))[\($0)]", spec: spec)
            }
        case let (.object(baselineObject), .object(candidateObject)):
            let keys = Set(baselineObject.keys).union(candidateObject.keys).sorted()
            return keys.flatMap { key in
                valueDivergences(
                    baselineObject[key] ?? .null,
                    candidateObject[key] ?? .null,
                    path: path.isEmpty ? key : "\(path).\(key)",
                    spec: spec
                )
            }
        default:
            return [mismatch(path, baseline, candidate)] // type mismatch
        }
    }

    private static func numeric(_ value: CanonicalValue) -> Double? {
        switch value {
        case let .int(intValue): Double(intValue)
        case let .double(doubleValue): doubleValue
        default: nil
        }
    }

    private static func label(_ path: String) -> String {
        path.isEmpty ? "value" : path
    }

    private static func mismatch(_ path: String, _ baseline: CanonicalValue, _ candidate: CanonicalValue) -> String {
        "\(label(path)): baseline=\(baseline.canonicalString) candidate=\(candidate.canonicalString)"
    }
}
