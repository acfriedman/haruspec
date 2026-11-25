import Foundation
import HaruspecCore
import HaruspecSeams

// The one call a migration test makes: interrogate *this* build against the bound baseline, print the
// verdict, and throw unless it earned the one the test declares. The build is an argument rather than
// part of the declaration — which port exists today is a fact about the migration's progress, not about
// how the system is interrogated, and `expecting: .diverged` is an assertion ("the seeded bug still
// bites") that reads as a test name rather than as a line in a spec.
//
// Decoupling costs nothing underneath: `verify(candidate:declaring:)` already takes a bare
// `(SeamContext) -> S`, so all this layer adds is the name the report is written under and the
// expectation to hold it to. One `@Test` per build is what the test runner wants anyway — a real case
// name, an individual re-run, and per-build traits, none of which survive a parameterized run over
// candidate name strings.

public extension BaselinedSpec {
    /// Verifies one build against the bound baseline, returning the verdict paired with the
    /// expectation it was held to. The intent lives with the build because a declaration on the spec
    /// would leak one port's excuses to every other candidate.
    ///
    /// - Parameters:
    ///   - name: The build's title on the console banner and the HTML report.
    ///   - expected: The verdict the build should earn.
    ///   - intent: The deltas this build is meant to produce; `.none` asks for parity.
    ///   - directory: Where the HTML report goes; Haruspec's temp `HaruspecReports` folder when `nil`.
    ///   - make: Builds a fresh candidate per capture from the capture's context.
    /// - Returns: The verdict with the expectation it was held to.
    func verify(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil,
        _ make: @escaping (SeamContext) -> S
    ) async -> CandidateVerdict {
        let verdict = await verify(candidate: make, declaring: intent)
        return CandidateVerdict(
            name: name,
            expected: expected,
            verdict: verdict,
            htmlReportPath: verdict.writeHTMLReport(named: name, in: directory)?.path
        )
    }

    /// Verifies one build, prints its report, and throws unless it earned `expected` — the whole
    /// body of a migration test case. The verdict comes back so a test can additionally pin what rode
    /// along with it without running the campaign twice.
    ///
    /// - Parameters:
    ///   - name: The build's title on the console banner and the HTML report.
    ///   - expected: The verdict the build must earn.
    ///   - intent: The deltas this build is meant to produce; `.none` asks for parity.
    ///   - directory: Where the HTML report goes; Haruspec's temp `HaruspecReports` folder when `nil`.
    ///   - make: Builds a fresh candidate per capture from the capture's context.
    /// - Returns: The verdict.
    /// - Throws: `SpecCatalog.CheckFailure` unless the build earned `expected`.
    @discardableResult
    func check(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil,
        _ make: @escaping (SeamContext) -> S
    ) async throws -> SpecVerdict {
        let candidate = await verify(name, expecting: expected, declaring: intent, reportsIn: directory, make)
        try candidate.check(in: self.name)
        return candidate.verdict
    }

    /// Verifies a conformer the spec constructs itself, built and wrapped exactly as a baseline bound
    /// by type is, and throws unless it earned `expected`.
    ///
    /// - Parameters:
    ///   - conformer: The port's type; it must conform to the boundary protocol.
    ///   - name: The report's title; the type's name when `nil`.
    ///   - expected: The verdict the build must earn.
    ///   - intent: The deltas this build is meant to produce; `.none` asks for parity.
    ///   - directory: Where the HTML report goes; Haruspec's temp `HaruspecReports` folder when `nil`.
    /// - Returns: The verdict.
    /// - Throws: `SpecCatalog.CheckFailure` unless the build earned `expected`.
    /// - Precondition: The spec derives construction (its stamped protocol pastes its `init`);
    ///   otherwise the trap says to author the build with the closure form. A
    ///   non-conformer traps naming the extension to write.
    @discardableResult
    func check(
        _ conformer: Any.Type,
        named name: String? = nil,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil
    ) async throws -> SpecVerdict {
        try await check(
            name ?? String(describing: conformer),
            expecting: expected,
            declaring: intent,
            reportsIn: directory,
            spec.constructing(conformer)
        )
    }
}

/// A verdict together with the expectation it was held to, so a caller can assert on `metExpectation`
/// without re-stating which way this build was supposed to go.
public struct CandidateVerdict: Sendable {
    public let name: String
    public let expected: TraceDiff.Verdict
    public let verdict: SpecVerdict
    /// Where the rendered HTML report was written, if it was.
    public let htmlReportPath: String?

    public var actual: TraceDiff.Verdict {
        verdict.verdict
    }

    public var metExpectation: Bool {
        actual == expected
    }

    /// Returns the verdict's report, prefixed with the expectation when it was *not* met — the line a
    /// failing test prints, where "DIVERGED" alone doesn't say whether that was the point.
    ///
    /// - Returns: The verdict's report text; when the expectation was not met, preceded by an
    ///   `expected <verdict>, got <verdict>` line.
    public func report() -> String {
        guard !metExpectation else {
            return verdict.report()
        }
        return "expected \(expected.rawValue), got \(actual.rawValue)\n\(verdict.report())"
    }

    /// Prints the report under `spec/build` and throws unless the expectation was met. Shared by every
    /// check spelling, so an inline build and a declared candidate fail identically.
    ///
    /// - Parameter specName: The name of the spec the build was checked against; the first path
    ///   component of the printed `spec/build` title.
    /// - Throws: ``SpecCatalog/CheckFailure`` carrying the report's first line when the verdict differs
    ///   from the expected one.
    func check(in specName: String) throws {
        SpecCatalog.report("\(specName)/\(name)", report(), htmlReportPath: htmlReportPath)
        guard metExpectation else {
            throw SpecCatalog.CheckFailure.reported(report())
        }
    }
}
