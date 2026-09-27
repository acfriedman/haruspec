import Foundation
import HaruspecCore

// The verdict as evidence for a declaration: what a developer attaches to a PR to show that the
// intent they declared was checked, and what it absorbed. Built from the same sections as the
// sticky comment, minus the parts that ask the reader to do something — an evidence record states
// what happened; it does not offer a block to paste.

public extension SpecVerdict {
    /// The declarations that would mark this verdict's gating divergences intended, one DSL line
    /// each, as narrow as the failing cases allow. Empty unless the verdict is DIVERGED.
    ///
    /// A divergence one of the author's own declarations already rejected gets no line: absorbing
    /// it takes a wider declaration than the one they wrote, which is theirs to choose.
    var offeredDeclarations: [String] {
        guard verdict == .diverged else {
            return []
        }
        let gating = diff.divergences.filter { $0.classification == .collateral }
        return Divergence.suggestedDeclarations(across: failingCases?.gatingDivergences ?? gating)
    }

    /// Returns the markdown evidence record of this verdict: the headline, any declaration the
    /// replay never observed, what each declaration absorbed, and the qualification block.
    ///
    /// - Returns: Markdown sections separated by blank lines, never empty; a DIVERGED verdict's
    ///   record also lists its gating divergences.
    ///
    /// The record never contains a `haruspec-intent` fence, so it can sit beside the declarations it
    /// evidences without being read as a second declaration block.
    func evidenceMarkdown() -> String {
        var sections = [headline]
        sections.append(contentsOf: unobservedIntentSection)
        let intended = diff.divergences.filter { $0.classification == .intended }
        let gating = diff.divergences.filter { $0.classification == .collateral }
        if !gating.isEmpty {
            sections.append("**Collateral — undeclared, gating:**\n\n" + divergenceTable(gating))
        }
        if !intended.isEmpty {
            sections.append("**Intended — absorbed by the declarations above:**\n\n" + divergenceTable(intended))
        }
        sections.append(contentsOf: observationsSection)
        sections.append(qualificationBlock)
        return sections.joined(separator: "\n\n")
    }
}
