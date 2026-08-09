import Foundation
import HaruspecCore

// Replay repetition — the trust layer above coverage. `verify(replaying:)` replays the plan more than
// once and requires every pass to reach the *same* verdict with the *same* divergence inventory. Two
// passes over identical recorded inputs have no legitimate reason to disagree, so a disagreement is
// proof of an unmodeled nondeterministic axis (a missing tolerance, projection, or seam) — exactly the
// failure that once made the parallel subject report a different counterexample every run. The delta
// between the disagreeing passes is not noise to suppress; it is the report's pointer to which axis
// is unmodeled.

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

    public init(replays: Int, outcomes: [Outcome]) {
        self.replays = replays
        self.outcomes = outcomes
    }

    /// A single pass, or every pass agreeing. `verify(replaying:)` flips the verdict to `.unstable`
    /// exactly when this is false.
    public var isStable: Bool {
        outcomes.count <= 1
    }

    /// The unmeasured placeholder for verdicts that never repeat a run (the live differential, a
    /// single-pass replay). Renders as "single run", never as a reproduction claim.
    public static let singleRun = Stability(replays: 1, outcomes: [])

    /// Replay passes per `verify(replaying:)`. More than one by default: a verdict that has never
    /// been reproduced is a verdict on faith, and the replay leg is the cheap side of the pipeline.
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
    /// The stability line every measured replay carries in `report()` — and, on disagreement, the
    /// run-to-run delta: each distinct outcome with the passes that produced it. The delta is the
    /// diagnostic (it names the unmodeled axis), so it renders in full rather than as a count.
    var stabilityLines: [String] {
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
            + "(a missing tolerance, projection, or seam); the delta above points at it")
        return lines
    }

    /// The same verdict, carrying what repetition showed. Everything else is run 1's — the
    /// representative pass whose diff, coverage, and counterexample the artifact keeps.
    func qualified(by stability: Stability) -> SpecVerdict {
        SpecVerdict(
            result: result,
            orderingsExplored: orderingsExplored,
            failingOrder: failingOrder,
            counterexample: counterexample,
            exploration: exploration,
            violatedPreconditions: violatedPreconditions,
            stability: stability
        )
    }
}

extension Stability {
    /// Fold N single-pass verdicts into their distinct outcomes. Grouping is by resolved verdict +
    /// full inventory; first-seen order keeps run 1 first so the carried representative matches.
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
        return Stability(replays: passes.count, outcomes: outcomes)
    }
}
