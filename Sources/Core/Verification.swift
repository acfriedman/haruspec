import Foundation

/// A behavioral diff **plus the coverage it was measured over** — the object the harness, CLI and MCP
/// callers actually consume. It carries the *resolved* four-tier verdict.
///
/// ``BehavioralDiff/compare`` stays a pure, binary comparison of two traces; this wrapper is the only
/// place `CANNOT-VERIFY` is reached, and only via ``resolve(diff:coverage:)``. The split keeps the
/// crown-jewel diff free of any notion of isolation/coverage, exactly as
/// ``TraceDiff/classified(against:evidence:)`` keeps intent out of it.
public struct VerificationResult: Codable, Sendable, Equatable {
    /// The pure trace comparison (already intent-classified, if any).
    public var diff: TraceDiff
    /// How much of the declared behavioral surface the replay exercised.
    public var coverage: Coverage
    /// The sound, resolved verdict derived from `diff` + `coverage`.
    public var verdict: TraceDiff.Verdict

    /// Creates the result for a diff over the coverage it was measured against, with the verdict
    /// already resolved.
    ///
    /// - Parameters:
    ///   - diff: The pure trace comparison, intent-classified if any intent was declared.
    ///   - coverage: How much of the declared surface the replay exercised.
    public init(diff: TraceDiff, coverage: Coverage) {
        self.diff = diff
        self.coverage = coverage
        verdict = Self.resolve(diff: diff, coverage: coverage)
    }

    /// Returns the sound verdict for a diff over its coverage. A false `EQUIVALENT` is the one
    /// catastrophic outcome, so `DIVERGED` **stands** and `EQUIVALENT` is trusted **only** over a
    /// fully-isolated replay.
    ///
    /// - Parameters:
    ///   - diff: The pure trace comparison.
    ///   - coverage: The surface the replay exercised.
    /// - Returns: `diff.verdict` unchanged for `.diverged`, `.cannotVerify`, and `.unstable`;
    ///   `.equivalent` only when ``Coverage/trustsEquivalent`` holds, else `.cannotVerify`.
    ///
    /// Coverage annotates a divergence, never hides it: a change may diverge *more* off the covered
    /// surface, but it already failed. A coverage gap downgrades an equivalence rather than emit a
    /// pass the engine cannot stand behind.
    public static func resolve(diff: TraceDiff, coverage: Coverage) -> TraceDiff.Verdict {
        switch diff.verdict {
        // `.unstable` is resolved a layer further out (replay repetition, not coverage) and never
        // produced by a comparison; a diff carrying it stands as-is, like a DIVERGED.
        case .diverged, .cannotVerify, .unstable:
            diff.verdict
        case .equivalent:
            coverage.trustsEquivalent ? .equivalent : .cannotVerify
        }
    }

    /// Only a fully-covered, non-diverging replay is equivalent. A `CANNOT-VERIFY` is *not* equivalent —
    /// callers gating on this must treat abstention as "not a pass."
    public var isEquivalent: Bool {
        verdict == .equivalent
    }

    /// Returns the result with its intent-declared divergences reclassified and the verdict
    /// re-resolved against the same coverage. Symmetric to ``TraceDiff/classified(against:evidence:)``.
    ///
    /// - Parameters:
    ///   - intent: The declared intent.
    ///   - evidence: What the intent's modifiers are checked against; ``ProbeEvidence/none`` when
    ///     nothing was probed.
    /// - Returns: A new result; the receiver is unchanged.
    public func classified(against intent: Intent, evidence: ProbeEvidence = .none) -> VerificationResult {
        VerificationResult(diff: diff.classified(against: intent, evidence: evidence), coverage: coverage)
    }
}
