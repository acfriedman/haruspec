import Foundation
import HaruspecCore
import HaruspecSeams

// The optional bulk path, for a project that wants its ports *enumerable* — driven from a
// `SpecCatalog`, or swept in one call — rather than one `@Test` per build
// (`check(_:named:expecting:declaring:reportsIn:)`,
// which is the first-class spelling and what a migration suite should reach for). Declaring the list on
// the bound spec is what lets tooling name the ports without constructing any of them; the price is that a
// rename is caught by a failed lookup instead of by the compiler.
//
// The declaration stays a typed Swift block rather than a data file because a candidate *is* a
// constructor — `(SeamContext) -> S`, the same shape `.baselined(on:)` takes. Nothing about it survives a
// round-trip through JSON, and keeping it in Swift keeps rename-safety and autocomplete.

/// One build to interrogate against the bound baseline, the verdict it is expected to earn, and the
/// deltas it declares — expectation and intent both travel with the candidate, because both are facts
/// about *this* build, not about the behavior being specified.
public struct Candidate<S> {
    public let name: String
    /// What this candidate *should* produce. Defaults to `.equivalent` — the ordinary case, a port
    /// meant to be indistinguishable from the baseline.
    public let expected: TraceDiff.Verdict
    /// The deltas this candidate is meant to produce (`Intent.none` = parity: it declares nothing).
    public let declared: Intent
    let make: (SeamContext) -> S

    public init(
        _ name: String,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        _ make: @escaping (SeamContext) -> S
    ) {
        self.name = name
        self.expected = expected
        declared = intent
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

// MARK: - Declaring and running candidates

public extension BaselinedSpec {
    /// Returns this binding with the builds to verify against its baseline, so they are enumerable.
    /// Optional: a suite that runs one `@Test` per build checks each inline and declares nothing here.
    ///
    /// - Parameter build: The candidates, in the order they run; replaces any declared before.
    /// - Returns: The binding with `build`'s candidates declared.
    func candidates(@CandidatesBuilder<S> _ build: () -> [Candidate<S>]) -> BaselinedSpec<S> {
        var copy = self
        copy.candidates = build()
        return copy
    }

    /// Declared candidate names, in declaration order. Useful as the arguments of a parameterized test
    /// — it carries no Haruspec types, so a test target can drive one candidate per case.
    var candidateNames: [String] {
        candidates.map(\.name)
    }

    /// Verifies every declared candidate against the baseline, in declaration order.
    ///
    /// - Parameter directory: Where each HTML report goes; Haruspec's temp `HaruspecReports` folder
    ///   when `nil`.
    /// - Returns: One verdict per candidate, in declaration order.
    func verifyAll(reportsIn directory: URL? = nil) async -> [CandidateVerdict] {
        var verdicts: [CandidateVerdict] = []
        for candidate in candidates {
            await verdicts.append(run(candidate, reportsIn: directory))
        }
        return verdicts
    }

    /// Verifies a single declared candidate by name.
    ///
    /// - Parameters:
    ///   - name: The candidate's declared name.
    ///   - directory: Where the HTML report goes; Haruspec's temp `HaruspecReports` folder when `nil`.
    /// - Returns: The verdict, or `nil` when no candidate is declared under `name` — a renamed
    ///   candidate fails the lookup rather than silently verifying nothing.
    func verify(candidateNamed name: String, reportsIn directory: URL? = nil) async -> CandidateVerdict? {
        guard let candidate = candidates.first(where: { $0.name == name }) else { return nil }
        return await run(candidate, reportsIn: directory)
    }

    /// Runs one declared port, prints its report, and throws unless it earned the verdict its
    /// `Candidate` declared, the declared-list twin of checking a build inline.
    ///
    /// - Parameters:
    ///   - candidate: The candidate's declared name.
    ///   - directory: Where the HTML report goes; Haruspec's temp `HaruspecReports` folder when `nil`.
    /// - Throws: `SpecCatalog.CheckFailure` when `candidate` is not declared or missed its expectation.
    func check(candidate: String, reportsIn directory: URL? = nil) async throws {
        guard let verdict = await verify(candidateNamed: candidate, reportsIn: directory) else {
            throw SpecCatalog.CheckFailure(description: "\(candidate) is no longer a declared candidate")
        }
        try verdict.check(in: name)
    }

    private func run(_ candidate: Candidate<S>, reportsIn directory: URL?) async -> CandidateVerdict {
        await verify(
            candidate.name,
            expecting: candidate.expected,
            declaring: candidate.declared,
            reportsIn: directory,
            candidate.make
        )
    }
}
