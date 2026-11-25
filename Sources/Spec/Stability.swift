import Foundation
import HaruspecCore

// Replay repetition — the trust layer above coverage. `verify(replaying:)` replays the plan more than
// once and requires every pass to reach the *same* verdict with the *same* divergence inventory. Two
// passes over identical recorded inputs have no legitimate reason to disagree, so a disagreement is
// proof of an unmodeled nondeterministic axis (an uncontrolled seam, or a missing projection) —
// exactly the failure that once made the parallel subject report a different counterexample every
// run. The delta between the disagreeing passes is not noise to suppress; it is the report's pointer
// to which axis is unmodeled, and where it is a payload field, the report names it as an
// `UncontrolledSeam` with the injection that controls it.
//
// The live differential has no repeated passes, so it measures the same thing where it matters: on a
// red, the failing input is rerun with the baseline on both sides. A baseline that cannot reproduce
// itself over identical inputs makes the red UNSTABLE rather than a finding about the candidate.

/// How a verdict behaved across repeated replays of the same plan: the number of passes and the
/// distinct outcomes they produced. One outcome = stable; more = UNSTABLE, and the outcomes *are* the
/// run-to-run delta the report renders.
public struct Stability: Codable, Sendable, Equatable {
    /// One distinct (verdict, divergence inventory) a replay pass produced, with the 1-based pass
    /// numbers that produced it — so "runs 1,3 diverged, run 2 held" reads straight off the artifact.
    public struct Outcome: Codable, Sendable, Equatable {
        public var runs: [Int]
        public var verdict: TraceDiff.Verdict
        /// Divergence fingerprints (kind + label + domains + detail), in reported order. Detail is
        /// part of identity on purpose: two passes that both say `valueMismatch Cart.total` but name
        /// different values disagree about the subject's behavior — which is the finding.
        public var inventory: [String]

        public init(runs: [Int], verdict: TraceDiff.Verdict, inventory: [String]) {
            self.runs = runs
            self.verdict = verdict
            self.inventory = inventory
        }
    }

    /// How many times the plan was replayed. 1 means stability was not measured (a single pass can't
    /// disagree with itself) — reports say so rather than claim a reproduction that never ran.
    public var replays: Int
    /// The distinct outcomes, in first-seen order. Never empty for a measured run.
    public var outcomes: [Outcome]
    /// The divergence fingerprints of the baseline compared against itself over the live
    /// differential's failing input.
    ///
    /// `nil` where it never ran (a green, or a replay, which measures through ``outcomes``
    /// instead); empty when the baseline reproduced itself, so the red is the candidate's.
    public var baselineSelfCheck: [String]?
    /// The payload fields that took different values over identical inputs, each a value the subject
    /// makes up itself instead of reading through a seam. `nil` when none was found.
    public var uncontrolledSeams: [UncontrolledSeam]?

    public init(
        replays: Int,
        outcomes: [Outcome],
        baselineSelfCheck: [String]? = nil,
        uncontrolledSeams: [UncontrolledSeam]? = nil
    ) {
        self.replays = replays
        self.outcomes = outcomes
        self.baselineSelfCheck = baselineSelfCheck
        self.uncontrolledSeams = uncontrolledSeams
    }

    /// Every measurement agreeing: at most one replay outcome, and a baseline that reproduced itself
    /// wherever it was rerun. The resolved verdict is `.unstable` exactly when this is false.
    public var isStable: Bool {
        outcomes.count <= 1 && (baselineSelfCheck?.isEmpty ?? true)
    }

    /// The unmeasured placeholder for verdicts that never repeat a run (the live differential, a
    /// single-pass replay). Renders as "single run", never as a reproduction claim.
    public static let singleRun = Stability(replays: 1, outcomes: [])

    /// Replay passes per ``BaselinedSpec/verify(replaying:declaring:replays:)``. More than one by
    /// default: a verdict never reproduced is a verdict on faith, and replay is the cheap leg.
    ///
    /// Three catches every always-different axis (the flapping-counterexample class) on the first
    /// disagreement, and a genuine coin-flip survives all three same-colored only one run in four.
    public static let defaultReplays = 3
}

public extension Divergence {
    /// The identity a divergence contributes to a stability inventory. Everything observable is
    /// included — kind, label, domains, detail — because replays of identical inputs may not differ
    /// in *any* of it and still count as the same behavior.
    var stabilityFingerprint: String {
        var parts = ["\(kind.rawValue) \(label)"]
        if let fromDomain, let toDomain {
            parts.append("\(fromDomain) → \(toDomain)")
        }
        parts.append(detail)
        return parts.joined(separator: " · ")
    }
}

