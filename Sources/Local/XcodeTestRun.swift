import Foundation
import HaruspecSpec

/// One `xcodebuild` invocation of a check: building a checkout for testing once, or running
/// selected tests against that build in one continuous mode without rebuilding.
///
/// Never passes `-sdk`: it overrides `SDKROOT` for the macro host tool, and every macro expansion
/// then fails with "produced malformed response". The destination alone selects the platform.
struct XcodeTestRun {
    /// What the invocation does.
    enum Action {
        /// `build-for-testing`: compile the app and test bundle once.
        case buildForTesting
        /// `test-without-building` in `mode`: run tests against the last build.
        case test(ContinuousMode)
    }

    /// The checkout the project paths resolve against — the repository or the base worktree.
    let checkout: URL
    /// The repository's settings.
    let config: LocalConfig
    /// Build, or test in a mode.
    let action: Action
    /// The tests to run as `-only-testing:` identifiers (`Target/Suite`); empty runs the whole
    /// test target. Ignored when building.
    var only: [String] = []
    /// The plan to record into or replay; `nil` when building or in census mode.
    var plan: URL?
    /// Where the run writes `result.json` or census markers; `nil` when building or recording.
    var results: URL?
    /// The per-spec intent file for a replay; `nil` is parity.
    var intent: URL?
    /// Whether the build is instrumented for, and the run collects, code coverage.
    var coverage = false
    /// The derived-data directory this side of the comparison builds into.
    let derivedData: URL
    /// The result bundle path; `nil` when building.
    var resultBundle: URL?

    /// Creates a build invocation, or a test invocation to be narrowed with the `var` properties.
    ///
    /// - Parameters:
    ///   - checkout: The checkout the project paths resolve against.
    ///   - config: The repository's settings.
    ///   - action: Build, or test in a mode.
    ///   - derivedData: The derived-data directory for this side of the comparison.
    init(checkout: URL, config: LocalConfig, action: Action, derivedData: URL) {
        self.checkout = checkout
        self.config = config
        self.action = action
        self.derivedData = derivedData
    }

    /// The `xcodebuild` output that means the simulator's test host died before any test ran — an
    /// infrastructure failure that says nothing about behavior.
    static let bootstrapFailureSignatures = [
        "operation never finished bootstrapping",
        "crashed before establishing connection"
    ]

    /// Runs the invocation, writing all output to `log`, and runs a test invocation once more when
    /// the first attempt's test host died before connecting.
    ///
    /// - Parameter log: The file that receives the final attempt's output; a failed first attempt is
    ///   kept beside it as `<name>.attempt-1.log`.
    /// - Returns: `xcodebuild`'s exit status; for a test run, nonzero also covers a failing test
    ///   outside the specs.
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
        if let resultBundle {
            try? FileManager.default.removeItem(at: resultBundle)
            try FileManager.default.createParentDirectory(of: resultBundle)
        }
        if let results {
            try? FileManager.default.removeItem(at: results)
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        }
        try FileManager.default.createParentDirectory(of: log)
        let environment = environment(from: ProcessInfo.processInfo.environment)
        return try Shell.run(arguments, in: checkout, environment: environment, log: log).status
    }

    /// Returns the child environment: `base` with every inherited `TEST_RUNNER_HARUSPEC_*` value
    /// replaced by this run's.
    ///
    /// - Parameter base: The environment to start from, normally this process's.
    /// - Returns: The environment the test runner receives, prefixes intact.
    func environment(from base: [String: String]) -> [String: String] {
        let prefix = "TEST_RUNNER_"
        var environment = base.filter { !$0.key.hasPrefix(prefix + "HARUSPEC_") }
        guard case let .test(mode) = action else {
            return environment
        }
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

    /// The `xcodebuild` arguments, `xcodebuild` itself first.
    var arguments: [String] {
        var arguments = ["xcodebuild"]
        switch action {
        case .buildForTesting:
            arguments.append("build-for-testing")
        case .test:
            arguments.append("test-without-building")
        }
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
            "-derivedDataPath",
            derivedData.path
        ]
        if case .test = action {
            // A suite, or the whole target — never one parameterized function, which selects nothing.
            let selection = only.isEmpty ? [config.testTarget] : only
            arguments += selection.map { "-only-testing:\($0)" }
            if let resultBundle {
                arguments += ["-resultBundlePath", resultBundle.path]
            }
        }
        if coverage {
            arguments += ["-enableCodeCoverage", "YES"]
        }
        arguments.append("CODE_SIGNING_ALLOWED=NO")
        return arguments
    }
}

/// What a recording executed, read from its result bundle's code coverage, and which of it was the
/// spec's own work rather than the app launching around it.
enum RecordedCoverage {
    /// Per repo-relative file, the execution count of every line that ran at least once.
    typealias LineCounts = [String: [Int: Int]]

    /// Returns the line counts of `checkout`'s files in the run that wrote `bundle`.
    ///
    /// - Parameters:
    ///   - bundle: A result bundle from a run with `-enableCodeCoverage YES`.
    ///   - checkout: The checkout the run built; files outside it, such as packages, are left out.
    /// - Returns: The counts; empty when the bundle holds no coverage.
    /// - Throws: A launch error when `xccov` cannot start.
    static func lineCounts(inResultBundle bundle: URL, under checkout: URL) throws -> LineCounts {
        let result = try Shell.run(["xcrun", "xccov", "view", "--archive", "--json", bundle.path])
        guard result.status == 0,
              let archive = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            return [:]
        }
        let root = checkout.path + "/"
        var counts: LineCounts = [:]
        for (path, lines) in archive where path.hasPrefix(root) {
            var ran: [Int: Int] = [:]
            for line in (lines as? [[String: Any]]) ?? [] {
                if let number = line["line"] as? Int, let count = line["executionCount"] as? Int, count > 0 {
                    ran[number] = count
                }
            }
            if !ran.isEmpty {
                counts[String(path.dropFirst(root.count))] = ran
            }
        }
        return counts
    }

    /// Returns the files a recording worked in itself: those with a line that ran more often than
    /// it did while the app merely launched.
    ///
    /// - Parameters:
    ///   - recording: The recording's line counts.
    ///   - startup: The line counts of a run that only launched the app; `nil` counts every file
    ///     the recording executed.
    /// - Returns: The spec's own files, sorted.
    static func ownFiles(_ recording: LineCounts, beyond startup: LineCounts?) -> [String] {
        recording.compactMap { file, lines in
            let launched = startup?[file] ?? [:]
            return lines.contains { $0.value > (launched[$0.key] ?? 0) } ? file : nil
        }.sorted()
    }

    /// Returns `changed` with each changed header standing for its implementation files too, since
    /// coverage never counts a header's lines.
    ///
    /// - Parameter changed: Repo-relative changed paths.
    /// - Returns: `changed` plus, for each header, the same path with the extensions `m`, `mm`, `c`,
    ///   and `cpp`.
    static func expandingHeaders(_ changed: Set<String>) -> Set<String> {
        var expanded = changed
        for path in changed where path.hasSuffix(".h") {
            let stem = String(path.dropLast(2))
            expanded.formUnion(["m", "mm", "c", "cpp"].map { "\(stem).\($0)" })
        }
        return expanded
    }
}
