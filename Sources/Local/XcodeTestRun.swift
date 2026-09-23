import Foundation
import HaruspecSpec

/// One whole-target `xcodebuild test` run in one continuous mode — the invocation the dogfood
/// workflows spell out in YAML, assembled from a ``LocalConfig``.
///
/// Never passes `-sdk`: it overrides `SDKROOT` for the macro host tool, and every macro expansion
/// then fails with "produced malformed response". The destination alone selects the platform.
struct XcodeTestRun {
    /// The checkout the project paths resolve against — the repository or the base worktree.
    let checkout: URL
    /// The repository's settings.
    let config: LocalConfig
    /// The continuous mode the test target runs in.
    let mode: ContinuousMode
    /// The plan to record into or replay; `nil` only in census mode.
    let plan: URL?
    /// Where the run writes `result.json` or census markers; `nil` in record mode.
    let results: URL?
    /// The per-spec intent file for a replay; `nil` is parity.
    let intent: URL?
    /// The derived-data directory this side of the comparison builds into.
    let derivedData: URL
    /// The result bundle path; must not exist yet.
    let resultBundle: URL

    /// The `xcodebuild` arguments, `xcodebuild` itself first.
    var arguments: [String] {
        var arguments = ["xcodebuild", "test"]
        if let project = config.project {
            arguments += ["-project", checkout.appendingPathComponent(project).path]
        } else if let workspace = config.workspace {
            arguments += ["-workspace", checkout.appendingPathComponent(workspace).path]
        }
        arguments += [
            "-scheme",
            config.scheme,
            "-configuration",
            config.resolvedConfiguration,
            "-destination",
            config.destination,
            // The whole target, never one test: a parameterized test selected by name runs nothing.
            "-only-testing:\(config.testTarget)",
            "-derivedDataPath",
            derivedData.path,
            "-resultBundlePath",
            resultBundle.path,
            "CODE_SIGNING_ALLOWED=NO"
        ]
        return arguments
    }

    /// Returns the child environment: `base` with every inherited `TEST_RUNNER_HARUSPEC_*` value
    /// replaced by this run's.
    ///
    /// - Parameter base: The environment to start from, normally this process's.
    /// - Returns: The environment the test runner receives, prefixes intact.
    func environment(from base: [String: String]) -> [String: String] {
        let prefix = "TEST_RUNNER_"
        var environment = base.filter { !$0.key.hasPrefix(prefix + "HARUSPEC_") }
        environment[prefix + ContinuousMode.environmentKey] = mode.rawValue
        environment[prefix + AuditRoot.environmentKey] = checkout.path
        if let plan {
            environment[prefix + ContinuousRun.planPathKey] = plan.path
        }
        if let results {
            environment[prefix + ContinuousRun.resultsDirectoryKey] = results.path
        }
        if let intent {
            environment[prefix + ContinuousRun.intentPathKey] = intent.path
        }
        return environment
    }

    /// The `xcodebuild` output that means the simulator's test host died before any test ran — an
    /// infrastructure failure that says nothing about behavior.
    static let bootstrapFailureSignatures = [
        "operation never finished bootstrapping",
        "crashed before establishing connection"
    ]

    /// Runs the tests, writing all build and test output to `log`, and runs them once more when the
    /// first attempt's test host died before connecting.
    ///
    /// - Parameter log: The file that receives the final attempt's output; a failed first attempt is
    ///   kept beside it as `<name>.attempt-1.log`.
    /// - Returns: `xcodebuild`'s exit status; nonzero also covers a failing test outside the specs.
    /// - Throws: A launch error when `xcodebuild` cannot start.
    func run(log: URL) throws -> Int32 {
        let status = try runOnce(log: log)
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard status != 0, Self.bootstrapFailureSignatures.contains(where: output.contains) else {
            return status
        }
        let firstAttempt = log.deletingPathExtension().appendingPathExtension("attempt-1.log")
        try? FileManager.default.removeItem(at: firstAttempt)
        try FileManager.default.moveItem(at: log, to: firstAttempt)
        return try runOnce(log: log)
    }

    private func runOnce(log: URL) throws -> Int32 {
        // A leftover bundle makes xcodebuild refuse to start; outputs are always this run's own.
        try? FileManager.default.removeItem(at: resultBundle)
        if let results {
            try? FileManager.default.removeItem(at: results)
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        }
        try FileManager.default.createParentDirectory(of: log)
        try FileManager.default.createParentDirectory(of: resultBundle)
        let environment = environment(from: ProcessInfo.processInfo.environment)
        return try Shell.run(arguments, in: checkout, environment: environment, log: log).status
    }
}
