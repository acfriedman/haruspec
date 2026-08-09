import Foundation
import HaruspecCore

// The spec-level visual report — the counterexample-hero wrapper around the shared divergence body.
// Mirrors how `SpecVerdict.report()` (in SpecRunner.swift) wraps `TraceDiff`'s text body: this
// wraps `HTML`'s page skeleton + divergence cards with the stat row and the minimal-counterexample
// hero that only a spec run can produce (orderings explored, failing order, varied seam values).
//
// TODO: (stretch — richest view): a full side-by-side *event timeline* of the baseline vs candidate traces
// with divergent rows highlighted. Blocked on Haruspec exposing the two underlying `Trace`s on
// `SpecVerdict` (only `diff.divergences` is public today). To do it, add the pair of traces to the
// verdict, then render a `timelineSection(baseline:candidate:)` in `HTML` next to `divergenceSection`.

extension SpecVerdict: HTMLReporting {}

public extension SpecVerdict {
    /// A self-contained, themeable HTML rendering of the spec verdict — the visual companion to
    /// `report()`. Leads with the shrunk counterexample, then one card per divergence (or a clean panel).
    func htmlReport() -> String {
        let name = diff.candidateName
        var tiles = [
            HTML.tile(label: "Verdict", value: HTML.shortVerdict(verdict), accent: HTML.accent(verdict)),
            HTML.tile(
                label: "Orderings explored",
                value: exploration.isExhaustive
                    ? "\(orderingsExplored)"
                    : "\(orderingsExplored)/\(exploration.orderingsAreExact ? "" : "≥")"
                    + "\(exploration.orderingsAvailable)"
            ),
            HTML.tile(
                label: "Divergences",
                value: "\(diff.divergences.count)",
                accent: diff.divergences.isEmpty ? "ok" : "bad"
            )
        ]
        if let fraction = coverage.fraction {
            tiles.append(
                HTML.tile(
                    label: "Coverage",
                    value: "\(Int((fraction * 100).rounded()))% of \(coverage.declared.count)",
                    accent: coverage.unrecordedReach.isEmpty ? "ok" : "bad"
                )
            )
        }
        let seams = counterexampleSeamPairs
        if !seams.isEmpty {
            tiles.append(
                HTML.tile(
                    label: "Counterexample",
                    value: seams.map { "\($0.key)=\($0.value)" }.joined(separator: " · "),
                    mono: true
                )
            )
        }

        let body: String = diff.divergences.isEmpty
            ? cleanPanel
            : HTML.divergenceSection(diff.divergences)

        return HTML.page(title: "Haruspec · \(name)", sections: [
            HTML.hero(verdict, title: name, baseline: diff.baselineName, candidate: name),
            HTML.statSection(tiles),
            HTML.counterexampleSection(seams: seams, order: failingOrder),
            body
        ])
    }

    private var cleanPanel: String {
        let plural = orderingsExplored == 1 ? "" : "s"
        if verdict == .cannotVerify {
            return HTML.abstentionSection(reason: "The oracle could not faithfully isolate this change.")
        }
        let scope = exploration.isExhaustive ? "All \(orderingsExplored)" : "\(orderingsExplored) sampled"
        return HTML.cleanSection(
            summary: "Behavior matched across everything explored",
            detail: "\(scope) call ordering\(plural) — and every generated seam value — produced "
                + "a byte-for-byte identical behavior trace (within declared tolerances). No divergences."
        )
    }
}