extension SpecVerdict {
    /// The stability lines ``SpecVerdict/report()`` carries: one when the measurement agreed, and on
    /// a disagreement the delta itself, which names the unmodeled axis.
    ///
    /// For replays the delta is each distinct outcome with the passes that produced it; for the live
    /// differential, what the baseline could not reproduce. Either renders in full rather than as a
    /// count, followed by any uncontrolled seams.
    var stabilityLines: [String] {
        if let selfCheck = stability.baselineSelfCheck {
            return selfCheckLines(selfCheck)
        }
        guard stability.replays > 1 else {
            return []
        }
        guard !stability.isStable else {
            return ["  stability: \(stability.replays)/\(stability.replays) identical replays"]
        }
        var lines = ["  stability: \(stability.outcomes.count) distinct outcomes "
            + "across \(stability.replays) replays of identical inputs:"]
        for outcome in stability.outcomes {
            let runs = outcome.runs.map(String.init).joined(separator: ",")
            let noun = outcome.runs.count == 1 ? "run" : "runs"
            if outcome.inventory.isEmpty {
                lines.append("    \(noun) \(runs) → \(outcome.verdict.rawValue)")
            } else {
                lines.append("    \(noun) \(runs) → \(outcome.verdict.rawValue):")
                lines += outcome.inventory.map { "      \($0)" }
            }
        }
        lines.append("    ⚠︎ identical replays disagreed — an axis of nondeterminism is unmodeled "
            + "(an uncontrolled seam, or a missing projection); the delta above points at it")
        return lines + uncontrolledSeamLines
    }

    /// Returns the live differential's reproduction lines.
    ///
    /// - Parameter selfCheck: The divergence fingerprints of the baseline against itself; empty when
    ///   it reproduced itself.
    /// - Returns: One line for a reproduction; otherwise the disagreement, a warning, and the seams.
    private func selfCheckLines(_ selfCheck: [String]) -> [String] {
        guard !selfCheck.isEmpty else {
            return ["  stability: the baseline reproduced itself on the failing input"]
        }
        var lines = ["  stability: the baseline disagreed with itself on the failing input:"]
        lines += selfCheck.map { "      \($0)" }
        lines.append("    ⚠︎ the baseline cannot reproduce itself over identical inputs, so no "
            + "comparison against it can gate")
        return lines + uncontrolledSeamLines
    }

    /// Each varying payload field named, with the injection that controls it.
    private var uncontrolledSeamLines: [String] {
        guard let seams = stability.uncontrolledSeams, !seams.isEmpty else {
            return []
        }
        return ["  uncontrolled seams — values the subject makes up itself:"]
            + seams.map { "    \($0.summary)" }
    }

    /// Returns the same verdict, carrying what repetition showed. Everything else is run 1's — the
    /// representative pass whose diff, coverage, and counterexample the artifact keeps.
    ///
    /// - Parameter stability: How the replay passes agreed.
    /// - Returns: A copy of this verdict carrying `stability`, any earlier stability replaced.
    func qualified(by stability: Stability) -> SpecVerdict {
        var verdict = self
        verdict.stability = stability
        return verdict
    }
}

extension Stability {
    /// Returns the stability of replay passes over identical inputs, naming the uncontrolled seams
    /// when they disagreed.
    ///
    /// - Parameter passes: Each pass's verdict, in pass order; non-empty.
    /// - Returns: The passes grouped into distinct outcomes by verdict and full inventory, in
    ///   first-seen order so run 1, the carried representative, leads.
    static func measured(over passes: [SpecVerdict]) -> Stability {
        var outcomes: [Outcome] = []
        for (index, pass) in passes.enumerated() {
            let inventory = pass.diff.divergences.map(\.stabilityFingerprint)
            if let position = outcomes.firstIndex(where: {
                $0.verdict == pass.result.verdict && $0.inventory == inventory
            }) {
                outcomes[position].runs.append(index + 1)
            } else {
                outcomes.append(Outcome(runs: [index + 1], verdict: pass.result.verdict, inventory: inventory))
            }
        }
        guard outcomes.count > 1 else {
            return Stability(replays: passes.count, outcomes: outcomes)
        }
        let seams = UncontrolledSeam.found(across: passes.map(\.diff.divergences))
        return Stability(
            replays: passes.count,
            outcomes: outcomes,
            uncontrolledSeams: seams.isEmpty ? nil : seams
        )
    }
}
