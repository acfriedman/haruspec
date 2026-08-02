import Foundation
import HaruspecCore

// Everything above this point is generic over the system under test, so `Spec<Cart>` and
// `Spec<Checkout>` cannot sit in one array. `SpecEntry` erases that parameter down to what
// tooling actually needs — a name, the candidates it declares, and how to run them — which is what
// lets an app hold a *catalog* of specs and drive them all from one place.
//
// The point of the catalog is that per-spec test plumbing stops existing. A test target
// parameterizes over `migrationCases` / `continuousSpecs` (plain strings) and never names a
// spec, so declaring a new one is a line in the catalog and nothing else.

/// A spec with its system type erased: name, declared candidates, and the two ways to run it.
public struct SpecEntry {
    public let name: String
    public let candidateNames: [String]
    let verifyCandidate: (String, URL?) -> CandidateVerdict?
    let runContinuous: (ContinuousRun) -> ContinuousOutcome
}

public extension Spec {
    /// Erase this spec for a `SpecCatalog`.
    func entry() -> SpecEntry {
        SpecEntry(
            name: name,
            candidateNames: candidateNames,
            verifyCandidate: { verify(candidateNamed: $0, reportsIn: $1) },
            runContinuous: { runContinuous($0) }
        )
    }
}

/// The declared specs of an app, and the flattened case lists a test target drives them by.
public struct SpecCatalog {
    public let entries: [SpecEntry]

    /// Which spec the environment selects for a continuous run. Unset means "the only declared
    /// spec", which is the common case; a catalog with several requires it.
    public static let specKey = "HARUSPEC_SPEC"

    public init(_ entries: [SpecEntry]) {
        self.entries = entries
    }

    public init(_ entries: SpecEntry...) {
        self.init(entries)
    }

    // MARK: Migration

    /// Every (spec, candidate) pair as `spec/candidate` — one test case per port, carrying no
    /// Haruspec types, so a test target can parameterize over them directly.
    public var migrationCases: [String] {
        entries.flatMap { entry in entry.candidateNames.map { "\(entry.name)/\($0)" } }
    }

    /// Run one `spec/candidate` case. `nil` when either half is no longer declared — a rename
    /// fails the lookup rather than silently verifying nothing.
    public func verify(migrationCase: String, reportsIn directory: URL? = nil) -> CandidateVerdict? {
        guard let separator = migrationCase.firstIndex(of: "/") else {
            return nil
        }
        let spec = String(migrationCase[..<separator])
        let candidate = String(migrationCase[migrationCase.index(after: separator)...])
        return entries.first { $0.name == spec }?.verifyCandidate(candidate, directory)
    }

    // MARK: Continuous

    /// The specs a continuous run should drive: empty unless a mode is selected, which is what
    /// keeps an ordinary test run untouched.
    public func continuousSpecs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard ContinuousMode.fromEnvironment(environment) != nil else {
            return []
        }
        guard let selected = environment[Self.specKey], !selected.isEmpty else {
            // One declared spec needs no selection; several are ambiguous and must be named.
            return entries.count == 1 ? entries.map(\.name) : []
        }
        return entries.map(\.name).filter { $0 == selected }
    }

    /// A case that didn't hold, carrying the report as its message so a test runner prints the
    /// verdict rather than a type name.
    public struct CheckFailure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Run one `scenario/candidate` case, print its report, and throw if it didn't earn the verdict
    /// its candidate declared. The whole body of a migration test case — a test target calls this
    /// and asserts nothing itself, because there is nothing left to decide.
    public func check(migrationCase: String, reportsIn directory: URL? = nil) throws {
        guard let verdict = verify(migrationCase: migrationCase, reportsIn: directory) else {
            throw CheckFailure(description: "\(migrationCase) is no longer declared")
        }
        print("\n─── \(migrationCase) ───\n\(verdict.report())\n\(Self.reportLink(verdict.htmlReportPath))\n")
        guard verdict.metExpectation else {
            throw CheckFailure(description: verdict.report())
        }
    }

    /// The continuous twin of `check(migrationCase:)`: run the side the environment selects, print
    /// the verdict, and throw unless it held.
    public func checkContinuous(
        spec: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let outcome = runContinuous(spec: spec, environment: environment) else {
            throw CheckFailure(description: "\(spec) is no longer declared")
        }
        print("\n─── \(spec) · continuous ───\n\(outcome.summary)\n\(Self.reportLink(outcome.htmlReportPath))\n")
        guard outcome.succeeded else {
            throw CheckFailure(description: outcome.summary)
        }
    }

    /// A `file://` line for the rendered report — ⌘-click it in Xcode's console, or `open` it.
    private static func reportLink(_ path: String?) -> String {
        guard let path else {
            return "  📄 (no HTML report written)"
        }
        return "  📄 visual report: file://\(path)"
    }

    /// Run the continuous side the environment selects for one spec. `nil` when the name isn't
    /// declared; a selected mode with a missing destination comes back as a failed outcome.
    public func runContinuous(
        spec: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ContinuousOutcome? {
        guard let entry = entries.first(where: { $0.name == spec }) else {
            return nil
        }
        do {
            guard let run = try ContinuousRun.fromEnvironment(environment) else {
                return .failed("no \(ContinuousMode.environmentKey) set — nothing to run")
            }
            return entry.runContinuous(run)
        } catch {
            return .failed("\(error)")
        }
    }
}
