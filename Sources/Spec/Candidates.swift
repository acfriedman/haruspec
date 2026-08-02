import Foundation
import HaruspecCore
import HaruspecSeams

// A migration is rarely one candidate. The ports land incrementally, and a spec is re-run against
// each of them — historically as one hand-written `verify(against:)` wrapper per port, all identical
// but for a type name. Declaring them alongside the ops turns that into a list, and the expected
// verdict travels with the declaration: a port being *replaced* is expected EQUIVALENT, while a port
// kept as a deliberate counterexample (a seeded bug, a known-divergent prototype) is expected to
// diverge, and asserting that is what proves the oracle still bites.
//
// The declaration stays a typed Swift block rather than a data file because a candidate *is* a
// constructor — `(SeamContext) -> S`, the same shape `.system` takes. Nothing about it survives a
// round-trip through JSON, and keeping it in Swift keeps rename-safety and autocomplete.

/// One build to interrogate against the spec's baseline, and the verdict it is expected to earn.
public struct Candidate<S> {
    public let name: String
    /// What this candidate *should* produce. Defaults to `.equivalent` — the ordinary case, a port
    /// meant to be indistinguishable from the baseline.
    public let expected: TraceDiff.Verdict
    let make: (SeamContext) -> S

    public init(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        _ make: @escaping (SeamContext) -> S
    ) {
        self.name = name
        self.expected = expected
        self.make = make
    }
}

@resultBuilder public enum CandidatesBuilder<S> {
    public static func buildExpression(_ candidate: Candidate<S>) -> Candidate<S> {
        candidate
    }

    public static func buildBlock(_ candidates: Candidate<S>...) -> [Candidate<S>] {
        candidates
    }
}

/// A candidate's verdict together with the expectation it was declared against, so a caller can assert
/// on `metExpectation` without re-stating per candidate which way it was supposed to go.
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
}

// MARK: - Declaring and running candidates

public extension Spec {
    /// The builds to verify against this spec's baseline.
    func candidates(@CandidatesBuilder<S> _ build: () -> [Candidate<S>]) -> Spec<S> {
        var copy = self
        copy.candidates = build()
        return copy
    }

    /// Declared candidate names, in declaration order. Useful as the arguments of a parameterized test
    /// — it carries no Haruspec types, so a test target can drive one candidate per case.
    var candidateNames: [String] {
        candidates.map(\.name)
    }

    /// Verify every declared candidate against the baseline, in declaration order. Each candidate's
    /// HTML report is written to `reportsIn`, defaulting to Haruspec's temp `HaruspecReports` folder.
    func verifyAll(reportsIn directory: URL? = nil) -> [CandidateVerdict] {
        candidates.map { run($0, reportsIn: directory) }
    }

    /// Verify a single declared candidate by name. `nil` when no candidate was declared under that
    /// name — a renamed candidate fails the lookup rather than silently verifying nothing.
    func verify(candidateNamed name: String, reportsIn directory: URL? = nil) -> CandidateVerdict? {
        candidates.first { $0.name == name }.map { run($0, reportsIn: directory) }
    }

    private func run(_ candidate: Candidate<S>, reportsIn directory: URL?) -> CandidateVerdict {
        let verdict = verify(against: candidate.make)
        return CandidateVerdict(
            name: candidate.name,
            expected: candidate.expected,
            verdict: verdict,
            htmlReportPath: verdict.writeHTMLReport(named: candidate.name, in: directory)?.path
        )
    }
}
