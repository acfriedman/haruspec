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
        case orderingLost // a happens-before constraint held in baseline; the candidate leaves the pair concurrent
        case orderingAdded // the candidate constrains a pair the baseline left concurrent — new synchronization
        case valueMismatch // an aligned event's payload differs beyond tolerance
        case timingRegression // an aligned interval got slower than its declared budget allows
    }

    public var kind: Kind
    public var label: String
    public var baselineSeq: Int?
    public var candidateSeq: Int?
    public var detail: String
    /// For a divergence that is *about* domains (`domainMigration`, `orderingRelaxed`): where the
    /// work was, and where it went — carried structurally so `Intent` can match a declared move
    /// without parsing prose out of `detail`.
    public var fromDomain: String?
    public var toDomain: String?
    /// For a `valueMismatch`: the leaf path that differed (`"info.pointsEarned"`, `"query[0]"`) and
    /// both sides' values, carried structurally so a precise declaration (`.to(32)`, `.increases()`)
    /// compares values rather than parsing them back out of `detail`.
    public var field: String?
    public var baselineValue: CanonicalValue?
    public var candidateValue: CanonicalValue?
    /// The declared op the diverging event was recorded under, which an op-scoped declaration
    /// (`.only(in:)`, `.once(per:)`) matches against; `nil` when the event carried none.
    ///
    /// The candidate's event when there is one (the side the change is on), else the baseline's.
    public var op: OpIdentity?
    /// True when this divergence is reported but does not fail the verdict (a structural divergence
    /// under `structuralComparison == .advisory`).
    public var isAdvisory: Bool
    /// Whether the change *declared* this divergence. Defaults to `.collateral`; the intent classifier
    /// promotes declared ones to `.intended`. Parity mode leaves everything `.collateral`.
    public var classification: DivergenceClass
    /// The declarations (by DSL spelling) that named this divergence's kind and label but whose
    /// modifier rejected it — a `.once(per:)` that saw two, an `.increases()` that saw a drop.
    ///
    /// Empty for an intended divergence and for a collateral one no declaration was about; a
    /// non-empty list is the author's own tripwire firing, which the report names instead of offering a wider line.
    public var rejectedBy: [String]

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
        fromDomain: String? = nil,
        toDomain: String? = nil,
        field: String? = nil,
        baselineValue: CanonicalValue? = nil,
        candidateValue: CanonicalValue? = nil,
        op: OpIdentity? = nil,
        isAdvisory: Bool = false,
        classification: DivergenceClass = .collateral,
        rejectedBy: [String] = []
    ) {
        self.kind = kind
        self.label = label
        self.baselineSeq = baselineSeq
        self.candidateSeq = candidateSeq
        self.detail = detail
        self.fromDomain = fromDomain
        self.toDomain = toDomain
        self.field = field
        self.baselineValue = baselineValue
        self.candidateValue = candidateValue
        self.op = op
        self.isAdvisory = isAdvisory
        self.classification = classification
        self.rejectedBy = rejectedBy
    }
}

/// The oracle's verdict on whether the candidate's behavior trace matches the baseline's within the
/// declared tolerances. It carries every divergence found, so a failing verdict is its own report.
public struct TraceDiff: Codable, Sendable, Equatable {
    /// The four verdict tiers, kept in one place so every layer speaks one vocabulary. A pure trace
    /// comparison only ever produces `.equivalent` or `.diverged`; `.cannotVerify` and `.unstable`
    /// are resolved further out, where coverage and repeated replays are known.
    ///
    /// `.cannotVerify` is what a `VerificationResult` reaches when isolation was incomplete: it
    /// downgrades an untrustworthy EQUIVALENT rather than emit a false pass. `.unstable` is one layer
    /// further out: identical replays that disagree (``Spec/verify(replaying:)`` runs the plan more than
    /// once) prove an unmodeled nondeterministic axis, and neither disagreeing verdict can be stood
    /// behind — a flapping red presented as red would be a coin flip wearing a verdict.
    public enum Verdict: String, Codable, Sendable { case equivalent, diverged, cannotVerify, unstable }

    public var verdict: Verdict
    public var baselineName: String
    public var candidateName: String
    public var divergences: [Divergence]

    /// Declared intent that matched no divergence, by DSL spelling (`Changes("Search.query")`) —
    /// set by `classified(against:)`, empty in parity mode.
    ///
    /// A dead declaration is a claim about the change that the oracle never saw: a dark feature, or
    /// stale intent left over from an earlier revision — and either way a *standing excuse* that
    /// would silently absorb a future divergence. So the continuous gate fails on it (exit 6);
    /// reports render it on every surface.
    ///
    /// Only meaningful over a completed sweep: a replay that stopped at its first collateral
    /// divergence cannot claim any declaration matched nothing, so the diverged paths clear this.
    public var unobservedIntent: [String] = []

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
    /// Working state one comparison accumulates: the divergences found so far, and every aligned
    /// (baseline, candidate) pair — recorded at the single choke point every matcher runs through
    /// (`compareAligned`), so the spawn-edge pass can read the finished alignment whichever
    /// concurrency mode produced it.
    struct DiffScratch {
        var divergences: [Divergence] = []
        var alignedPairs: [(baseline: TraceEvent, candidate: TraceEvent)] = []
    }

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
        /// A divergence is advisory (reported, non-failing) when its event sits in the structural tier
        /// and the spec compares that tier under `.advisory`.
        func advisory(_ event: TraceEvent) -> Bool {
            isAdvisory(event, under: spec)
        }

