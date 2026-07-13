import Foundation
import OracleCore

// The scenario-level visual report — the counterexample-hero wrapper around the shared divergence body.
// Mirrors how `ScenarioVerdict.report()` (in ScenarioRunner.swift) wraps `TraceDiff`'s text body: this
// wraps `OracleHTML`'s page skeleton + divergence cards with the stat row and the minimal-counterexample
// hero that only a scenario run can produce (orderings explored, failing order, varied seam values).
//
// TODO (stretch — richest view): a full side-by-side *event timeline* of the baseline vs candidate traces
// with divergent rows highlighted. Blocked on Oracle exposing the two underlying `Trace`s on
// `ScenarioVerdict` (only `diff.divergences` is public today). To do it, add the pair of traces to the
// verdict, then render a `timelineSection(baseline:candidate:)` in `OracleHTML` next to `divergenceSection`.

extension ScenarioVerdict: HTMLReporting {}

public extension ScenarioVerdict {
    /// A self-contained, themeable HTML rendering of the scenario verdict — the visual companion to
    /// `report()`. Leads with the shrunk counterexample, then one card per divergence (or a clean panel).
    func htmlReport() -> String {
        let name = diff.candidateName
        var tiles = [
            OracleHTML.tile(label: "Verdict", value: OracleHTML.shortVerdict(verdict), accent: OracleHTML.accent(verdict)),
            OracleHTML.tile(label: "Orderings explored", value: "\(orderingsExplored)"),
            OracleHTML.tile(label: "Divergences", value: "\(diff.divergences.count)",
                            accent: diff.divergences.isEmpty ? "ok" : "bad"),
        ]
        let seams = counterexampleSeamPairs
        if !seams.isEmpty {
            tiles.append(OracleHTML.tile(label: "Counterexample",
                                         value: seams.map { "\($0.key)=\($0.value)" }.joined(separator: " · "),
                                         mono: true))
        }

        let body: String = diff.divergences.isEmpty
            ? cleanPanel
            : OracleHTML.divergenceSection(diff.divergences)

        return OracleHTML.page(title: "Oracle · \(name)", sections: [
            OracleHTML.hero(verdict, title: name, baseline: diff.baselineName, candidate: name),
            OracleHTML.statSection(tiles),
            OracleHTML.counterexampleSection(seams: seams, order: failingOrder),
            body,
        ])
    }

    private var cleanPanel: String {
        let plural = orderingsExplored == 1 ? "" : "s"
        if verdict == .cannotVerify {
            return OracleHTML.abstentionSection(reason: "The oracle could not faithfully isolate this change.")
        }
        return OracleHTML.cleanSection(
            summary: "Behavior matched across everything explored",
            detail: "All \(orderingsExplored) call ordering\(plural) — and every generated seam value — produced "
                + "a byte-for-byte identical behavior trace (within declared tolerances). No divergences.")
    }
}
