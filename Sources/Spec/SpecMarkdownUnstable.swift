import Foundation
import HaruspecCore

extension SpecVerdict {
    /// The unstable body of ``SpecVerdict/markdownReport()``: what disagreed over identical inputs,
    /// the uncontrolled seams it names, and why the check does not pass.
    var unstableBody: [String] {
        if let selfCheck = stability.baselineSelfCheck, !selfCheck.isEmpty {
            var sections = [
                "The sweep went red, so the failing input was rerun with **the baseline on both "
                    + "sides** — and the baseline disagreed with itself. Identical inputs leave that "
                    + "only one explanation: an axis of nondeterminism the spec does not control. The "
                    + "red is noise until it is.",
                (["**Baseline against itself**", ""]
                    + selfCheck.prefix(divergenceRowCap).map { "- \(tableCell($0))" })
                    .joined(separator: "\n")
            ]
            sections += uncontrolledSeamSection
            sections.append("A verdict that cannot be reproduced cannot gate — **this check does not pass.**")
            return sections
        }
        var sections = [
            "The plan was replayed **\(stability.replays) times over identical recorded inputs** and "
                + "the passes disagreed — \(stability.outcomes.count) distinct outcomes. Identical "
                + "inputs leave a disagreement only one explanation: an axis of nondeterminism the "
                + "spec does not model (an uncontrolled seam, or a missing projection). Neither "
                + "outcome below is the verdict; the *difference between them* points at the "
                + "unmodeled axis."
        ]
        for outcome in stability.outcomes {
            let runs = outcome.runs.map(String.init).joined(separator: ", ")
            let noun = outcome.runs.count == 1 ? "Run" : "Runs"
            var lines = ["**\(noun) \(runs) — \(TraceDiff.banner(outcome.verdict))**"]
            if outcome.inventory.isEmpty {
                lines.append("")
                lines.append("No divergences.")
            } else {
                lines.append("")
                lines += outcome.inventory.prefix(divergenceRowCap).map { "- \(tableCell($0))" }
                if outcome.inventory.count > divergenceRowCap {
                    lines.append("- …and \(outcome.inventory.count - divergenceRowCap) more")
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        sections += uncontrolledSeamSection
        sections.append("A verdict that cannot be reproduced cannot gate — **this check does not pass.**")
        return sections
    }

    /// Each varying payload field named, with the injection that controls it — the unstable body's
    /// pointer from the symptom to the fix.
    private var uncontrolledSeamSection: [String] {
        guard let seams = stability.uncontrolledSeams, !seams.isEmpty else {
            return []
        }
        return [
            (["**Uncontrolled seams** — values the subject makes up itself:", ""]
                + seams.map { "- `\($0.label).\($0.field)` (\($0.shape)): \($0.remedy)" })
                .joined(separator: "\n")
        ]
    }
}
