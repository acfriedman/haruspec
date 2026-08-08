import Foundation
import HaruspecCore
import HaruspecSeams

// The optional bulk path, for a project that wants its ports *enumerable* — driven from a
// `SpecCatalog`, or swept in one call — rather than one `@Test` per build (`Spec.check(_:expecting:_:)`,
// which is the first-class spelling and what a migration suite should reach for). Declaring the list on
// the spec is what lets tooling name the ports without constructing any of them; the price is that a
// rename is caught by a failed lookup instead of by the compiler.
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

// MARK: - Declaring and running candidates

public extension Spec {
    /// The builds to verify against this spec's baseline, when they should be enumerable. Optional:
    /// a suite that runs one `@Test` per build calls `check(_:expecting:_:)` and declares nothing here.
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
    func verifyAll(reportsIn directory: URL? = nil) async -> [CandidateVerdict] {
        var verdicts: [CandidateVerdict] = []
        for candidate in candidates {
            await verdicts.append(run(candidate, reportsIn: directory))
        }
        return verdicts
    }

    /// Verify a single declared candidate by name. `nil` when no candidate was declared under that
    /// name — a renamed candidate fails the lookup rather than silently verifying nothing.
    func verify(candidateNamed name: String, reportsIn directory: URL? = nil) async -> CandidateVerdict? {
        guard let candidate = candidates.first(where: { $0.name == name }) else { return nil }
        return await run(candidate, reportsIn: directory)
    }

    private func run(_ candidate: Candidate<S>, reportsIn directory: URL?) async -> CandidateVerdict {
        await verify(candidate.name, expecting: candidate.expected, reportsIn: directory, candidate.make)
    }
}

public extension SpecProviding {
    /// The ports this spec declares — the arguments of a parameterized migration test case.
    var candidateNames: [String] {
        spec.candidateNames
    }

    /// Run one declared port, print its report, and throw unless it earned the verdict its
    /// `Candidate` declared. The declared-list twin of `check(_:expecting:_:)`.
    func check(candidate: String, reportsIn directory: URL? = nil) async throws {
        guard let verdict = await spec.verify(candidateNamed: candidate, reportsIn: directory) else {
            throw SpecCatalog.CheckFailure(description: "\(candidate) is no longer a declared candidate")
        }
        try verdict.check(in: spec.name)
    }
}
