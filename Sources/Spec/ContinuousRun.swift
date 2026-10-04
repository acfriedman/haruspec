import Foundation
import HaruspecCore

// The CI harness over `record(to:)` / `verify(replayingContentsOf:)`. Those two give a spec the
// ability to pin a golden plan on the base build and diff a changed build against it; what a PR
// pipeline additionally needs — decide which side to run, validate its destinations, create them,
// write `result.json` and the visual report, and hand back something a test can assert on — is
// identical for every spec. It lives here so an adopting app declares *what* to interrogate and
// nothing about how the Continuous shape is wired.
//
// The run is env-driven by default because the destinations are chosen by the pipeline, not the code:
// CI passes `TEST_RUNNER_HARUSPEC_*` and the runner strips the prefix. `ContinuousRun` is the explicit
// form for callers that already know their paths (a script, a host tool, a test of this harness).

/// Which side of the Continuous shape this process is running. Absent or unrecognized means neither —
/// the suite is disabled and a normal test run is untouched.
public enum ContinuousMode: String, Sendable {
    case record
    case replay
    /// Catalog enumeration for the record-on-merge sweep: every declared spec writes a marker
    /// naming itself, and nothing records or replays.
    ///
    /// Linking a spec into the test target is its registration — the census reads that registry,
    /// so a new spec needs no manifest entry.
    case census
    /// The app host launches and the suite waits, running nothing, so a local check can measure
    /// what launching the app executes — including its asynchronous launch work — and tell a spec's
    /// own coverage apart from it.
    case settle

    public static let environmentKey = "HARUSPEC_MODE"

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ContinuousMode? {
        environment[environmentKey].flatMap(ContinuousMode.init(rawValue:))
    }

    /// Returns whether campaign suites (in-build checks, where baseline and ports coexist) stand
    /// down for this process, so they never pollute a measurement.
    ///
    /// - Parameter environment: The process environment, or a stand-in for one.
    /// - Returns: `true` under `record`, `census`, and `settle`; `false` under `replay` or no mode.
    ///
    /// A record run's code coverage becomes the plan's dependency list, so a campaign executing
    /// beside the capture — a port, another subject — pollutes it into spurious staleness.
    /// Replay keeps campaigns running: a PR gate wants them beside the plan verdicts. Suites
    /// apply this as `@Suite(.disabled(if: ContinuousMode.standsDownCampaigns()))`.
    public static func standsDownCampaigns(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch fromEnvironment(environment) {
        case .record, .census, .settle: true
        case .replay, nil: false
        }
    }
}

/// A fully-specified run. Modeled as a sum rather than a mode plus optional paths so the destinations
/// a side needs are the destinations it carries: `record` cannot hold a stray results directory, and
/// `replay` cannot be missing one.
public enum ContinuousRun: Sendable {
    /// Base-branch side: pin the explored surface to `planURL`.
    case record(planURL: URL)
    /// Changed-build side: replay the committed `planURL`, write the verdict into `resultsDirectory`.
    /// `intentURL` is the PR's declared intent for this spec (extension mode); `nil` is parity mode.
    case replay(planURL: URL, resultsDirectory: URL, intentURL: URL?)
    /// Sweep side: write a `<spec>.census.json` marker into `resultsDirectory` — the declared-spec
    /// inventory the record-on-merge sweep diffs against the committed plans.
    case census(resultsDirectory: URL)
    /// Launch-measurement side: wait `seconds` and run nothing.
    case settle(seconds: Double)

    public static let planPathKey = "HARUSPEC_PLAN_PATH"
    public static let resultsDirectoryKey = "HARUSPEC_RESULTS_DIR"
    public static let intentPathKey = "HARUSPEC_INTENT_PATH"
    /// How long a `settle` run waits, in seconds; unset means ``defaultSettleSeconds``.
    public static let settleSecondsKey = "HARUSPEC_SETTLE_SECONDS"
    /// The wait of a `settle` run with no ``settleSecondsKey`` set.
    ///
    /// Shorter than a recording on purpose: a measurement that stops early only makes a check
    /// replay more specs, while one that outlasts a recording could hide a spec's use of code the
    /// launch keeps running.
    public static let defaultSettleSeconds = 5.0

    /// The spec a conventioned plan path names — `<spec>.plan.json[.gz]` — or `nil` for a path
    /// outside the convention, which applies to every suite.
    ///
    /// This is what lets one whole-target CI run carry several continuous suites: each suite
    /// compares the stem against its own spec and stands down for another's plan, instead of
    /// recording over it or replaying a plan that was never its baseline.
    public static func specName(inPlanPath path: String) -> String? {
        let file = URL(fileURLWithPath: path).lastPathComponent
        for suffix in [".plan.json.gz", ".plan.json"] where file.hasSuffix(suffix) {
            let stem = String(file.dropLast(suffix.count))
            return stem.isEmpty ? nil : stem
        }
        return nil
    }

