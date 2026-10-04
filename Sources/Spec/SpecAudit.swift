import Foundation
import HaruspecAudit
import HaruspecCore
import HaruspecTrace

// Where the capture-completeness audit meets the verdict. The lint tier answers "does this subject
// reach a channel nothing records"; this is the half that makes the answer *cost* something — an
// undeclared bypass becomes a coverage gap, and coverage is already the thing an EQUIVALENT has to
// survive (`VerificationResult.resolve`). Nothing new decides the verdict: the audit only adds to
// what the existing rule reads.
//
// Two honesty rules shape the code:
//   1. A green verdict may claim "audited, nothing found" only if an audit actually ran over
//      something. No root, or no origins to read, leaves `blindSpots` nil — "not audited".
//   2. A declared blind spot is never removed from the verdict, only moved out of the gate. The
//      README promises a reader that a green says what it did not see.

/// The checkout the audit reads. A verdict is recorded by a test process (often on a simulator) that
/// knows a `#fileID` but not where the repo lives, so the root arrives the way every other Continuous
/// destination does: from the environment the pipeline controls, `TEST_RUNNER_`-prefixed under Xcode.
public enum AuditRoot {
    public static let environmentKey = "HARUSPEC_SOURCE_ROOT"

    /// `nil` disables the audit rather than failing the run: an adopter who has not wired the root yet
    /// gets "not audited" on every verdict, which is the truth, and is visibly different from clean.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

public extension SpecVerdict {
    /// Audits what this verdict covered and folds the result back into it: blind spots onto the
    /// qualification block, undeclared ones onto the coverage as gaps, and the verdict re-resolved
    /// over that coverage.
    ///
    /// - Parameter intent: The check site's declaration — only its `acceptedBlindSpots` are read,
    ///   joined onto the ones the verdict already carries.
    ///
    /// Applied after the whole verification rather than inside it because the origin set is only
    /// complete once every capture has run — and because the finding is a property of the *sources*,
    /// identical across the replays a stability run folds together.
    ///
    /// Public so a test or host tool that knows its own checkout (`#filePath`, a repo argument) can
    /// audit explicitly, mirroring `ContinuousRun`'s explicit form beside its env-driven one. The
    /// first audit wins: a verdict already carrying blind spots returns unchanged, so the explicit
    /// call composes with a run where `HARUSPEC_SOURCE_ROOT` already audited inside `verify`.
    func audited(against root: URL, declaring intent: Intent = .none) -> SpecVerdict {
        guard qualification.blindSpots == nil else { return self }
        // An audit over no declarations read nothing, and "nothing found in nothing" must not print
        // as a clean bill of health.
        guard !qualification.origins.isEmpty else { return self }
        let report = AuditReport.audit(origins: qualification.origins, root: root)
        // The verdict carries the spec's and check site's declarations, so an explicit audit resolves
        // exactly what the env-driven one inside the verify would have.
        return noting(report.outcome(accepting: intent.acceptedBlindSpots + (acceptedBlindSpots ?? [])))
    }

    /// Audits against the checkout the calling file lives in: its nearest ancestor holding
    /// `.haruspec` or `.git`. See ``audited(against:declaring:)``.
    ///
    /// - Parameters:
    ///   - intent: The check site's declaration; only its accepted blind spots are read.
    ///   - file: The calling file; the caller's own path by default.
    /// - Returns: The verdict with the audit folded in.
    /// - Precondition: An ancestor of `file` holds `.haruspec` or `.git`; otherwise audit
    ///   explicitly with ``audited(against:declaring:)``.
    func audited(declaring intent: Intent = .none, file: StaticString = #filePath) -> SpecVerdict {
        let path = URL(fileURLWithPath: "\(file)")
        guard let root = Self.checkoutRoot(above: path) else {
            preconditionFailure(
                "no .haruspec or .git above \(path.path) — audit explicitly: audited(against: <checkout root>)"
            )
        }
        return audited(against: root, declaring: intent)
    }

    /// Returns the nearest ancestor of `file` holding `.haruspec` or `.git`, or `nil` when none does.
    ///
    /// - Parameter file: A source file's path.
    /// - Returns: The checkout root.
    internal static func checkoutRoot(above file: URL) -> URL? {
        var directory = file.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let markers = [".haruspec", ".git"].map { directory.appendingPathComponent($0).path }
            if markers.contains(where: FileManager.default.fileExists(atPath:)) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// The same verdict with an audit's outcome applied. Split out so a caller holding its own
    /// `AuditReport` (the CLI, a host tool auditing a recorded `result.json`) folds it in identically.
    internal func noting(_ outcome: AuditOutcome) -> SpecVerdict {
        var verdict = self
        verdict.result = VerificationResult(diff: result.diff, coverage: coverage.noting(outcome))
        verdict.qualification = qualification.noting(blindSpots: outcome.entries)
        return verdict
    }
}

extension Coverage {
    /// The audit's gating findings as coverage gaps. Rebuilt through the initializer so the gap list
    /// re-sorts — a verdict is compared char for char across machines, and the audit's contribution
    /// must not depend on the order the filesystem walk happened to return.
    func noting(_ outcome: AuditOutcome) -> Coverage {
        Coverage(
            declared: declared,
            exercised: exercised,
            gaps: gaps
                + outcome.bypassed.map { Gap(boundary: $0, reason: .bypassedChannel) }
                + outcome.unreadable.map { Gap(boundary: $0, reason: .unauditableSource) },
            domainExercised: domainExercised
        )
    }
}
