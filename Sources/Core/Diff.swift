import Foundation

/// How a divergence relates to the change's *declared intent* (see `IntentSpec`). Tolerated deltas
/// never become divergences at all; of those that do, `intended` ones were declared and don't gate,
/// `collateral` ones were not — the residual an extension-mode verdict fails on.
public enum DivergenceClass: String, Codable, Sendable {
    case collateral  // undeclared behavioral change — gates the verdict
    case intended    // declared in the intent spec as expected — reported, non-gating
}

/// One way a candidate trace departs from its baseline.
public struct Divergence: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case missingEvent      // baseline had an event the candidate never produced
        case unexpectedEvent   // candidate produced an event the baseline never had
        case reordered         // an event moved, and its order is significant
        case valueMismatch     // an aligned event's payload differs beyond tolerance
        case timingRegression  // an aligned interval got slower than its declared budget allows
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
    public var isGating: Bool { !isAdvisory && classification == .collateral }

    public init(kind: Kind, label: String, baselineSeq: Int?, candidateSeq: Int?,
                detail: String, isAdvisory: Bool = false,
                classification: DivergenceClass = .collateral) {
        self.kind = kind
        self.label = label
        self.baselineSeq = baselineSeq
        self.candidateSeq = candidateSeq
        self.detail = detail
        self.isAdvisory = isAdvisory
        self.classification = classification
    }

    enum CodingKeys: String, CodingKey {
        case kind, label, baselineSeq, candidateSeq, detail, isAdvisory, classification
    }

    // Tolerant decode so older diff JSON (written before `classification` existed) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        baselineSeq = try c.decodeIfPresent(Int.self, forKey: .baselineSeq)
        candidateSeq = try c.decodeIfPresent(Int.self, forKey: .candidateSeq)
        detail = try c.decode(String.self, forKey: .detail)
        isAdvisory = try c.decodeIfPresent(Bool.self, forKey: .isAdvisory) ?? false
        classification = try c.decodeIfPresent(DivergenceClass.self, forKey: .classification) ?? .collateral
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

    public var isEquivalent: Bool { verdict == .equivalent }
}

/// The evergreen "behavioral diff" primitive. Everything else in the product is a caller of this.
///
/// Pipeline:
///  1. Canonicalize both traces under the tolerance spec (redact volatile fields, drop ignored kinds).
///  2. Align event *signatures* (kind+label+thread) with an LCS — robust to insertions,
///     deletions and moves without assuming lockstep positions.
///  3. Classify the leftovers: matched-and-moved ⇒ reordered, unmatched-baseline ⇒ missing,
///     unmatched-candidate ⇒ unexpected.
///  4. For every aligned pair, compare payload values (within numeric epsilon) and interval timing
///     (within declared budgets).
public enum BehavioralDiff {
    private struct Signature: Hashable {
        let kind: EventKind
        let label: String
        let thread: LogicalThread
    }

    public static func compare(baseline rawBaseline: Trace,
                               candidate rawCandidate: Trace,
                               tolerances spec: ToleranceSpec = .strict) -> TraceDiff {
        var baseline = Canonicalizer.canonicalize(rawBaseline, spec: spec).events
        var candidate = Canonicalizer.canonicalize(rawCandidate, spec: spec).events

        // Two-tier: when the structural tier is ignored, compare only the semantic (product) events.
        if spec.structuralComparison == .ignored {
            baseline = baseline.filter { $0.tier == .semantic }
            candidate = candidate.filter { $0.tier == .semantic }
        }
        // A structural divergence is advisory (reported, non-failing) in `.advisory` mode.
        func advisory(_ tier: EventTier) -> Bool {
            spec.structuralComparison == .advisory && tier == .structural
        }

        let baselineSig = baseline.map(signature)
        let candidateSig = candidate.map(signature)

        let matched = longestCommonSubsequence(baselineSig, candidateSig)
        let matchedBaseline = Set(matched.map(\.0))
        let matchedCandidate = Set(matched.map(\.1))

        var divergences: [Divergence] = []

        // 4a. Aligned (in-order) pairs: compare values + timing.
        for (bi, ci) in matched {
            compareAligned(baseline[bi], candidate[ci], spec: spec,
                           isAdvisory: advisory(baseline[bi].tier), into: &divergences)
        }

        // 3/4b. Reconcile the unmatched: pair equal signatures as moves, rest are missing/unexpected.
        var unmatchedInsertions = candidate.indices.filter { !matchedCandidate.contains($0) }
        for bi in baseline.indices where !matchedBaseline.contains(bi) {
            if let slot = unmatchedInsertions.firstIndex(where: { candidateSig[$0] == baselineSig[bi] }) {
                let ci = unmatchedInsertions.remove(at: slot)
                if !spec.isUnordered(label: baseline[bi].label) {
                    divergences.append(Divergence(
                        kind: .reordered, label: baseline[bi].label,
                        baselineSeq: baseline[bi].seq, candidateSeq: candidate[ci].seq,
                        detail: "event order changed (baseline #\(baseline[bi].seq) → candidate #\(candidate[ci].seq))",
                        isAdvisory: advisory(baseline[bi].tier)))
                }
                // A moved event can still carry a value/timing regression — check it either way.
                compareAligned(baseline[bi], candidate[ci], spec: spec,
                               isAdvisory: advisory(baseline[bi].tier), into: &divergences)
            } else {
                divergences.append(Divergence(
                    kind: .missingEvent, label: baseline[bi].label,
                    baselineSeq: baseline[bi].seq, candidateSeq: nil,
                    detail: "\(baseline[bi].kind.rawValue) present in baseline, absent in candidate",
                    isAdvisory: advisory(baseline[bi].tier)))
            }
        }
        for ci in unmatchedInsertions {
            divergences.append(Divergence(
                kind: .unexpectedEvent, label: candidate[ci].label,
                baselineSeq: nil, candidateSeq: candidate[ci].seq,
                detail: "\(candidate[ci].kind.rawValue) present in candidate, absent in baseline",
                isAdvisory: advisory(candidate[ci].tier)))
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
            divergences: divergences)
    }