    /// The spec a conventioned intent path names — `<spec>.intent.json` — or `nil` outside the
    /// convention.
    ///
    /// Same stem discipline as `specName(inPlanPath:)`, so a plan and the intent declared against
    /// it are pairable (and a mispaired pair is refusable) by filename alone.
    public static func specName(inIntentPath path: String) -> String? {
        let file = URL(fileURLWithPath: path).lastPathComponent
        guard file.hasSuffix(".intent.json") else { return nil }
        let stem = String(file.dropLast(".intent.json".count))
        return stem.isEmpty ? nil : stem
    }

    /// Which side this run is, for callers that selected on the mode before assembling the run.
    public var mode: ContinuousMode {
        switch self {
        case .record: .record
        case .replay: .replay
        case .census: .census
        case .settle: .settle
        }
    }

    /// Returns the run the environment selects, with every destination its mode needs. Paths are
    /// always explicit, never defaulted, so a selected mode missing one is an error.
    ///
    /// - Parameter environment: The process environment with the `TEST_RUNNER_` prefix stripped.
    /// - Returns: The run, or `nil` when no mode is selected, which disables the suite.
    /// - Throws: ``ContinuousRunError`` when a selected mode lacks a destination, or carries an
    ///   intent it cannot use or one paired with another spec's plan.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ContinuousRun? {
        guard let mode = ContinuousMode.fromEnvironment(environment) else {
            return nil
        }
        let intentPath = environment[Self.intentPathKey].flatMap { $0.isEmpty ? nil : $0 }
        switch mode {
        case .record:
            // Intent declares a change *against* a baseline; a record run IS the baseline, so an
            // intent here can only be a mispointed pipeline — refuse rather than silently ignore.
            if let intentPath {
                throw ContinuousRunError.intentOnRecord(path: intentPath)
            }
            let planPath = try environment.requiredPath(Self.planPathKey, mode: mode)
            return .record(planURL: URL(fileURLWithPath: planPath))
        case .replay:
            let planPath = try environment.requiredPath(Self.planPathKey, mode: mode)
            let resultsPath = try environment.requiredPath(Self.resultsDirectoryKey, mode: mode)
            // A conventioned intent file must name the same spec as the plan it excuses: a mispaired
            // stem means one spec's declarations were about to be applied to another's verdict.
            if let intentPath,
               let intentSpec = specName(inIntentPath: intentPath),
               let planSpec = specName(inPlanPath: planPath),
               intentSpec != planSpec {
                throw ContinuousRunError.mispairedIntent(intentSpec: intentSpec, planSpec: planSpec)
            }
            return .replay(
                planURL: URL(fileURLWithPath: planPath),
                resultsDirectory: URL(fileURLWithPath: resultsPath, isDirectory: true),
                intentURL: intentPath.map { URL(fileURLWithPath: $0) }
            )
        case .census:
            // A census enumerates what is declared; an intent excuses a change. Pointing one at the
            // other is a mispointed pipeline — refuse rather than silently ignore.
            if let intentPath {
                throw ContinuousRunError.intentOnCensus(path: intentPath)
            }
            let resultsPath = try environment.requiredPath(Self.resultsDirectoryKey, mode: mode)
            return .census(resultsDirectory: URL(fileURLWithPath: resultsPath, isDirectory: true))
        case .settle:
            let seconds = environment[Self.settleSecondsKey].flatMap(Double.init) ?? Self.defaultSettleSeconds
            return .settle(seconds: max(0, seconds))
        }
    }
}

/// Why a run could not be assembled from the environment.
public enum ContinuousRunError: Error, CustomStringConvertible, Sendable {
    case missingPath(key: String, mode: ContinuousMode)
    case intentOnRecord(path: String)
    case intentOnCensus(path: String)
    case mispairedIntent(intentSpec: String, planSpec: String)

    public var description: String {
        switch self {
        case let .missingPath(key, mode):
            "\(ContinuousMode.environmentKey)=\(mode.rawValue) needs \(key) (absolute path)"
        case let .intentOnRecord(path):
            "\(ContinuousRun.intentPathKey)=\(path) with \(ContinuousMode.environmentKey)=record — "
                + "intent declares a change against a baseline, and a record run is the baseline; "
                + "unset it (intent applies on replay only)"
        case let .intentOnCensus(path):
            "\(ContinuousRun.intentPathKey)=\(path) with \(ContinuousMode.environmentKey)=census — "
                + "a census only enumerates declared specs; unset it (intent applies on replay only)"
        case let .mispairedIntent(intentSpec, planSpec):
            "\(ContinuousRun.intentPathKey) names spec \"\(intentSpec)\" but "
                + "\(ContinuousRun.planPathKey) names spec \"\(planSpec)\" — "
                + "an intent file excuses only the spec its stem names (<spec>.intent.json)"
        }
    }
}

/// What a continuous run produced. Deliberately flat and stringly: it crosses back into a test target
/// as an assertion plus something to print, while `result.json` carries the load-bearing detail.
public struct ContinuousOutcome: Sendable {
    public let succeeded: Bool
    public let summary: String
    /// The plan (record) or `result.json` (replay) that was written.
    public let artifactPath: String?
    public let htmlReportPath: String?

