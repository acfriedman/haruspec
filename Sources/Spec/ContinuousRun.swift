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

    public static let environmentKey = "HARUSPEC_MODE"

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ContinuousMode? {
        environment[environmentKey].flatMap(ContinuousMode.init(rawValue:))
    }
}

/// A fully-specified run. Modeled as a sum rather than a mode plus optional paths so the destinations
/// a side needs are the destinations it carries: `record` cannot hold a stray results directory, and
/// `replay` cannot be missing one.
public enum ContinuousRun: Sendable {
    /// Base-branch side: pin the explored surface to `planURL`.
    case record(planURL: URL)
    /// Changed-build side: replay the committed `planURL`, write the verdict into `resultsDirectory`.
    case replay(planURL: URL, resultsDirectory: URL)

    public static let planPathKey = "HARUSPEC_PLAN_PATH"
    public static let resultsDirectoryKey = "HARUSPEC_RESULTS_DIR"

    /// Which side this run is, for callers that selected on the mode before assembling the run.
    public var mode: ContinuousMode {
        switch self {
        case .record: .record
        case .replay: .replay
        }
    }

    /// `nil` when no mode is selected, which disables the suite. A selected mode with a missing
    /// destination throws instead: paths are always explicit, never defaulted.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ContinuousRun? {
        guard let mode = ContinuousMode.fromEnvironment(environment) else {
            return nil
        }
        let planURL = try URL(
            fileURLWithPath: environment.requiredPath(Self.planPathKey, mode: mode)
        )
        switch mode {
        case .record:
            return .record(planURL: planURL)
        case .replay:
            let resultsPath = try environment.requiredPath(Self.resultsDirectoryKey, mode: mode)
            return .replay(
                planURL: planURL,
                resultsDirectory: URL(fileURLWithPath: resultsPath, isDirectory: true)
            )
        }
    }
}

/// Why a run could not be assembled from the environment.
public enum ContinuousRunError: Error, CustomStringConvertible, Sendable {
    case missingPath(key: String, mode: ContinuousMode)

    public var description: String {
        switch self {
        case let .missingPath(key, mode):
            "\(ContinuousMode.environmentKey)=\(mode.rawValue) needs \(key) (absolute path)"
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

public extension Spec {
    /// Run whichever side the environment selects. A run that was never selected is a failure here,
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

    func runContinuous(_ run: ContinuousRun) async -> ContinuousOutcome {
        switch run {
        case let .record(planURL):
            await recordContinuous(to: planURL)
        case let .replay(planURL, resultsDirectory):
            await replayContinuous(plan: planURL, into: resultsDirectory)
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

    private func replayContinuous(plan planURL: URL, into resultsDirectory: URL) async -> ContinuousOutcome {
        do {
            try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
            let verdict = try await verify(replayingContentsOf: planURL)
            let resultURL = resultsDirectory.appendingPathComponent("result.json")
            try verdict.write(to: resultURL)
            // HTML is best-effort visual evidence; result.json is the load-bearing artifact.
            let htmlPath = verdict.writeHTMLReport(named: name, in: resultsDirectory)?.path
            return ContinuousOutcome(
                succeeded: verdict.verdict == .equivalent,
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
