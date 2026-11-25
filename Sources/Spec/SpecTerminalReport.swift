import Foundation
import HaruspecCore

// The terminal rendering of a verdict — the third surface beside `markdownReport()` (the sticky PR
// comment) and `htmlReport()`. All three draw their qualification block from the same
// `qualificationEntries`, so what a reviewer reads in a comment and what a developer reads in a
// console cannot drift apart.

extension SpecVerdict {
    /// Returns a compact rendering built from the diff's public surface (a caller / LLM would print this).
    ///
    /// - Returns: The verdict as multi-line plain text, headed by its banner.
    public func report() -> String {
        var lines = ["\(TraceDiff.banner(verdict))  \(diff.baselineName) → \(diff.candidateName)",
                     "  explored: \(exploration.summary)"]
        lines += stabilityLines
        if let fraction = coverage.fraction {
            var line = "  coverage: \(Int((fraction * 100).rounded()))% "
                + "of \(coverage.declared.count) declared boundaries"
            // Printed at 0 too: a spec that declared domains and swept none of them is exactly the
            // case worth saying out loud, and gating the clause on `> 0` would hide it.
            if let domain = coverage.domainFraction, !coverage.domainExercised.isEmpty || domain == 0 {
                line += " · domain-swept \(Int((domain * 100).rounded()))%"
            }
            lines.append(line)
            for gap in coverage.unrecordedReach {
                lines.append("    ⚠︎ unrecorded reach: \(gap.boundary) (replay fell back to live)")
            }
            for gap in coverage.unmatchedDomains {
                lines.append("    ⚠︎ declared domain matched nothing: \(gap.boundary) (nothing read that seam)")
            }
        }
        lines += qualificationReportLines
        if diff.divergences.isEmpty {
            lines.append("  behavior matches across everything explored (0 divergences)")
        } else {
            let absorbed = verdict == .equivalent && diff.intendedCount > 0
                ? " — all intended, absorbed by declared intent" : ""
            lines.append("  \(diff.divergences.count) divergence(s)\(absorbed):")
            for divergence in diff.divergences {
                let mark = divergence.classification == .intended ? "✓ intended " : "≠ "
                lines.append("    \(mark)\(divergence.label): \(divergence.detail)")
            }
        }
        lines += unreportedFindingLines
        lines += diff.unobservedIntentLines()
        lines += failingOrderLines
        let seams = counterexampleSeamPairs
        if !seams.isEmpty {
            lines.append("  ↳ counterexample: \(seams.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    /// What other failing cases found that the reported one does not show, so one loud bug cannot
    /// hide a quieter one.
    private var unreportedFindingLines: [String] {
        guard let failingCases else {
            return []
        }
        let others = failingCases.unreported(beside: diff.divergences)
        guard !others.isEmpty else {
            return []
        }
        return ["  also in other failing cases (\(failingCases.probes.count) failed in all):"]
            + others.map { "    ≠ \($0.label): \($0.detail)" }
    }

    /// The failing call sequence, and — when it came from the out-of-order stratum — which declared
    /// precondition it broke. Triage differs: a divergence on a path the author said shouldn't happen
    /// is a defensive-code finding, not a regression on the described surface.
    private var failingOrderLines: [String] {
        guard let failing = failingOrder else {
            return []
        }
        var lines = ["  ↳ failing order: \(failing.joined(separator: " → "))"]
        if let violated = violatedPreconditions, !violated.isEmpty {
            lines.append("    ⚠︎ out-of-order: breaks \(violated.joined(separator: ", "))")
        }
        return lines
    }

    /// The counterexample's seam values as `(key, value)` pairs, e.g. `("add.quantity", "1,20")` —
    /// one entry per reading, so a repeatedly-read seam shows which position was extreme. Shared by
    /// ``report()`` and ``htmlReport()`` so the extraction lives in one place.
    ///
    /// Every value type renders, not only integers: a categorical argument (`.oneOf(Catalog.all)`) is
    /// the input a counterexample most needs to name, and dropping it would leave the reader with a
    /// quantity and no SKU.
    var counterexampleSeamPairs: [(key: String, value: String)] {
        guard let tracks = counterexample?.tracks else { return [] }
        let rendered = tracks.compactMapValues { values -> String? in
            values.isEmpty ? nil : values.map(Self.render).joined(separator: ",")
        }
        return rendered.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }

    /// Returns one seam value as a report line shows it: a plain string bare — `add.sku=COFFEE`
    /// reads better than `add.sku="COFFEE"` — and anything else as its ``CanonicalValue/canonicalString``.
    ///
    /// - Parameter value: A value the counterexample read.
    /// - Returns: A string bare when it reads unambiguously as itself; quoted and escaped when it is
    ///   empty, holds a space, a comma, or a character that must be escaped, or would read as a
    ///   number, a Boolean, or `null`.
    ///
    /// The serialized cassette is the artifact anything machine-read should use.
    private static func render(_ value: CanonicalValue) -> String {
        if case let .string(text) = value, readsBare(text) {
            return text
        }
        return value.canonicalString
    }

    /// Returns whether `text` can stand in a report line without quotes: a comma separates a seam's
    /// positions and a space separates seams, so either would misread.
    ///
    /// - Parameter text: A string seam value.
    /// - Returns: `true` when `text` is non-empty, needs no escaping, holds no space or comma, and
    ///   would not read as another kind of value.
    private static func readsBare(_ text: String) -> Bool {
        guard !text.isEmpty,
              CanonicalValue.string(text).canonicalString == "\"\(text)\"",
              !text.unicodeScalars.contains(where: { $0 == " " || $0 == "," })
        else { return false }
        return Double(text) == nil && !["true", "false", "null"].contains(text)
    }
}