    // MARK: - Aligned-pair comparison

    private static func compareAligned(_ b: TraceEvent, _ c: TraceEvent, spec: ToleranceSpec,
                                       isAdvisory: Bool, into out: inout [Divergence]) {
        for path in valueDivergences(b.payload ?? .null, c.payload ?? .null, path: "", spec: spec) {
            out.append(Divergence(kind: .valueMismatch, label: b.label,
                                  baselineSeq: b.seq, candidateSeq: c.seq, detail: path,
                                  isAdvisory: isAdvisory))
        }
        if let budget = spec.timingBudget(for: b.label),
           let base = b.durationTicks, let cand = c.durationTicks, cand - base > budget {
            out.append(Divergence(kind: .timingRegression, label: b.label,
                baselineSeq: b.seq, candidateSeq: c.seq,
                detail: "duration \(base)→\(cand) ticks exceeds budget +\(budget) (Δ=\(cand - base))",
                isAdvisory: isAdvisory))
        }
    }

    /// Structural, tolerance-aware value comparison. Returns one message per differing leaf path.
    private static func valueDivergences(_ b: CanonicalValue, _ c: CanonicalValue,
                                         path: String, spec: ToleranceSpec) -> [String] {
        if let bn = numeric(b), let cn = numeric(c) {
            return abs(bn - cn) <= spec.numericEpsilon ? [] : [mismatch(path, b, c)]
        }
        switch (b, c) {
        case (.null, .null):
            return []
        case let (.bool(x), .bool(y)):
            return x == y ? [] : [mismatch(path, b, c)]
        case let (.string(x), .string(y)):
            return x == y ? [] : [mismatch(path, b, c)]
        case let (.array(x), .array(y)):
            guard x.count == y.count else {
                return ["\(label(path)): array length baseline=\(x.count) candidate=\(y.count)"]
            }
            return x.indices.flatMap { valueDivergences(x[$0], y[$0], path: "\(label(path))[\($0)]", spec: spec) }
        case let (.object(x), .object(y)):
            let keys = Set(x.keys).union(y.keys).sorted()
            return keys.flatMap { key in
                valueDivergences(x[key] ?? .null, y[key] ?? .null,
                                 path: path.isEmpty ? key : "\(path).\(key)", spec: spec)
            }
        default:
            return [mismatch(path, b, c)] // type mismatch
        }
    }

    private static func numeric(_ value: CanonicalValue) -> Double? {
        switch value {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    private static func label(_ path: String) -> String { path.isEmpty ? "value" : path }

    private static func mismatch(_ path: String, _ b: CanonicalValue, _ c: CanonicalValue) -> String {
        "\(label(path)): baseline=\(b.canonicalString) candidate=\(c.canonicalString)"
    }

    private static func signature(_ e: TraceEvent) -> Signature {
        Signature(kind: e.kind, label: e.label, thread: e.thread)
    }

    /// Classic O(n·m) LCS, returning the aligned index pairs in increasing order.
    private static func longestCommonSubsequence<T: Equatable>(_ a: [T], _ b: [T]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