    public init(succeeded: Bool, summary: String, artifactPath: String?, htmlReportPath: String?) {
        self.succeeded = succeeded
        self.summary = summary
        self.artifactPath = artifactPath
        self.htmlReportPath = htmlReportPath
    }

    public static func failed(_ reason: String) -> ContinuousOutcome {
        ContinuousOutcome(succeeded: false, summary: reason, artifactPath: nil, htmlReportPath: nil)
    }
}

// MARK: - Driving a spec

public extension BaselinedSpec {
    /// Runs whichever side the environment selects. A run that was never selected is a failure here,
    /// not a silent pass — gate the test on `ContinuousMode.fromEnvironment()` so it never gets called.
    func runContinuous(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> ContinuousOutcome {
        do {
            guard let run = try ContinuousRun.fromEnvironment(environment) else {
                return .failed("no \(ContinuousMode.environmentKey) set — nothing to run")
            }
            return await runContinuous(run)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Runs `run`'s side of the continuous shape for this spec.
    ///
    /// - Parameters:
    ///   - run: The side to run and its destinations.
    ///   - suite: The test suite hosting this run, recorded by a census so a local check can select
    ///     that suite alone; `nil` when the suite did not name itself.
    /// - Returns: The outcome; a failure carries its reason in the summary rather than throwing.
    func runContinuous(_ run: ContinuousRun, suite: ContinuousSuite? = nil) async -> ContinuousOutcome {
        switch run {
        case let .record(planURL):
            await recordContinuous(to: planURL)
        case let .replay(planURL, resultsDirectory, intentURL):
            await replayContinuous(plan: planURL, into: resultsDirectory, intent: intentURL)
        case let .census(resultsDirectory):
            censusContinuous(into: resultsDirectory, suite: suite)
        case let .settle(seconds):
            await settleContinuous(for: seconds)
        }
    }

    private func recordContinuous(to planURL: URL) async -> ContinuousOutcome {
        do {
            try FileManager.default.createDirectory(
                at: planURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let plan = try await record(to: planURL)
            return ContinuousOutcome(
                succeeded: true,
                summary: "recorded \(plan.probes.count) probes "
                    + "(covering \(plan.coveredClasses.joined(separator: ", "))) → \(planURL.path)",
                artifactPath: planURL.path,
                htmlReportPath: nil
            )
        } catch {
            return .failed("record failed: \(error)")
        }
    }

    private func settleContinuous(for seconds: Double) async -> ContinuousOutcome {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return ContinuousOutcome(
            succeeded: true,
            summary: "settle: waited \(seconds)s",
            artifactPath: nil,
            htmlReportPath: nil
        )
    }

    private func censusContinuous(into resultsDirectory: URL, suite: ContinuousSuite?) -> ContinuousOutcome {
        do {
            try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
            let markerURL = resultsDirectory.appendingPathComponent(name + CensusMarker.fileSuffix)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(CensusMarker(spec: name, suite: suite)).write(to: markerURL)
            return ContinuousOutcome(
                succeeded: true,
                summary: "census: \(name)",
                artifactPath: markerURL.path,
                htmlReportPath: nil
            )
        } catch {
            return .failed("census failed: \(error)")
        }
    }

    private func replayContinuous(
        plan planURL: URL,
        into resultsDirectory: URL,
        intent intentURL: URL?
    ) async -> ContinuousOutcome {
        do {
            try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
            // An intent that was pointed at but cannot load must fail the run, never quietly become
            // parity: a red from missing declarations and a green from ignored ones are both wrong.
            let intent = try intentURL.map(Intent.init(contentsOf:)) ?? .none
            let verdict = try await verify(replayingContentsOf: planURL, declaring: intent)
            let resultURL = resultsDirectory.appendingPathComponent("result.json")
            try verdict.write(to: resultURL)
            // HTML is best-effort visual evidence; result.json is the load-bearing artifact.
            let htmlPath = verdict.writeHTMLReport(named: name, in: resultsDirectory)?.path
            return ContinuousOutcome(
                // Unobserved intent fails the run even on EQUIVALENT behavior — the same gate the
                // CLI report exits 6 on — so the local replay and the CI gate cannot disagree.
                succeeded: verdict.verdict == .equivalent && verdict.diff.unobservedIntent.isEmpty,
                summary: verdict.report(),
                artifactPath: resultURL.path,
                htmlReportPath: htmlPath
            )
        } catch {
            return .failed("replay failed: \(error)")
        }
    }
}

private extension [String: String] {
    /// Missing and empty are the same failure: paths must be explicit, never defaulted.
    func requiredPath(_ key: String, mode: ContinuousMode) throws -> String {
        guard let value = self[key], !value.isEmpty else {
            throw ContinuousRunError.missingPath(key: key, mode: mode)
        }
        return value
    }
}
