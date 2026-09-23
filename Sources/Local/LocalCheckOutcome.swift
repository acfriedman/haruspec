import Foundation
import HaruspecCore
import HaruspecSpec

/// What one local check found: a verdict per spec, or the reason a spec has none, plus what was
/// compared.
public struct LocalCheckOutcome: Sendable {
    /// How one spec's check ended.
    public enum SpecResult: Sendable {
        /// The replay produced a verdict, written to `artifact`; `otherFailures` is the log of a test
        /// run in which tests outside this verdict also failed, such as a campaign suite.
        case verdict(SpecVerdict, artifact: URL, otherFailures: URL?)
        /// The merge base does not declare the spec, so there is nothing to compare it with yet.
        case noBaseline
        /// Recording or replaying failed before a verdict existed; `log` holds the build output.
        case failed(reason: String, log: URL?)
    }

    /// One spec's line in the outcome.
    public struct Entry: Sendable {
        /// The spec's name.
        public let spec: String
        /// How its check ended.
        public let result: SpecResult
    }

    /// The branch compared against, as given.
    public let base: String
    /// The merge base's full hash.
    public let baseSHA: String
    /// `HEAD`'s full hash.
    public let headSHA: String
    /// The checked-out branch, or `nil` when `HEAD` is detached.
    public let branch: String?
    /// Whether the working tree differs from `HEAD`; the replay measured those changes too.
    public let uncommitted: Bool
    /// One entry per checked spec, in check order.
    public let entries: [Entry]
    /// Specs the intent doc declares that this check did not replay — a typo or a stale section.
    public let undeclaredIntent: [String]
    /// Repo-relative paths that differ from the merge base, which scope the report.
    public let changedFiles: [String]
    /// The repository root the verdicts' origins resolve against.
    public let repositoryRoot: URL
    /// The intent doc the check read, or `nil` with no branch; it may not exist.
    public let intentDocument: URL?
    /// Where the run's logs, bundles, and verdicts live.
    public let runDirectory: URL

    /// The process exit code: the worst across specs, using the CLI's codes — 0 equivalent,
    /// 3 diverged, 4 cannot verify, 5 unstable, 6 declared intent not observed, 1 no verdict.
    ///
    /// A spec with no baseline at the merge base does not fail the check.
    public var exitCode: Int32 {
        entries.map { entry -> Int32 in
            switch entry.result {
            case let .verdict(verdict, _, _):
                Self.exitCode(for: verdict)
            case .noBaseline:
                0
            case .failed:
                1
            }
        }.max() ?? 0
    }

    /// Returns the exit code one verdict earns.
    ///
    /// - Parameter verdict: A replay's verdict.
    /// - Returns: 0, 3, 4, 5, or 6, as ``exitCode`` describes.
    public static func exitCode(for verdict: SpecVerdict) -> Int32 {
        switch verdict.verdict {
        case .equivalent: verdict.diff.unobservedIntent.isEmpty ? 0 : 6
        case .diverged: 3
        case .cannotVerify: 4
        case .unstable: 5
        }
    }

    /// Returns the terminal report: what was compared, the verdicts scoped to the changed files, and
    /// for each red spec the `haruspec intent save` command that declares its divergences.
    ///
    /// - Returns: Plain text for a terminal or an agent.
    public func report() -> String {
        var sections = [header]
        let verdicts = entries.compactMap { entry -> ContinuousReport.Entry? in
            guard case let .verdict(verdict, artifact, _) = entry.result else {
                return nil
            }
            return ContinuousReport.Entry(
                verdict: verdict,
                source: artifact.path,
                subjectFiles: verdict.subjectFiles(root: repositoryRoot)
            )
        }
        if !verdicts.isEmpty {
            sections.append(ContinuousReport(entries: verdicts, changed: Set(changedFiles)).text())
        }
        sections.append(contentsOf: missingVerdictLines)
        sections.append(contentsOf: offers)
        sections.append("run: \(runDirectory.path)")
        return sections.joined(separator: "\n\n")
    }

    /// Writes this check's verdicts as evidence under each declared spec in `document`.
    ///
    /// - Parameter document: The intent doc the check read; sections for specs this check did not
    ///   replay are left as they were.
    public func refreshEvidence(in document: inout IntentDocument) {
        for entry in entries where document.sectionSpecs.contains(entry.spec) {
            guard case let .verdict(verdict, _, _) = entry.result else {
                continue
            }
            let stamp = "**Checked** · base `\(base)` @ `\(baseSHA.prefix(7))` → `\(headSHA.prefix(7))`"
                + (uncommitted ? " + uncommitted changes" : "")
                + " · \(ISO8601DateFormatter().string(from: Date()))"
            document.setEvidence(stamp + "\n\n" + verdict.evidenceMarkdown(), for: entry.spec)
        }
    }

    // MARK: - Sections

    private var header: String {
        let head = "\(headSHA.prefix(7))" + (uncommitted ? " + uncommitted changes" : "")
        var lines = ["haruspec check · \(branch ?? "detached HEAD") · \(base) @ \(baseSHA.prefix(7)) → \(head)"]
        if let intentDocument, FileManager.default.fileExists(atPath: intentDocument.path) {
            lines.append("intent: \(relative(intentDocument))")
        } else {
            lines.append("intent: none declared — parity: any behavior change is red")
        }
        for spec in undeclaredIntent {
            lines.append("  ⚠︎ the intent doc declares \(spec), which this check did not replay")
        }
        return lines.joined(separator: "\n")
    }

    private var missingVerdictLines: [String] {
        entries.compactMap { entry in
            switch entry.result {
            case let .verdict(_, _, otherFailures):
                otherFailures.map { log in
                    "⚠︎ \(entry.spec): other tests failed in the same run (not part of this verdict — "
                        + "a campaign suite, say)\n  log: \(log.path)"
                }
            case .noBaseline:
                "— \(entry.spec): no baseline — the merge base does not declare this spec; "
                    + "it is compared once it exists on \(base)"
            case let .failed(reason, log):
                "✗ \(entry.spec): NO VERDICT — \(reason)" + (log.map { "\n  log: \($0.path)" } ?? "")
            }
        }
    }

    /// For every red spec with offered declarations: the command that declares them.
    private var offers: [String] {
        entries.compactMap { entry in
            guard case let .verdict(verdict, _, _) = entry.result, !verdict.offeredDeclarations.isEmpty else {
                return nil
            }
            let arguments = verdict.offeredDeclarations.map(Self.shellQuoted).joined(separator: " \\\n      ")
            return """
            \(entry.spec): is this change the point of the branch? Declare it (edit it down to what \
            you mean), then check again:
                haruspec intent save \(entry.spec) \\
                  \(arguments)
            If you did not mean to change behavior, this is a regression: fix the code, don't declare it.
            """
        }
    }

    private func relative(_ url: URL) -> String {
        let root = repositoryRoot.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
