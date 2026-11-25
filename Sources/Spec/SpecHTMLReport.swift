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
    /// ``report()``. Leads with the shrunk counterexample, then one card per divergence (or a clean panel).
    ///
    /// - Returns: A complete HTML document, its styles inline, that opens on its own over `file://`.
    func htmlReport() -> String {
        let name = diff.candidateName
        // On UNSTABLE the delta panel leads regardless of run 1's own divergences — a flapping green
        // has none, and a flapping red's cards describe one pass, not the finding.
        let body: String = if verdict == .unstable {
            unstablePanel + (diff.divergences.isEmpty ? "" : HTML.divergenceSection(diff.divergences))
        } else if diff.divergences.isEmpty {
            cleanPanel
        } else {
            HTML.divergenceSection(diff.divergences) + unreportedFindingSection
        }

        return HTML.page(title: "Haruspec · \(name)", sections: [
            HTML.hero(verdict, title: name, baseline: diff.baselineName, candidate: name),
            HTML.statSection(statTiles),
            // Right under the stats, on every verdict: the stats say what was found, this says what
            // the finding was measured over — the disclaimer, rendered.
            HTML.qualificationSection(qualificationEntries),
            HTML.unobservedIntentSection(diff.unobservedIntent),
            HTML.counterexampleSection(seams: counterexampleSeamPairs, order: failingOrder),
            body
        ])
    }

    /// The run-to-run delta as the leading panel: each distinct outcome with the passes that produced
    /// it. Run 1 may have had no divergences at all (a flapping green) — the finding is the delta.
    private var unstablePanel: String {
        let seams = (stability.uncontrolledSeams ?? []).map(\.summary).joined(separator: " — ")
        let named = seams.isEmpty ? "" : " Uncontrolled seams: \(seams)."
        if let selfCheck = stability.baselineSelfCheck, !selfCheck.isEmpty {
            return HTML.abstentionSection(
                reason: "The baseline, rerun against itself over the failing input, disagreed with "
                    + "itself (\(selfCheck.joined(separator: " ⸱ "))).\(named) A verdict that cannot "
                    + "be reproduced cannot gate."
            )
        }
        let delta = stability.outcomes.map { outcome in
            let runs = outcome.runs.map(String.init).joined(separator: ", ")
            let inventory = outcome.inventory.isEmpty
                ? "no divergences"
                : outcome.inventory.joined(separator: " ⸱ ")
            return "runs \(runs) → \(outcome.verdict.rawValue): \(inventory)"
        }
        .joined(separator: " — ")
        return HTML.abstentionSection(
            reason: "\(stability.replays) replays of identical inputs disagreed (\(delta)).\(named) "
                + "An unmodeled nondeterministic axis; a verdict that cannot be reproduced cannot gate."
        )
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
                + "a byte-for-byte identical behavior trace (within the declared comparison). No divergences."
        )
    }

    /// What other failing cases found that the reported one does not show.
    private var unreportedFindingSection: String {
        guard let failingCases else {
            return ""
        }
        let others = failingCases.unreported(beside: diff.divergences)
        guard !others.isEmpty else {
            return ""
        }
        return HTML.divergenceSection(
            others,
            heading: "Also in other failing cases (\(failingCases.probes.count) failed in all)"
        )
    }

    /// The stat row: verdict, exploration, divergence count, then the qualifiers that only apply when
    /// measured (coverage, stability, counterexample).
    private var statTiles: [String] {
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
        if let selfCheck = stability.baselineSelfCheck {
            tiles.append(
                HTML.tile(
                    label: "Stability",
                    value: selfCheck.isEmpty ? "baseline reproduced" : "baseline disagreed with itself",
                    accent: selfCheck.isEmpty ? "ok" : "warn"
                )
            )
        } else if stability.replays > 1 {
            tiles.append(
                HTML.tile(
                    label: "Stability",
                    value: stability.isStable
                        ? "\(stability.replays)/\(stability.replays) identical"
                        : "\(stability.outcomes.count) outcomes / \(stability.replays) replays",
                    accent: stability.isStable ? "ok" : "warn"
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
        return tiles
    }
}
