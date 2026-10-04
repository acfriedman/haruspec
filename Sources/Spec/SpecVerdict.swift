import Foundation
import HaruspecCore
import HaruspecSeams

/// The outcome of a spec run: the resolved verdict *with the coverage it was measured over*, how
/// much was explored, and — for an order-dependent divergence — the failing call sequence: shrunk to
/// minimal by ``BaselinedSpec/verify(candidate:declaring:)``, but the *raw recorded ordering* on
/// ``BaselinedSpec/verify(replaying:declaring:replays:)``, which never shrinks (a shrunk variant has
/// no recorded golden to diff against).
/// `Codable`, so a verify run is writable as a `result.json` artifact a reviewer can read and reproduce.
///
/// Read-only outside the module. Inside it, a step that adjusts one field (an audit's outcome, the
/// collected origins) copies and mutates rather than rebuilding through the initializer, so a
/// field added later is carried by every step without each one having to name it.
public struct SpecVerdict: Codable, Sendable {
    /// The artifact's version stamp — `SpecPlan`'s discipline applied to the verdict side (see
    /// `supportedSchemaVersion` in SpecVerdictSerialization.swift). An unstamped `result.json`
    /// predates the qualification block and is refused with "re-run", never part-decoded.
    public let schemaVersion: Int
    /// The diff + coverage pair carrying the *resolved* verdict (see `VerificationResult`): an
    /// EQUIVALENT the replay can't stand behind (an op or seam fell back to live) downgrades to
    /// CANNOT-VERIFY; a DIVERGED always stands.
    public internal(set) var result: VerificationResult
    public internal(set) var orderingsExplored: Int
    public internal(set) var failingOrder: [String]?
    /// Declared `.after` preconditions the failing order broke, as `"removeMug after addMug"`. That
    /// stratum is explored on purpose, so a divergence here is a finding about a defensive path — worth
    /// separating from one on the surface the author described. Empty on an in-order failure, `nil`
    /// where no order was reported at all.
    public internal(set) var violatedPreconditions: [String]?
    /// The generated input that triggered a divergence (its varied seam values are the counterexample).
    public internal(set) var counterexample: CassetteData?
    /// The budget spent and the surface it covered.
    public internal(set) var exploration: Exploration
    /// What the verdict was measured over — the disclaimer's feeds, rendered as the qualification
    /// block on every surface (see Qualification.swift). No default: an empty qualification would
    /// claim a surface of nothing, which is a statement, not an absence.
    public internal(set) var qualification: Qualification
    /// How the verdict behaved across repeated replays. `.singleRun` where repetition never happened
    /// (the live differential, a one-pass replay) — reported as unmeasured, never as reproduced.
    public internal(set) var stability: Stability
    /// Channels the spec and check site declared acceptable as uncaptured, carried on the verdict so
    /// *every* audit path resolves the same declarations — the env-driven audit inside a verify and
    /// an explicit `audited(against:)` afterwards must not disagree. `nil` on artifacts recorded
    /// before the field existed; treated as none declared.
    public internal(set) var acceptedBlindSpots: [String]?
    /// Every failing case a red replay walked within its window after the first (see
    /// `FailingCases`). `result.diff`, `failingOrder` and `counterexample` are the richest of them.
    /// `nil` on a green verdict and on the live differential, which shrinks one case instead.
    public internal(set) var failingCases: FailingCases?
    /// Where each declared change was first observed, one entry per declaration the sweep saw hold
    /// — the disclosure a green-by-declaration verdict owes. Empty in parity mode.
    public internal(set) var intentObservations: [IntentObservation]

    public init(
        schemaVersion: Int = SpecVerdict.supportedSchemaVersion,
        result: VerificationResult,
        orderingsExplored: Int,
        failingOrder: [String]?,
        counterexample: CassetteData?,
        exploration: Exploration,
        qualification: Qualification,
        violatedPreconditions: [String]? = nil,
        stability: Stability = .singleRun,
        acceptedBlindSpots: [String]? = nil,
        failingCases: FailingCases? = nil,
        intentObservations: [IntentObservation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.result = result
        self.orderingsExplored = orderingsExplored
        self.failingOrder = failingOrder
        self.counterexample = counterexample
        self.exploration = exploration
        self.qualification = qualification
        self.violatedPreconditions = violatedPreconditions
        self.stability = stability
        self.acceptedBlindSpots = acceptedBlindSpots
        self.failingCases = failingCases
        self.intentObservations = intentObservations
    }

    /// The resolved verdict, with stability applied above coverage: disagreeing replays flip *any*
    /// underlying verdict to UNSTABLE — a coin flip reported as red (or green) would spend the gate's
    /// credibility on noise. `result.verdict` keeps run 1's underlying verdict for forensics.
    public var verdict: TraceDiff.Verdict {
        stability.isStable ? result.verdict : .unstable
    }

    public var diff: TraceDiff {
        result.diff
    }

    /// The declared interrogation surface (`op:` boundaries + seams) and how much of it was exercised.
    public var coverage: Coverage {
        result.coverage
    }
}
