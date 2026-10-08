import Foundation
import HaruspecCore

// The PR-surface rendering — the GitHub-flavored sibling of `report()` (terminal) and `htmlReport()`
// (visual). `haruspec report --markdown` pipes it into a PR comment or job summary. Deliberately
// app-agnostic: no "reproduce locally" command block lives here — the consuming workflow appends its
// own, because only it knows the checkout layout and env-var plumbing that produced the artifact.

/// Divergence tables stop here; the full list lives in the HTML report artifact. A PR comment that
/// scrolls past twenty rows has stopped being a verdict and become a log.
let divergenceRowCap = 20

public extension SpecVerdict {
    /// GitHub-flavored markdown rendering of the verdict, for PR comments and CI job summaries.
    /// Same verdict vocabulary as `report()`; coverage is rendered only on verdicts whose replay
    /// swept the whole surface (a DIVERGED run stopped at the first non-equivalent probe, so its
    /// coverage numbers describe one replay and would mislead next to an EQUIVALENT's).
    func markdownReport() -> String {
        var sections = [headline]
        // Dead declarations lead, before the verdict body: on an otherwise-green run they are the
        // entire reason the gate fails (exit 6), and burying them under a ✅ body would read as a pass.
        sections.append(contentsOf: unobservedIntentSection)
        switch verdict {
        case .equivalent:
            sections.append(contentsOf: equivalentBody)
        case .diverged:
            sections.append(contentsOf: divergedBody)
        case .cannotVerify:
            sections.append(contentsOf: abstentionBody)
        case .unstable:
            sections.append(contentsOf: unstableBody)
        }
        // On every verdict, deliberately — a green states its blind spots, a red or an abstention
        // states the surface it was measured over. The disclaimer, rendered rather than linked.
        sections.append(qualificationBlock)
        sections.append(footer)
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Sections

    var headline: String {
        // On replay both traces carry the spec name; only render an arrow when they differ.
        let subject = diff.baselineName == diff.candidateName
            ? "`\(diff.baselineName)`"
            : "`\(diff.baselineName)` → `\(diff.candidateName)`"
        // An extension-mode green gets a visibly different banner: it passed *because* intent
        // absorbed divergences, and a reader must never mistake it for parity.
        let mode = verdict == .equivalent && diff.intendedCount > 0 ? " · declared intent absorbed" : ""
        return "### \(TraceDiff.banner(verdict))\(mode) — \(subject)"
    }

    private var equivalentBody: [String] {
        // "all N orderings" only when the sweep was exhaustive: a sampled run that says "all" is
        // claiming a surface it never walked.
        let scope = exploration.isExhaustive
            ? "all \(exploration.orderingsExplored)"
            : "\(exploration.orderingsExplored) of "
            + "\(exploration.orderingsAreExact ? "" : "≥")\(exploration.orderingsAvailable)"
        let plural = orderingsExplored == 1 ? "" : "s"
        var sections: [String] = []
        // Extension mode passes WITH disclosure: the intended table leads, so what was absorbed is
        // on the comment, not behind it.
        let intended = diff.divergences.filter { $0.classification == .intended }
        if !intended.isEmpty {
            sections.append(
                "This PR **diverges as declared**: \(intended.count) intended "
                    + "divergence\(intended.count == 1 ? "" : "s") absorbed by the declared intent, "
                    + "no collateral divergence."
            )
            sections.append(
                "**Intended — declared in the intent spec; reported, not gating:**\n\n"
                    + divergenceTable(intended)
            )
            sections.append(contentsOf: observationsSection)
        }
        var lines = ["\(intended.isEmpty ? "Behavior" : "Everything else") matched across everything "
            + "explored — \(scope) call ordering\(plural) and every recorded seam variant replayed "
            + "to traces identical to the goldens, within the declared comparison."]
        if let coverageLine {
            lines.append("")
            lines.append(coverageLine)
        }
        sections.append(lines.joined(separator: "\n"))
        return sections
    }

    /// The dead-declaration block: declared intent the whole sweep never observed. Rendered on any
    /// verdict that carries one (the diverged paths clear the claim by construction).
    var unobservedIntentSection: [String] {
        let unobserved = diff.unobservedIntent
        guard !unobserved.isEmpty else {
            return []
        }
        let plural = unobserved.count == 1 ? "" : "s"
        return ["""
        **⚠️ Declared but not observed — this check does not pass (exit 6).** The replay swept the \
        whole recorded surface and never saw the change\(plural) declared below: a dark feature, or \
        stale intent — and either way a standing excuse that would silently absorb a future \
        divergence. Remove the declaration\(plural) from the PR description, or make this PR \
        actually produce the change\(plural):

        \(unobserved.map { "- `\($0)`" }.joined(separator: "\n"))
        """]
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
        sections.append(contentsOf: failingCasesSection)
        sections.append(contentsOf: observationsSection)
        sections.append(contentsOf: rejectedDeclarationsSection(for: failingCases?.gatingDivergences ?? gating))
        sections.append(contentsOf: declarationOffer)
        return sections
    }

    /// The author's own tripwires that fired: each declaration that named a gating divergence's
    /// kind and label but rejected it, with how many divergences it rejected and the first one.
    ///
    /// Rendered before the offer, which leaves these divergences out — the only line that would
    /// absorb them is wider than the one the author wrote, so the choice is theirs, not the report's.
    private func rejectedDeclarationsSection(for gating: [Divergence]) -> [String] {
        var order: [String] = []
        var rejected: [String: [Divergence]] = [:]
        for divergence in gating {
            for declaration in divergence.rejectedBy {
                if rejected[declaration] == nil {
                    order.append(declaration)
                }
                rejected[declaration, default: []].append(divergence)
            }
        }
        guard !order.isEmpty else {
            return []
        }
        let lines = order.map { declaration -> String in
            let cases = rejected[declaration] ?? []
            let first = cases[0]
            let count = cases.count == 1 ? "1 divergence" : "\(cases.count) divergences"
            return "- `\(tableCell(declaration))` rejected \(count) — "
                + "`\(tableCell(first.label))`\(opCell(first)): \(tableCell(first.detail))"
        }
        return ["""
        **Declared, but not as observed** — these declarations name the change, but their modifier \
        rejected what actually happened. That is the tripwire doing its job: fix the code, or widen \
        the declaration on purpose. No wider line is offered for these.

        \(lines.joined(separator: "\n"))
        """]
    }

    /// How many failing cases the red rests on, and what the others found beyond the reported one.
    private var failingCasesSection: [String] {
        guard let failingCases, failingCases.probes.count > 1 else {
            return []
        }
        let count = failingCases.probes.count
        let others = failingCases.unreported(beside: diff.divergences)
            .map { "- `\($0.label)`: \(tableCell($0.detail))" }
        return ["**\(count) failing cases** among the \(failingCases.walkedAfterFirst + 1) checked from the "
            + "first failure on. The tables above show the most informative one; the offer below is "
            + "derived from all \(count)."]
            + (others.isEmpty ? [] : [(["**Also in other failing cases:**", ""] + others).joined(separator: "\n")])
    }

    /// Per declaration, the divergence it was first seen to absorb and the case that produced it —
    /// so a green-by-declaration verdict shows *what* each declaration excused. The first absorbing
    /// probe alone is not enough: it is often the golden, whose values say nothing.
    var observationsSection: [String] {
        guard !intentObservations.isEmpty else {
            return []
        }
        var lines = [
            "**Declared changes, as first observed:**",
            "",
            "| Declaration | Where | Detail | In the case |",
            "|---|---|---|---|"
        ]
        for observation in intentObservations.prefix(divergenceRowCap) {
            let inputs = observation.inputs.tracks.keys.sorted().map { key in
                "\(key)=\((observation.inputs.tracks[key] ?? []).map(\.canonicalString).joined(separator: ","))"
            }
            lines.append(
                "| `\(tableCell(observation.declaration))` "
                    + "| `\(tableCell(observation.divergence.label))`\(opCell(observation.divergence)) "
                    + "| \(tableCell(observation.divergence.detail)) "
                    + "| \(tableCell(inputs.joined(separator: " · "))) |"
            )
        }
        return [lines.joined(separator: "\n")]
    }

    /// The teaching half of the red gate: the exact declarations that would mark the collateral
    /// divergences intended, as a block the author pastes into the PR description.
    ///
    /// The whole intent-signaling loop in one copy-paste — but offered, never presumed: the
    /// sentence around it says when pasting is the wrong move.
    private var declarationOffer: [String] {
        let suggestions = offeredDeclarations
        guard !suggestions.isEmpty else {
            return []
        }
        // A modifier is as narrow as the failing cases allow: one case pins `.to(…)`, several prove
        // a direction or a range. The author widens it only on purpose.
        let narrowing = suggestions.contains { $0.contains(").") }
            ? " Each modifier is the narrowest the failing cases support — `.to(…)` when every case "
            + "showed one value, a direction or a range when they differed; widen one only if the "
            + "change is broader than what was seen — every modifier you keep is a tripwire for the "
            + "values it excludes."
            : ""
        // The four-backtick fence renders the inner block literally, ready to copy.
        return ["""
        <details><summary>Is this change the point of the PR?</summary>

        If these divergences are the intended behavior change, declare them: paste this block into \
        the PR description (edit it down to what is genuinely intended) and the check re-runs in \
        extension mode — declared divergences are disclosed instead of gating, and anything \
        undeclared still fails. If you did not mean to change behavior, this is a regression: fix \
        the code, don't declare it.\(narrowing)

        ````
        ```\(IntentGrammar.fenceLabel) \(diff.baselineName)
        \(suggestions.joined(separator: "\n"))
        ```
        ````

        </details>
        """]
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
        let explored = exploration.isExhaustive
            ? "\(orderingsExplored) (exhaustive)"
            : "\(orderingsExplored) of \(exploration.orderingsAreExact ? "" : "≥")\(exploration.orderingsAvailable)"
        var parts = ["Haruspec continuous verification", "orderings explored: \(explored)"]
        if stability.replays > 1, stability.isStable {
            parts.append("stability: \(stability.replays)/\(stability.replays) identical replays")
        }
        if verdict != .diverged, let coverageSummary = coverageFooterSummary {
            parts.append(coverageSummary)
        }
        return "<sub>\(parts.joined(separator: " · "))</sub>"
    }

    /// The qualification block: what this verdict rests on, one aligned line per axis. Fenced as
    /// text so the sticky comment renders it as the fixed-width block a reader scans, not five
    /// paragraphs of prose.
    var qualificationBlock: String {
        let entries = qualificationEntries
        let width = (entries.map(\.label.count).max() ?? 0) + 1
        let lines = entries.map { entry in
            "\(entry.label):".padding(toLength: width + 2, withPad: " ", startingAt: 0) + entry.value
        }
        return "**What this verdict rests on:**\n\n```text\n" + lines.joined(separator: "\n") + "\n```"
    }

    // MARK: - Rendering helpers

    /// ` in checkout (op 7)` after a Where cell's label, or nothing for an event under no op.
    private func opCell(_ divergence: Divergence) -> String {
        divergence.op.map { " in \(tableCell($0.description))" } ?? ""
    }

    func divergenceTable(_ divergences: [Divergence]) -> String {
        var lines = ["| Kind | Where | Detail |", "|---|---|---|"]
        for divergence in divergences.prefix(divergenceRowCap) {
            let advisory = divergence.isAdvisory ? " (advisory)" : ""
            lines.append(
                "| `\(divergence.kind.rawValue)`\(advisory) "
                    + "| `\(tableCell(divergence.label))`\(opCell(divergence)) "
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

    /// Keeps engine-produced text from breaking the table grammar: pipes escape, newlines flatten.
    func tableCell(_ text: String) -> String {
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