        var scratch = DiffScratch()

        switch spec.concurrency {
        case .totalOrder:
            compareTotalOrder(
                baseline: baseline,
                candidate: candidate,
                spec: spec,
                advisory: advisory,
                into: &scratch
            )
        case .perDomain:
            // The projection: one comparison per domain (sequence where order is a guarantee,
            // multiset where it is scheduler noise), cross-domain order dropped. `DiffProjection.swift`.
            comparePerDomain(
                baseline: baseline,
                candidate: candidate,
                spec: spec,
                into: &scratch
            )
        }

        // The happens-before pass: with alignment settled, compare the *constraints* the recorded
        // spawn edges imply. `DiffSpawnEdges.swift`.
        compareSpawnEdges(baseline: baseline, candidate: candidate, spec: spec, into: &scratch)

        scratch.divergences.sort { lhs, rhs in
            (lhs.baselineSeq ?? lhs.candidateSeq ?? Int.max, lhs.candidateSeq ?? Int.max)
                < (rhs.baselineSeq ?? rhs.candidateSeq ?? Int.max, rhs.candidateSeq ?? Int.max)
        }

        // Stamp each divergence with the op of the event it points at, at the one choke point every
        // matcher's output passes through: the candidate's event when there is one (the side the
        // change is on), else the baseline's.
        let baselineOps = Dictionary(uniqueKeysWithValues: baseline.map { ($0.seq, $0.op) })
        let candidateOps = Dictionary(uniqueKeysWithValues: candidate.map { ($0.seq, $0.op) })
        for index in scratch.divergences.indices {
            let divergence = scratch.divergences[index]
            scratch.divergences[index].op = divergence.candidateSeq.flatMap { candidateOps[$0] ?? nil }
                ?? divergence.baselineSeq.flatMap { baselineOps[$0] ?? nil }
        }

        // Only gating divergences decide the verdict (non-advisory, and — after an optional intent
        // pass — not a declared, intended change).
        let diverged = scratch.divergences.contains(where: \.isGating)
        return TraceDiff(
            verdict: diverged ? .diverged : .equivalent,
            baselineName: rawBaseline.name,
            candidateName: rawCandidate.name,
            divergences: scratch.divergences
        )
    }

    /// The `.totalOrder` comparison: one LCS over the whole interleaving, then reconciliation of
    /// whatever failed to align — steps 2–4 of the pipeline documented on `BehavioralDiff`.
    private static func compareTotalOrder(
        baseline: [TraceEvent],
        candidate: [TraceEvent],
        spec: Tolerance,
        advisory: (TraceEvent) -> Bool,
        into scratch: inout DiffScratch
    ) {
        let baselineSig = baseline.map(signature)
        let candidateSig = candidate.map(signature)

        let matched = contentFirstAlignment(baseline, candidate)
        let matchedBaseline = Set(matched.map(\.0))
        let matchedCandidate = Set(matched.map(\.1))

        // 4a. Aligned (in-order) pairs: compare values + timing.
        for (baselineIndex, candidateIndex) in matched {
            compareAligned(
                baseline[baselineIndex],
                candidate[candidateIndex],
                spec: spec,
                isAdvisory: advisory(baseline[baselineIndex]),
                into: &scratch
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
            into: &scratch
        )
    }

    // MARK: - Aligned-pair comparison

    /// One differing leaf: where it differed and both sides' values, plus the rendered message.
    struct ValueMismatch {
        var path: String
        var baseline: CanonicalValue
        var candidate: CanonicalValue
        var detail: String
    }

    /// Returns one mismatch per leaf path at which two canonical values differ beyond the tolerance.
    /// Internal rather than private because the projection's multiset matching uses it as its predicate.
    ///
    /// - Parameters:
    ///   - baseline: The recorded value.
    ///   - candidate: The value compared against it.
    ///   - path: The dotted route to `baseline` from the payload root.
    ///   - spec: The tolerance in force.
    /// - Returns: The mismatches, each at a path beneath `path`; empty when the values are equivalent,
    ///   with numbers within `spec.numericEpsilon` counting as equal.
    static func valueDivergences(
        _ baseline: CanonicalValue,
        _ candidate: CanonicalValue,
        path: String,
        spec: Tolerance
    ) -> [ValueMismatch] {
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
                return [ValueMismatch(
                    path: label(path),
                    baseline: baseline,
                    candidate: candidate,
                    detail: "\(label(path)): array length "
                        + "baseline=\(baselineArray.count) candidate=\(candidateArray.count)"
                )]
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

    private static func mismatch(
        _ path: String,
        _ baseline: CanonicalValue,
        _ candidate: CanonicalValue
    ) -> ValueMismatch {
        ValueMismatch(
            path: label(path),
            baseline: baseline,
            candidate: candidate,
            detail: "\(label(path)): baseline=\(baseline.canonicalString) candidate=\(candidate.canonicalString)"
        )
    }
}
