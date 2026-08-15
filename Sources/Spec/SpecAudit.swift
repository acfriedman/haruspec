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

extension SpecVerdict {
    /// Audit what this verdict covered and fold the result back into it: blind spots onto the
    /// qualification block, undeclared ones onto the coverage as gaps, and the verdict re-resolved
    /// over that coverage.
    ///
    /// Applied after the whole verification rather than inside it because the origin set is only
    /// complete once every capture has run — and because the finding is a property of the *sources*,
    /// identical across the replays a stability run folds together.
    func audited(against root: URL, declaring intent: Intent) -> SpecVerdict {
        // An audit over no declarations read nothing, and "nothing found in nothing" must not print
        // as a clean bill of health.
        guard !qualification.origins.isEmpty else { return self }
        let report = AuditReport.audit(origins: qualification.origins, root: root)
        return noting(report.outcome(accepting: intent.acceptedBlindSpots))
    }

    /// The same verdict with an audit's outcome applied. Split out so a caller holding its own
    /// `AuditReport` (the CLI, a host tool auditing a recorded `result.json`) folds it in identically.
    func noting(_ outcome: AuditOutcome) -> SpecVerdict {
        SpecVerdict(
            schemaVersion: schemaVersion,
            result: VerificationResult(diff: result.diff, coverage: coverage.noting(outcome)),
            orderingsExplored: orderingsExplored,
            failingOrder: failingOrder,
            counterexample: counterexample,
            exploration: exploration,
            qualification: qualification.noting(blindSpots: outcome.entries),
            violatedPreconditions: violatedPreconditions,
            stability: stability
        )
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
