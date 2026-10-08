import Foundation

public extension VerificationResult {
    /// A compact, human-readable rendering of the resolved verdict + coverage — what the CLI and CI
    /// logs print for a replay-driven verification. Reuses `TraceDiff.bodyLines()` for the divergence
    /// list so the two report paths stay consistent.
    func report() -> String {
        var lines = ["\(TraceDiff.banner(verdict))  \(diff.baselineName) → \(diff.candidateName)"]
        lines += coverageLines()
        if verdict == .cannotVerify {
            lines += abstentionLines()
        }
        lines += diff.bodyLines()
        return lines.joined(separator: "\n")
    }

    /// A prompt-injected relay guide for a consuming agent (printed behind `--agent`). Teaches the agent
    /// to relay `CANNOT-VERIFY` as an *abstention* — never a pass — which is the whole point of the
    /// third tier: the oracle refuses to confirm parity it couldn't isolate.
    func agentBrief() -> String {
        let gate = switch verdict {
        case .equivalent: "PASS"
        case .diverged: "FAIL"
        case .cannotVerify: "ABSTAIN"
        // A `VerificationResult` is one pass and never resolves `.unstable` itself (that takes
        // repetition, `SpecVerdict`'s layer) — but the vocabulary is shared, so relay it faithfully.
        case .unstable: "UNSTABLE"
        }

        var lines = [
            "── FOR THE AGENT · how to relay this verdict ──",
            "This is a deterministic behavioral-diff verdict from the oracle: ground truth from re-running",
            "the code against a recorded baseline, not a plausibility guess. Relay it to the user like this:",
            "• Gate: \(gate).  (process exit code: 0 = PASS, 3 = FAIL, 4 = ABSTAIN, 5 = UNSTABLE.)",
            "• Coverage: \(coverageSummary). EQUIVALENT is only as strong as this number — say it out loud."
        ]

        if verdict == .cannotVerify {
            lines.append(contentsOf: [
                "• ABSTAIN means the oracle could NOT faithfully isolate this change. Do NOT report it as a",
                "  pass or a behavioral-parity confirmation. State plainly that verification was inconclusive",
                "  \(abstentionReason), and that re-recording the cassette (or declaring the seam) is required",
                "  before a real verdict is possible."
            ])
        } else {
            lines.append(contentsOf: [
                "• Intended changes: \(diff.intendedCount). Declared in the intent spec and expected — mention them",
                "  as confirmations of the feature; do NOT flag them as problems.",
                "• Collateral changes: \(diff.collateralCount). NOT declared. Treat each as a suspected regression:",
                "  state WHAT changed and WHERE (label + detail), and ask the user whether it was intended.",
                "• Claim only that observable behavior did or did not change vs. the baseline within declared",
                "  comparison and over the covered surface — never that the code is \"correct.\""
            ])
            if diff.collateralCount > 0 {
                lines.append("• Do not merge until the user confirms each collateral change is acceptable.")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Machine-readable form for tooling / MCP callers: the diff, the coverage, and the resolved verdict.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: - Rendering helpers

    private func coverageLines() -> [String] {
        guard let fraction = coverage.fraction else {
            return ["  coverage: unknown — no declared seam surface to measure against"]
        }
        var lines = ["  coverage: \(coverage.exercised.count)/\(coverage.declared.count) "
            + "declared seams exercised (\(percent(fraction)))"]
        if let domain = coverage.domainFraction, !coverage.domainExercised.isEmpty {
            lines.append("  domain: \(coverage.domainExercised.count)/\(coverage.declared.count) seam(s) "
                + "swept over a value domain via property gen (\(percent(domain)))")
        }

        let missed = coverage.unrecordedReach
        if !missed.isEmpty {
            let list = missed.map { "\($0.boundary)#\($0.ordinal ?? 0)" }.joined(separator: ", ")
            lines.append("  gap: reached \(missed.count) unrecorded boundary(ies), fell back to live — \(list)")
        }
        let unexercised = coverage.gaps.filter { $0.reason == .unexercised }
        if !unexercised.isEmpty {
            let list = unexercised.map(\.boundary).joined(separator: ", ")
            lines.append("  gap: \(unexercised.count) declared boundary(ies) never reached this run — \(list)")
        }
        return lines
    }

    private func abstentionLines() -> [String] {
        ["  abstaining: verification was inconclusive \(abstentionReason). An EQUIVALENT here would be",
         "  unsound, so the oracle refuses it. Re-record the cassette (or declare the seam) to close the gap."]
    }

    /// Reason phrasing shared by the human report and the agent brief.
    private var abstentionReason: String {
        coverage.unrecordedReach.isEmpty
            ? "because there is no declared seam surface to certify equivalence over"
            : "because the change crossed a boundary the recording didn't cover, "
            + "so the environment wasn't held identical"
    }

    private var coverageSummary: String {
        guard let fraction = coverage.fraction else { return "unknown (no declared seam surface)" }
        return "\(coverage.exercised.count)/\(coverage.declared.count) declared seams (\(percent(fraction)))"
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
