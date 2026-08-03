import Foundation
import HaruspecCore
import HaruspecSeams

// The one call a migration test makes: interrogate *this* build against the spec's baseline, print the
// verdict, and throw unless it earned the one the test declares. The build is an argument rather than
// part of the declaration — which port exists today is a fact about the migration's progress, not about
// how the system is interrogated, and `expecting: .diverged` is an assertion ("the seeded bug still
// bites") that reads as a test name rather than as a line in a spec.
//
// Decoupling costs nothing underneath: `verify(against:)` already takes a bare `(SeamContext) -> S`, so
// all this layer adds is the name the report is written under and the expectation to hold it to. One
// `@Test` per build is what the test runner wants anyway — a real case name, an individual re-run, and
// per-build traits, none of which survive a parameterized run over candidate name strings.

public extension Spec {
    /// Verify one build against this spec's baseline, returning the verdict paired with the expectation
    /// it was held to. `name` titles the console banner and the HTML report written to `reportsIn`
    /// (Haruspec's temp `HaruspecReports` folder by default).
    func verify(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        reportsIn directory: URL? = nil,
        _ make: @escaping (SeamContext) -> S
    ) -> CandidateVerdict {
        let verdict = verify(against: make)
        return CandidateVerdict(
            name: name,
            expected: expected,
            verdict: verdict,
            htmlReportPath: verdict.writeHTMLReport(named: name, in: directory)?.path
        )
    }

    /// The whole body of a migration test case: verify this build, print its report, and throw unless it
    /// earned `expected`. The test asserts nothing itself, because there is nothing left to decide.
    func check(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        reportsIn directory: URL? = nil,
        _ make: @escaping (SeamContext) -> S
    ) throws {
        try verify(name, expecting: expected, reportsIn: directory, make).check(in: self.name)
    }
}

public extension SpecProviding {
    /// Verify one build against this declaration's baseline and throw unless it earned `expected` —
    /// the whole body of a migration test case, called on the spec type itself.
    func check(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        reportsIn directory: URL? = nil,
        _ make: @escaping (SeamContext) -> System
    ) throws {
        try spec.check(name, expecting: expected, reportsIn: directory, make)
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

    /// `verdict.report()` prefixed with the expectation when it was *not* met — the line a failing
    /// test prints, where "DIVERGED" alone doesn't say whether that was the point.
    public func report() -> String {
        guard !metExpectation else {
            return verdict.report()
        }
        return "expected \(expected.rawValue), got \(actual.rawValue)\n\(verdict.report())"
    }

    /// Print the report under `spec/build` and throw unless the expectation was met. Shared by every
    /// check spelling, so an inline build and a declared candidate fail identically.
    func check(in specName: String) throws {
        SpecCatalog.report("\(specName)/\(name)", report(), htmlReportPath: htmlReportPath)
        guard metExpectation else {
            throw SpecCatalog.CheckFailure(description: report())
        }
    }
}
