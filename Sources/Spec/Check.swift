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
    /// Verifies one build against this spec's baseline, returning the verdict paired with the expectation
    /// it was held to. `name` titles the console banner and the HTML report written to `reportsIn`
    /// (Haruspec's temp `HaruspecReports` folder by default). `declaring` is this build's intent —
    /// the deltas *this port* is meant to produce — which lives here, next to the build it describes,
    /// because a declaration on the spec would leak one port's excuses to every other candidate.
    func verify(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil,
        _ make: @escaping (SeamContext) -> S
    ) async -> CandidateVerdict {
        let verdict = await verify(against: make, declaring: intent)
        return CandidateVerdict(
            name: name,
            expected: expected,
            verdict: verdict,
            htmlReportPath: verdict.writeHTMLReport(named: name, in: directory)?.path
        )
    }

    /// The whole body of a migration test case: verify this build, print its report, and throw unless it
    /// earned `expected`. The test asserts nothing itself, because there is nothing left to decide.
    /// Returned (discardably) so a test can additionally pin what rode along with the verdict — a
    /// qualification line, a declared blind spot — without running the campaign twice.
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

    /// `check(_:expecting:declaring:reportsIn:_:)` for a build the spec can construct itself: the
    /// conformer is built through the boundary's pasted `init` — collaborators resolved to their
    /// doubles, the capture's center injected — and wrapped in the forwarder, exactly as the
    /// baseline is. The report is titled by the type unless `named` says otherwise.
    ///
    /// - Precondition: The spec must derive construction (`derivedFrom:` a catalog whose protocol
    ///   pastes its `init` and carries `@Haruspec`); otherwise author the build with the
    ///   closure form. The type must conform to the boundary protocol — a spec generic over
    ///   `any Proto` cannot demand that statically, so a non-conformer traps naming the extension
    ///   to write.
    @discardableResult
    func check(
        _ conformer: Any.Type,
        named name: String? = nil,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil
    ) async throws -> SpecVerdict {
        guard let construct = makeConformer else {
            preconditionFailure(
                "spec '\(self.name)' derives no construction, so it cannot build \(conformer) — paste the "
                    + "init into the @Haruspec protocol, or author the build: "
                    + "check(\"\(conformer)\") { context in … }"
            )
        }
        return try await check(
            name ?? String(describing: conformer),
            expecting: expected,
            declaring: intent,
            reportsIn: directory
        ) { construct($0, conformer) }
    }
}

public extension SpecProviding {
    /// Verifies one build against this declaration's baseline and throws unless it earned `expected` —
    /// the whole body of a migration test case, called on the spec type itself.
    @discardableResult
    func check(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil,
        _ make: @escaping (SeamContext) -> System
    ) async throws -> SpecVerdict {
        try await spec.check(name, expecting: expected, declaring: intent, reportsIn: directory, make)
    }

    /// Verifies a build the spec constructs itself — see `Spec.check(_:named:expecting:declaring:reportsIn:)`.
    @discardableResult
    func check(
        _ conformer: Any.Type,
        named name: String? = nil,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil
    ) async throws -> SpecVerdict {
        try await spec.check(conformer, named: name, expecting: expected, declaring: intent, reportsIn: directory)
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

    /// Prints the report under `spec/build` and throws unless the expectation was met. Shared by every
    /// check spelling, so an inline build and a declared candidate fail identically.
    func check(in specName: String) throws {
        SpecCatalog.report("\(specName)/\(name)", report(), htmlReportPath: htmlReportPath)
        guard metExpectation else {
            throw SpecCatalog.CheckFailure(description: report())
        }
    }
}
