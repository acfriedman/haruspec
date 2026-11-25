import Foundation
import HaruspecAudit
import HaruspecCore

// The many-verdict rendering, scoped to a PR's diff. A continuous run replays every committed plan,
// but a reviewer reads at the altitude of their change: verdicts whose subject the diff touches are
// the report, a red verdict the diff does NOT touch is the surprise that must lead, and untouched
// greens collapse to one line each. Scoping is by the subject's *declared* sources (the traced
// declarations a verdict carries as origins) — deliberately narrower than the behavior's transitive
// file closure, which is exactly what makes an outside-the-diff red mean something: the change
// reached a subject none of whose declarations it edited.

/// One continuous run's verdict artifacts, partitioned against the changed files of a diff.
public struct ContinuousReport {
    /// One verdict artifact as the report holds it.
    ///
    /// - Parameter verdict: `nil` when the artifact could not be read — rendered as an
    ///   infrastructure failure that does not pass, never dropped.
    /// - Parameter source: What to call the artifact when there is no verdict to name it.
    /// - Parameter subjectFiles: The resolved subject sources (see ``SpecVerdict/subjectFiles(root:)``);
    ///   `nil` means the verdict cannot honestly be scoped and is reported regardless of the diff.
    public struct Entry {
        public let verdict: SpecVerdict?
        public let source: String
        public let subjectFiles: [String]?

        public init(verdict: SpecVerdict?, source: String, subjectFiles: [String]?) {
            self.verdict = verdict
            self.source = source
            self.subjectFiles = subjectFiles
        }
    }

    public let entries: [Entry]
    /// Repo-relative changed paths, or `nil` for an unscoped report — the freshness guard's shape,
    /// where there is no diff to scope to and every verdict renders in full.
    public let changed: Set<String>?

    public init(entries: [Entry], changed: Set<String>?) {
        self.entries = entries
        self.changed = changed
    }

    /// The four-tier verdict per entry, `nil` where no artifact was readable — the exit-code fold
    /// stays with the caller, which owns process exit semantics.
    public var verdicts: [TraceDiff.Verdict?] {
        entries.map { $0.verdict?.verdict }
    }

