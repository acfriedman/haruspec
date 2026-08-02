import Foundation
import HaruspecCore

// The PR-surface rendering — the GitHub-flavored sibling of `report()` (terminal) and `htmlReport()`
// (visual). `haruspec report --markdown` pipes it into a PR comment or job summary. Deliberately
// app-agnostic: no "reproduce locally" command block lives here — the consuming workflow appends its
// own, because only it knows the checkout layout and env-var plumbing that produced the artifact.

/// Divergence tables stop here; the full list lives in the HTML report artifact. A PR comment that
/// scrolls past twenty rows has stopped being a verdict and become a log.
private let divergenceRowCap = 20

public extension SpecVerdict {
    /// GitHub-flavored markdown rendering of the verdict, for PR comments and CI job summaries.
    /// Same three-tier vocabulary as `report()`; coverage is rendered only on verdicts whose replay
    /// swept the whole surface (a DIVERGED run stopped at the first non-equivalent probe, so its
    /// coverage numbers describe one replay and would mislead next to an EQUIVALENT's).
    func markdownReport() -> String {
        var sections = [headline]
        switch verdict {
        case .equivalent:
            sections.append(equivalentBody)
        case .diverged:
            sections.append(contentsOf: divergedBody)
        case .cannotVerify:
            sections.append(contentsOf: abstentionBody)
        }
        sections.append(footer)
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Sections

    private var headline: String {
        // On replay both traces carry the spec name; only render an arrow when they differ.
        let subject = diff.baselineName == diff.candidateName
            ? "`\(diff.baselineName)`"
            : "`\(diff.baselineName)` → `\(diff.candidateName)`"
        return "### \(TraceDiff.banner(verdict)) — \(subject)"
    }

    private var equivalentBody: String {
        let plural = orderingsExplored == 1 ? "" : "s"
        var lines = ["Behavior matched across everything explored — all \(orderingsExplored) "
            + "call ordering\(plural) and every recorded seam variant replayed to traces identical "
            + "to the goldens, within declared tolerances."]
        if let coverageLine {
            lines.append("")
            lines.append(coverageLine)
        }
        return lines.joined(separator: "\n")
    }

    private var divergedBody: [String] {
        var sections = [divergenceSummary]

        let gating = diff.divergences.filter { $0.classification == .collateral }
        let intended = diff.divergences.filter { $0.classification == .intended }
        if intended.isEmpty {
            sections.append(divergenceTable(gating))
        } else {
            sections.append("**Collateral — undeclared, gating:**\n\n" + divergenceTable(gating))
            sections.append(
                "**Intended — declared in the intent spec; reported, not gating:**\n\n"
                    + divergenceTable(intended)
            )
        }

        if let failing = failingOrder {
            sections.append(
                "**Exposing order** (the recorded ordering that exposed it — not shrunk): "
                    + failing.map { "`\($0)`" }.joined(separator: " → ")
            )
        }
        let seams = counterexampleSeamPairs
        if !seams.isEmpty {
            sections.append(
                "**Counterexample:** " + seams.map { "`\($0.key)=\($0.value)`" }.joined(separator: " · ")
            )
        }
        return sections
    }

    private var divergenceSummary: String {
        let count = diff.divergences.count
        let plural = count == 1 ? "" : "s"
        var summary = "Replaying the recorded plan against this build surfaced **\(count) "
            + "divergence\(plural)** from the golden traces."
        if diff.intendedCount > 0 {
            summary += " \(diff.collateralCount) collateral (gating), \(diff.intendedCount) intended."
        }
        return summary
    }

    private var abstentionBody: [String] {
        let unrecorded = coverage.unrecordedReach
        let opGaps = unrecorded.filter { $0.boundary.hasPrefix("op:") }
        let seamGaps = unrecorded.filter { !$0.boundary.hasPrefix("op:") }

        var sections: [String] = []
        if !opGaps.isEmpty {
            let labels = opGaps.map { "`\($0.boundary)`" }.joined(separator: ", ")
            sections.append(
                "The plan records operations this build no longer declares: \(labels). Recorded input "
                    + "for a renamed or removed operation cannot be replayed faithfully — re-record the "
                    + "plan on the base branch to re-pin the surface."
            )
        }
        if !seamGaps.isEmpty {
            let labels = seamGaps.map { "`\($0.boundary)`" }.joined(separator: ", ")
            sections.append(
                "The code under verification read seams past the recording: \(labels). Replay fell "
                    + "back to live values there, so the environment was not held identical across the "
                    + "two builds."
            )
        }
        if sections.isEmpty {
            sections.append("The oracle could not faithfully isolate this change.")
        }
        sections.append(
            "An `EQUIVALENT` here would be unsound; the oracle abstains — **this check does not pass.**"
        )
        return sections
    }

    private var footer: String {
        var parts = ["Haruspec continuous verification", "orderings explored: \(orderingsExplored)"]
        if verdict != .diverged, let coverageSummary = coverageFooterSummary {
            parts.append(coverageSummary)
        }
        return "<sub>\(parts.joined(separator: " · "))</sub>"
    }

    // MARK: - Rendering helpers

    private func divergenceTable(_ divergences: [Divergence]) -> String {
        var lines = ["| Kind | Where | Detail |", "|---|---|---|"]
        for divergence in divergences.prefix(divergenceRowCap) {
            let advisory = divergence.isAdvisory ? " (advisory)" : ""
            lines.append(
                "| `\(divergence.kind.rawValue)`\(advisory) "
                    + "| `\(tableCell(divergence.label))` "
                    + "| \(tableCell(divergence.detail)) |"
            )
        }
        if divergences.count > divergenceRowCap {
            let hidden = divergences.count - divergenceRowCap
            lines.append("")
            lines.append("…and \(hidden) more — the full list is in the HTML report artifact.")
        }
        return lines.joined(separator: "\n")
    }

    /// Keep engine-produced text from breaking the table grammar: pipes escape, newlines flatten.
    private func tableCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " · ")
    }

    private var coverageLine: String? {
        guard let fraction = coverage.fraction else { return nil }
        var line = "**Coverage:** \(percent(fraction)) of \(coverage.declared.count) declared boundaries"
        if let domain = coverage.domainFraction, domain > 0 {
            line += " · domain-swept \(percent(domain))"
        }
        return line
    }

    private var coverageFooterSummary: String? {
        guard let fraction = coverage.fraction else { return nil }
        return "coverage: \(percent(fraction)) of \(coverage.declared.count) boundaries"
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
