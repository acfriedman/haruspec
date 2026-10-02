import Foundation
import HaruspecCore

// Everything above this point is generic over the system under test, so `Spec<Cart>` and
// `Spec<Checkout>` cannot sit in one array. `SpecEntry` erases that parameter down to what
// tooling actually needs — a name, the candidates it declares, and how to run them — which is what
// lets an app hold a *catalog* of specs and drive them all from one place.
//
// Two shapes, and the first is the one that scales. `SpecProviding`'s own `check(_:expecting:_:)` lets
// a spec carry its *own* suite in its own file, so a project with fifty specs keeps no central list — a
// new spec is a new file and nothing else. `SpecCatalog` is the alternative for a project that would
// rather drive everything from one place: it flattens differently-typed specs into plain
// `spec/candidate` strings, at the cost of declaring `.candidates` and a line to remember per spec.

/// Declares one spec by conformance — the same shape SwiftUI asks of a `View`: a type whose
/// whole job is to answer one property. `System` is inferred from the return type, so an author
/// writes the spec and never the associated type.
///
///     struct CartMigration: SpecProviding {
///         var spec: Spec<Cart> { … }
///     }
///
/// Conforming is what lets a catalog take the declarations directly (`SpecCatalog(CartMigration())`)
/// rather than each caller remembering to erase with `.entry()`.
public protocol SpecProviding {
    associatedtype System
    var spec: Spec<System> { get }
}

public extension SpecProviding {
    /// Erases this declaration for a `SpecCatalog`. Not on the protocol itself: the signature
    /// mentions no associated type, so it stays callable on `any SpecProviding`.
    func entry() -> SpecEntry {
        spec.entry()
    }

    /// The continuous side to run, or empty — which is what keeps an ordinary test run untouched.
    ///
    /// A plan path following the `<spec>.plan.json[.gz]` convention also scopes the mode to the
    /// spec it names: CI runs the whole target (the parameterized case ignores function-level
    /// `-only-testing:`), so with several continuous suites in one target the filename is what
    /// keeps a suite from recording over another's plan or replaying a foreign baseline. A path
    /// outside the convention applies to every suite, and its mismatches fail loudly downstream.
    func continuousModes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ContinuousMode] {
        guard let mode = ContinuousMode.fromEnvironment(environment) else {
            return []
        }
        if let path = environment[ContinuousRun.planPathKey],
           let planSpec = ContinuousRun.specName(inPlanPath: path),
           planSpec != spec.name {
            return []
        }
        return [mode]
    }

    /// Runs the continuous side CI selected, prints the verdict, and throws unless it held. A local
    /// check runs the whole test target for a suite that calls this form.
    ///
    /// - Parameters:
    ///   - mode: The side the test's arguments selected.
    ///   - environment: Where the run's destinations are read from; the process environment by default.
    /// - Throws: `SpecCatalog.CheckFailure` unless the side held, carrying the printed summary's first line.
    func checkContinuous(
        _ mode: ContinuousMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        try await checkContinuous(mode, suite: nil, environment: environment)
    }

    /// Runs the continuous side selected, naming the test suite that hosts it, so a local
    /// `haruspec check` runs this suite alone instead of the whole test target.
    ///
    /// - Parameters:
    ///   - mode: The side the test's arguments selected.
    ///   - suite: The type of the suite calling this; inside the suite, that is `Self`.
    ///   - environment: Where the run's destinations are read from; the process environment by default.
    /// - Throws: `SpecCatalog.CheckFailure` unless the side held, carrying the printed summary's first line.
    func checkContinuous(
        _ mode: ContinuousMode,
        in suite: Any.Type,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        try await checkContinuous(mode, suite: ContinuousSuite(suite), environment: environment)
    }

    private func checkContinuous(
        _ mode: ContinuousMode,
        suite: ContinuousSuite?,
        environment: [String: String]
    ) async throws {
        let outcome: ContinuousOutcome
        do {
            guard let run = try ContinuousRun.fromEnvironment(environment), mode == run.mode else {
                throw SpecCatalog.CheckFailure(description: "no \(ContinuousMode.environmentKey) set")
            }
            outcome = await spec.runContinuous(run, suite: suite)
        } catch let failure as SpecCatalog.CheckFailure {
            throw failure
        } catch {
            throw SpecCatalog.CheckFailure(description: "\(error)")
        }
        SpecCatalog.report(
            "\(spec.name) · \(mode.rawValue)",
            outcome.summary,
            htmlReportPath: outcome.htmlReportPath
        )
        guard outcome.succeeded else {
            throw SpecCatalog.CheckFailure.reported(outcome.summary)
        }
    }
}

/// A spec with its system type erased: name, declared candidates, and the two ways to run it.
public struct SpecEntry {
    public let name: String
    public let candidateNames: [String]
    // Stored as closures, so the async colour lands in the *type* rather than a signature.
    let verifyCandidate: (String, URL?) async -> CandidateVerdict?
    let runContinuous: (ContinuousRun, ContinuousSuite?) async -> ContinuousOutcome
}