    /// Returns GitHub-flavored markdown for the sticky PR comment: outside-the-diff reds lead, in-scope
    /// verdicts render in full, untouched greens collapse to one rollup line each.
    ///
    /// - Returns: The rendered markdown; empty when the report holds no entries.
    public func markdown() -> String {
        var sections: [String] = []
        let outside = entries.filter { placement(of: $0) == .redOutsideDiff }
        if !outside.isEmpty {
            sections.append("### ⚠️ Not equivalent outside this diff")
            sections.append(
                "Replay did not come back equivalent for the specs below, yet the diff touches none "
                    + "of their subjects' declared sources — either the change reaches them through "
                    + "files no declaration names, or the environment drifted. Read these first."
            )
            sections.append(contentsOf: outside.map(fullBlock))
        }
        sections.append(contentsOf: entries.filter { placement(of: $0) == .primary }.map(fullBlock))
        let untouched = entries.filter { placement(of: $0) == .greenOutsideDiff }
        if !untouched.isEmpty {
            sections.append("### Untouched by this diff")
            sections.append(untouched.compactMap(\.rollupLine).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Returns the terminal sibling of ``markdown()`` — same partition, plain-text headers.
    ///
    /// - Returns: The rendered plain text; empty when the report holds no entries.
    public func text() -> String {
        var sections: [String] = []
        let outside = entries.filter { placement(of: $0) == .redOutsideDiff }
        if !outside.isEmpty {
            sections.append("── NOT EQUIVALENT OUTSIDE THIS DIFF — read these first ──")
            sections.append(contentsOf: outside.map(fullText))
        }
        sections.append(contentsOf: entries.filter { placement(of: $0) == .primary }.map(fullText))
        let untouched = entries.filter { placement(of: $0) == .greenOutsideDiff }
        if !untouched.isEmpty {
            sections.append(
                "── Untouched by this diff ──\n"
                    + untouched.compactMap(\.rollupLine).joined(separator: "\n")
            )
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Partition

    private enum Placement {
        case primary
        case redOutsideDiff
        case greenOutsideDiff
    }

    /// Returns where one entry renders. Unreadable artifacts and unscopable verdicts are always primary —
    /// hiding either behind a diff no one measured them against would be a silent claim.
    ///
    /// - Parameter entry: One verdict artifact of this report.
    /// - Returns: `.primary` when the report is unscoped, `entry` is unreadable or unscopable, or the diff
    ///   touches its subject; otherwise `.greenOutsideDiff` for an equivalent verdict and
    ///   `.redOutsideDiff` for any other.
    private func placement(of entry: Entry) -> Placement {
        guard let changed,
              let files = entry.subjectFiles,
              let verdict = entry.verdict
        else { return .primary }
        if files.contains(where: changed.contains) {
            return .primary
        }
        return verdict.verdict == .equivalent ? .greenOutsideDiff : .redOutsideDiff
    }

    // MARK: - Rendering

    private func fullBlock(_ entry: Entry) -> String {
        guard let verdict = entry.verdict else { return missingArtifactBlock(entry) }
        guard changed != nil, entry.subjectFiles == nil else { return verdict.markdownReport() }
        return verdict.markdownReport() + "\n\n" + Self.unscopableNote
    }

    private func missingArtifactBlock(_ entry: Entry) -> String {
        "### ⚠️ no verdict produced — `\(entry.source)`\n\n"
            + "The replay ended before writing this artifact — a build break or simulator failure, "
            + "not a behavioral verdict. **This check does not pass.**"
    }

    private func fullText(_ entry: Entry) -> String {
        guard let verdict = entry.verdict else { return missingArtifactText(entry) }
        guard changed != nil, entry.subjectFiles == nil else { return verdict.report() }
        return verdict.report() + "\n" + Self.unscopableNote
    }

    private func missingArtifactText(_ entry: Entry) -> String {
        "⚠️ NO VERDICT — \(entry.source): the replay ended before writing this artifact "
            + "(build break or simulator failure). This check does not pass."
    }

    private static let unscopableNote =
        "_Subject sources could not be resolved against the checkout, so this verdict is "
            + "reported regardless of the diff._"
}

private extension ContinuousReport.Entry {
    /// The one-line collapse of an untouched, equivalent verdict.
    var rollupLine: String? {
        guard let verdict else { return nil }
        var line = "- ✅ `\(verdict.diff.baselineName)` — EQUIVALENT, subject untouched by this diff"
        if verdict.stability.replays > 1, verdict.stability.isStable {
            line += " (\(verdict.stability.replays)/\(verdict.stability.replays) identical replays)"
        }
        return line
    }
}

public extension SpecVerdict {
    /// Returns the subject's declared source files resolved against a checkout, repo-relative — or
    /// `nil` when the verdict cannot honestly be scoped to files.
    ///
    /// - Parameter root: The checkout the origins resolve against, as in `haruspec audit --root`.
    /// - Returns: The subject's source files, repo-relative and sorted, or `nil` on either honesty
    ///   failure below.
    ///
    /// `nil` on either honesty failure: no origins were collected (the run predates collection, or
    /// nothing traced was reached), or a declaration resolved to no file (a binary framework, a
    /// moved class). Both mean "untouched by this diff" would be a guess, so the caller must render
    /// the verdict in full rather than scope it.
    func subjectFiles(root: URL) -> [String]? {
        let origins = qualification.origins
        guard !origins.isEmpty else { return nil }
        let resolutions = SourceResolver(root: root).resolve(origins)
        guard resolutions.allSatisfy(\.isResolved) else { return nil }
        return Set(resolutions.flatMap(\.files)).sorted()
    }
}
