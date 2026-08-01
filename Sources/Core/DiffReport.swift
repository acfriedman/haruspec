import Foundation

public extension TraceDiff {
    /// A compact, human-readable rendering of the verdict — what the CLI and CI logs print.
    func report() -> String {
        ([bannerLine] + bodyLines()).joined(separator: "\n")
    }

    /// The verdict + trace-name headline. `VerificationResult` renders its own (coverage-aware) banner
    /// instead, but reuses `bodyLines()`.
    var bannerLine: String {
        "\(TraceDiff.banner(verdict))  \(baselineName) → \(candidateName)"
    }

    /// The three-tier banner glyph + label.
    static func banner(_ verdict: Verdict) -> String {
        switch verdict {
        case .equivalent: "✅ EQUIVALENT"
        case .diverged: "❌ DIVERGED"
        case .cannotVerify: "⚠️ CANNOT-VERIFY"
        }
    }

    /// The divergence summary + per-divergence lines (no banner), so `VerificationResult.report()` can
    /// prepend a coverage-aware headline and reuse this body verbatim.
    func bodyLines() -> [String] {
        guard !divergences.isEmpty else {
            return ["  behavior trace matches within declared tolerances (0 divergences)"]
        }

        var lines: [String] = []
        let intended = intendedCount
        let advisory = divergences.filter(\.isAdvisory).count

        // Enrich the summary with the intended/collateral split only when intent is in play, so
        // parity-mode output stays identical to before.
        if intended > 0 {
            var parts: [String] = []
            if collateralCount > 0 {
                parts.append("\(collateralCount) collateral")
            }
            parts.append("\(intended) intended")
            if advisory > 0 {
                parts.append("\(advisory) advisory")
            }
            lines.append("  \(divergences.count) divergence(s) — \(parts.joined(separator: ", ")):")
        } else {
            let suffix = advisory > 0 ? " (\(advisory) advisory)" : ""
            lines.append("  \(divergences.count) divergence(s)\(suffix):")
        }

        for divergence in divergences {
            let location = "[b:\(divergence.baselineSeq.map(String.init) ?? "–") "
                + "c:\(divergence.candidateSeq.map(String.init) ?? "–")]"
            let tag: String = switch divergence.classification {
            case .intended: " (intended)"
            case .collateral: divergence.isAdvisory ? " (advisory)" : (intended > 0 ? " (collateral)" : "")
            }
            lines.append(
                "    \(glyph(divergence.kind)) \(divergence.kind.rawValue) \(location) \(divergence.label)\(tag)"
            )
            lines.append("        \(divergence.detail)")
        }
        return lines
    }

    /// A prompt-injected relay guide for a consuming agent (printed behind `--agent`). Until an MCP
    /// wrapper exists the CLI *is* the interface, so the output itself teaches the agent how to
    /// communicate this ground-truth verdict to a human. Not meant for human eyes.
    func agentBrief() -> String {
        let gate = verdict == .equivalent ? "PASS" : "FAIL"
        let mergeGuard = collateralCount > 0
            ? "\n• Do not merge until the user confirms each collateral change is acceptable."
            : ""
        return """
        ── FOR THE AGENT · how to relay this verdict ──
        This is a deterministic behavioral-diff verdict from the oracle: ground truth from re-running
        the code against a recorded baseline, not a plausibility guess. Relay it to the user like this:
        • Gate: \(gate).  (process exit code: 0 = PASS, 3 = FAIL.)
        • Intended changes: \(intendedCount). Declared in the intent spec and expected — mention them as
          confirmations that the feature's new behavior is present; do NOT flag them as problems.
        • Collateral changes: \(collateralCount). NOT declared. Treat each as a suspected regression:
          state WHAT changed and WHERE (label + detail), and ask the user whether it was intended.
        • Claim only that observable behavior did or did not change vs. the baseline within declared
          tolerances — never that the code is "correct."\(mergeGuard)
        """
    }

    /// Machine-readable form for tooling / MCP callers.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private func glyph(_ kind: Divergence.Kind) -> String {
        switch kind {
        case .missingEvent: "−"
        case .unexpectedEvent: "+"
        case .reordered: "↔"
        case .valueMismatch: "≠"
        case .timingRegression: "⏱"
        }
    }
}