public extension Spec {
    /// Erases this spec for a `SpecCatalog`.
    func entry() -> SpecEntry {
        SpecEntry(
            name: name,
            candidateNames: candidateNames,
            verifyCandidate: { await verify(candidateNamed: $0, reportsIn: $1) },
            runContinuous: { await runContinuous($0, suite: $1) }
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

    /// The usual spelling: hand the catalog the declarations themselves.
    public init(_ providers: [any SpecProviding]) {
        self.init(providers.map { $0.entry() })
    }

    public init(_ providers: any SpecProviding...) {
        self.init(providers.map { $0.entry() })
    }

    // MARK: Migration

    /// Every (spec, candidate) pair as `spec/candidate` — one test case per port, carrying no
    /// Haruspec types, so a test target can parameterize over them directly.
    public var migrationCases: [String] {
        entries.flatMap { entry in entry.candidateNames.map { "\(entry.name)/\($0)" } }
    }

    /// Runs one `spec/candidate` case. `nil` when either half is no longer declared — a rename
    /// fails the lookup rather than silently verifying nothing.
    ///
    /// - Parameter directory: Where the HTML report lands; `nil` means Haruspec's temp
    ///   `HaruspecReports` folder.
    public func verify(migrationCase: String, reportsIn directory: URL? = nil) async -> CandidateVerdict? {
        guard let separator = migrationCase.firstIndex(of: "/") else {
            return nil
        }
        let spec = String(migrationCase[..<separator])
        let candidate = String(migrationCase[migrationCase.index(after: separator)...])
        guard let entry = entries.first(where: { $0.name == spec }) else { return nil }
        return await entry.verifyCandidate(candidate, directory)
    }

    // MARK: Continuous

    /// The specs a continuous run should drive: empty unless a mode is selected, which is what
    /// keeps an ordinary test run untouched.
    public func continuousSpecs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let mode = ContinuousMode.fromEnvironment(environment) else {
            return []
        }
        // A census exists to enumerate the whole catalog, so selection never narrows it.
        if mode == .census {
            return entries.map(\.name)
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

        /// The failure for a check whose report the console already printed. The test runner prints
        /// a thrown error too, so this carries only the report's first line.
        ///
        /// - Parameter report: The full report the console printed.
        /// - Returns: A failure carrying the report's first line, or the whole report when it is
        ///   one line.
        static func reported(_ report: String) -> CheckFailure {
            let headline = report.prefix { $0 != "\n" }
            guard headline.count < report.count else {
                return CheckFailure(description: report)
            }
            return CheckFailure(description: "\(headline) — full report above")
        }
    }

    /// Runs one `spec/candidate` case, prints its report, and throws if it didn't earn the verdict
    /// its candidate declared. The whole body of a migration test case — a test target calls this
    /// and asserts nothing itself, because there is nothing left to decide.
    ///
    /// - Parameter directory: Where the HTML report lands; `nil` means Haruspec's temp
    ///   `HaruspecReports` folder.
    public func check(migrationCase: String, reportsIn directory: URL? = nil) async throws {
        guard let verdict = await verify(migrationCase: migrationCase, reportsIn: directory) else {
            throw CheckFailure(description: "\(migrationCase) is no longer declared")
        }
        // `migrationCase` is already `spec/candidate`, the title every check reports under.
        try verdict.check(in: String(migrationCase.prefix { $0 != "/" }))
    }

    /// Runs the continuous side of `spec` the environment selects, prints the verdict, and throws
    /// unless it held. The continuous twin of ``check(migrationCase:)``.
    ///
    /// - Parameters:
    ///   - spec: The spec's name.
    ///   - environment: Where the side selection is read from; the process environment by default.
    /// - Throws: `CheckFailure` when `spec` is not declared or the selected side did not hold, carrying
    ///   the first line of the summary the console printed.
    public func checkContinuous(
        spec: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        try await checkContinuous(spec: spec, suite: nil, environment: environment)
    }

    /// Runs the continuous side of `spec` the environment selects, naming the test suite that hosts
    /// it, so a local `haruspec check` runs this suite alone instead of the whole test target.
    ///
    /// - Parameters:
    ///   - spec: The spec's name.
    ///   - suite: The type of the suite calling this; inside the suite, that is `Self`.
    ///   - environment: Where the side selection is read from; the process environment by default.
    /// - Throws: `CheckFailure` when `spec` is not declared or the selected side did not hold.
    public func checkContinuous(
        spec: String,
        in suite: Any.Type,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        try await checkContinuous(spec: spec, suite: ContinuousSuite(suite), environment: environment)
    }

    private func checkContinuous(
        spec: String,
        suite: ContinuousSuite?,
        environment: [String: String]
    ) async throws {
        guard let outcome = await runContinuous(spec: spec, suite: suite, environment: environment) else {
            throw CheckFailure(description: "\(spec) is no longer declared")
        }
        Self.report("\(spec) · continuous", outcome.summary, htmlReportPath: outcome.htmlReportPath)
        guard outcome.succeeded else {
            throw CheckFailure.reported(outcome.summary)
        }
    }

    /// The console rendering every check shares: a titled banner, the verdict, and a `file://` line
    /// for the rendered report — ⌘-click it in Xcode's console, or `open` it.
    static func report(_ title: String, _ body: String, htmlReportPath: String?) {
        print("\n─── \(title) ───\n\(body)\n\(reportLink(htmlReportPath))\n")
    }

    static func reportLink(_ path: String?) -> String {
        guard let path else {
            return "  📄 (no HTML report written)"
        }
        return "  📄 visual report: file://\(path)"
    }

    /// Runs the continuous side the environment selects for one spec. A selected mode with a
    /// missing destination comes back as a failed outcome rather than a throw.
    ///
    /// - Parameters:
    ///   - spec: The spec's name.
    ///   - suite: The test suite hosting the run, recorded by a census; `nil` when unknown.
    ///   - environment: Where the side selection is read from; the process environment by default.
    /// - Returns: The outcome, or `nil` when `spec` is not declared.
    public func runContinuous(
        spec: String,
        suite: ContinuousSuite? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> ContinuousOutcome? {
        guard let entry = entries.first(where: { $0.name == spec }) else {
            return nil
        }
        do {
            guard let run = try ContinuousRun.fromEnvironment(environment) else {
                return .failed("no \(ContinuousMode.environmentKey) set — nothing to run")
            }
            return await entry.runContinuous(run, suite)
        } catch {
            return .failed("\(error)")
        }
    }
}
