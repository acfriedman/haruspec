import Foundation

/// A behavioral diff **plus the coverage it was measured over** — the object the harness, CLI and MCP
/// callers actually consume. It carries the *resolved* three-tier verdict.
///
/// `BehavioralDiff.compare` stays a pure, binary comparison of two traces; this wrapper is the only
/// place `CANNOT-VERIFY` is reached, and only via `resolve`. The split keeps the crown-jewel diff free
/// of any notion of isolation/coverage, exactly as `classified(against:)` keeps intent out of it.
public struct VerificationResult: Codable, Sendable, Equatable {
    /// The pure trace comparison (already intent-classified, if any).
    public var diff: TraceDiff
    /// How much of the declared behavioral surface the replay exercised.
    public var coverage: Coverage
    /// The sound, three-tier verdict derived from `diff` + `coverage`.
    public var verdict: TraceDiff.Verdict

    public init(diff: TraceDiff, coverage: Coverage) {
        self.diff = diff
        self.coverage = coverage
        self.verdict = Self.resolve(diff: diff, coverage: coverage)
    }

    /// The soundness core. A false `EQUIVALENT` is the one catastrophic outcome, so:
    ///  - `DIVERGED` **stands** — a real divergence is the safe direction; coverage annotates it, never
    ///    hides it (a change may diverge *more* off the covered surface, but it already failed).
    ///  - `EQUIVALENT` is trusted **only** over a fully-isolated replay; any coverage gap downgrades it
    ///    to `CANNOT-VERIFY` rather than emit a pass the engine can't stand behind.
    public static func resolve(diff: TraceDiff, coverage: Coverage) -> TraceDiff.Verdict {
        switch diff.verdict {
        case .diverged, .cannotVerify:
            return diff.verdict
        case .equivalent:
            return coverage.trustsEquivalent ? .equivalent : .cannotVerify
        }
    }

    /// Only a fully-covered, non-diverging replay is equivalent. A `CANNOT-VERIFY` is *not* equivalent —
    /// callers gating on this must treat abstention as "not a pass."
    public var isEquivalent: Bool { verdict == .equivalent }

    /// Extension mode over the wrapped diff: reclassify the intent-declared divergences, then re-resolve
    /// against the same coverage. Symmetric to `TraceDiff.classified(against:)`.
    public func classified(against intent: IntentSpec) -> VerificationResult {
        VerificationResult(diff: diff.classified(against: intent), coverage: coverage)
    }
}
