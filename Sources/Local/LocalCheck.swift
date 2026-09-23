import Foundation
import HaruspecCore
import HaruspecSpec

/// The local continuous check: compares the working tree's behavior with the merge base's, on the
/// developer's machine, with no CI involved.
///
/// The merge base's behavior is recorded once per base commit and plan schema into the cache, so
/// repeat checks on a branch pay only the replay, and an engine upgrade that changes the plan
/// format simply records again.
public struct LocalCheck: Sendable {
    /// What one check compares and under which declarations.
    public struct Options: Sendable {
        /// The branch to compare against; `nil` uses the configuration's.
        public var base: String?
        /// The specs to check; `nil` uses the configuration's, or every declared spec.
        public var specs: [String]?
        /// The intent doc to check under; `nil` uses the current branch's.
        public var intentDocument: URL?

        /// Creates options; every `nil` falls back to the configuration or the branch.
        ///
        /// - Parameters:
        ///   - base: The branch to compare against.
        ///   - specs: The specs to check.
        ///   - intentDocument: The intent doc to check under.
        public init(base: String? = nil, specs: [String]? = nil, intentDocument: URL? = nil) {
            self.base = base
            self.specs = specs
            self.intentDocument = intentDocument
        }
    }

    /// The repository's `.haruspec/` layout.
    public let directory: HaruspecDirectory
    /// The repository's settings.
    public let config: LocalConfig
    /// Receives one line per step, for a person or agent watching a check that takes minutes.
    let progress: @Sendable (String) -> Void

    /// Opens the repository containing `path` and reads its configuration.
    ///
    /// - Parameters:
    ///   - path: Any directory inside the repository.
    ///   - progress: Receives a line as each step starts; never this process's stdout by contract.
    /// - Returns: A check bound to the repository.
    /// - Throws: ``LocalCheckError/notARepository(_:)`` outside a git repository, and the
    ///   configuration errors of ``LocalConfig/load(from:)``.
    public static func at(_ path: URL, progress: @escaping @Sendable (String) -> Void) throws -> LocalCheck {
        let directory = try HaruspecDirectory(repositoryRoot: Git(directory: path).topLevel())
        let config = try LocalConfig.load(from: directory.config)
        return LocalCheck(directory: directory, config: config, progress: progress)
    }

    /// Returns the intent doc a check on the current branch reads.
    ///
    /// - Returns: The doc's path, whether or not it exists.
    /// - Throws: ``LocalCheckError/detachedHead`` when no branch is checked out.
    public func currentIntentDocument() throws -> URL {
        guard let branch = try Git(directory: directory.repositoryRoot).currentBranch() else {
            throw LocalCheckError.detachedHead
        }
        return directory.intentDocument(branch: branch)
    }

    /// Runs the check: records any missing baseline at the merge base, replays every spec against
    /// the working tree under the intent doc, and refreshes the doc's evidence.
    ///
    /// - Parameter options: What to compare; defaults come from the configuration and branch.
    /// - Returns: One entry per spec, with the verdict or the reason there is none.
    /// - Throws: ``LocalCheckError`` when the comparison cannot be set up — no merge base, an
    ///   unparseable intent doc, no declared specs — and file-system errors writing the cache.
    ///   A spec whose build or replay fails is an entry, not a throw.
    public func run(_ options: Options = Options()) throws -> LocalCheckOutcome {
        let git = Git(directory: directory.repositoryRoot)
        let base = options.base ?? config.resolvedBase
        let baseSHA = try git.mergeBase(with: base)
        let branch = try git.currentBranch()
        let documentURL = options.intentDocument ?? branch.map(directory.intentDocument(branch:))
        let document = documentURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(IntentDocument.init(text:))
        let intents = try document?.intents() ?? [:]

        try directory.prepareCache()
        let run = try RunDirectory.create(under: directory.runs)
        let specs = try resolveSpecs(options, run: run)
        let plans = directory.plans(baseSHA: baseSHA, schema: SpecPlan.supportedSchemaVersion)
        var results = try recordMissing(specs, at: baseSHA, into: plans, run: run)
        for spec in specs where results[spec] == nil {
            results[spec] = try replay(
                spec,
                plan: plans.appendingPathComponent("\(spec).plan.json.gz"),
                intent: intents[spec],
                run: run
            )
        }
        let outcome = try LocalCheckOutcome(
            base: base,
            baseSHA: baseSHA,
            headSHA: git.commit("HEAD"),
            branch: branch,
            uncommitted: git.hasUncommittedChanges(),
            entries: specs.map { spec in
                LocalCheckOutcome.Entry(spec: spec, result: results[spec] ?? .failed(reason: "not run", log: nil))
            },
            undeclaredIntent: intents.keys.filter { !specs.contains($0) }.sorted(),
            changedFiles: git.changedFiles(since: baseSHA),
            repositoryRoot: directory.repositoryRoot,
            intentDocument: documentURL,
            runDirectory: run.url
        )
        if let document, let documentURL {
            var refreshed = document
            outcome.refreshEvidence(in: &refreshed)
            if refreshed != document {
                try Data(refreshed.text.utf8).write(to: documentURL)
            }
        }
        return outcome
    }

    // MARK: - Steps

    private func resolveSpecs(_ options: Options, run: RunDirectory) throws -> [String] {
        if let specs = options.specs ?? config.specs {
            return specs
        }
        progress("▸ finding the declared specs (census of \(config.testTarget) at the working tree)")
        let census = run.url.appendingPathComponent("census", isDirectory: true)
        let status = try XcodeTestRun(
            checkout: directory.repositoryRoot,
            config: config,
            mode: .census,
            plan: nil,
            results: census,
            intent: nil,
            derivedData: directory.derivedData("head"),
            resultBundle: run.bundle("census")
        ).run(log: run.log("census"))
        let specs = ((try? FileManager.default.contentsOfDirectory(atPath: census.path)) ?? [])
            .filter { $0.hasSuffix(".census.json") }
            .map { String($0.dropLast(".census.json".count)) }
            .sorted()
        guard !specs.isEmpty else {
            throw LocalCheckError.noSpecs(
                status == 0
                    ? "\(config.testTarget) declares no continuous specs — nothing to check"
                    : "the census run failed before any spec declared itself — see \(run.log("census").path)"
            )
        }
        return specs
    }

    /// Records the merge base's plan for every spec without one in the cache.
    ///
    /// - Parameters:
    ///   - specs: The specs this check covers.
    ///   - baseSHA: The merge base's full hash.
    ///   - plans: The cache directory for plans recorded at `baseSHA` under this engine's schema.
    ///   - run: This check's run directory.
    /// - Returns: The specs that ended without a plan, with the reason; empty when every spec has one.
    /// - Throws: ``LocalCheckError`` when the base worktree cannot be prepared, and file-system
    ///   errors writing the cache.
    private func recordMissing(
        _ specs: [String],
        at baseSHA: String,
        into plans: URL,
        run: RunDirectory
    ) throws -> [String: LocalCheckOutcome.SpecResult] {
        let missing = specs.filter { spec in
            !FileManager.default.fileExists(atPath: plans.appendingPathComponent("\(spec).plan.json.gz").path)
        }
        guard !missing.isEmpty else {
            return [:]
        }
        progress("▸ checking out the merge base \(baseSHA.prefix(7)) to record its behavior (once per base commit)")
        let checkout = try BaseCheckout.prepare(commit: baseSHA, directory: directory, config: config)
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        var ended: [String: LocalCheckOutcome.SpecResult] = [:]
        for spec in missing {
            progress("▸ recording \(spec) at the merge base")
            // Recorded to the run directory first: a failed recording never lands in the cache.
            let staged = run.url.appendingPathComponent("recording/\(spec).plan.json.gz")
            try FileManager.default.createParentDirectory(of: staged)
            let status = try XcodeTestRun(
                checkout: checkout.root,
                config: config,
                mode: .record,
                plan: staged,
                results: nil,
                intent: nil,
                derivedData: directory.derivedData("base"),
                resultBundle: run.bundle("record-\(spec)")
            ).run(log: run.log("record-\(spec)"))
            if (try? SpecPlan(contentsOf: staged)) != nil {
                try FileManager.default.moveItem(at: staged, to: plans.appendingPathComponent(staged.lastPathComponent))
            } else if status == 0 {
                ended[spec] = .noBaseline
            } else {
                ended[spec] = .failed(reason: "recording the merge base failed", log: run.log("record-\(spec)"))
            }
        }
        return ended
    }

    private func replay(
        _ spec: String,
        plan: URL,
        intent: Intent?,
        run: RunDirectory
    ) throws -> LocalCheckOutcome.SpecResult {
        progress("▸ replaying \(spec) against the working tree" + (intent == nil ? "" : " under its declared intent"))
        var intentFile: URL?
        if let intent {
            let file = run.url.appendingPathComponent("intent/\(spec).intent.json")
            try FileManager.default.createParentDirectory(of: file)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(intent).write(to: file)
            intentFile = file
        }
        let results = run.url.appendingPathComponent("results/\(spec)", isDirectory: true)
        let status = try XcodeTestRun(
            checkout: directory.repositoryRoot,
            config: config,
            mode: .replay,
            plan: plan,
            results: results,
            intent: intentFile,
            derivedData: directory.derivedData("head"),
            resultBundle: run.bundle("replay-\(spec)")
        ).run(log: run.log("replay-\(spec)"))
        let artifact = results.appendingPathComponent("result.json")
        guard let verdict = try? SpecVerdict(contentsOf: artifact) else {
            let reason = "the replay wrote no verdict (a build or test failure)"
            return .failed(reason: reason, log: run.log("replay-\(spec)"))
        }
        return .verdict(verdict, artifact: artifact, otherFailures: status == 0 ? nil : run.log("replay-\(spec)"))
    }
}

/// One check's output directory: logs, result bundles, staged recordings, and verdicts.
struct RunDirectory {
    /// How many runs the cache keeps; older ones are deleted when a new run starts.
    static let retained = 10

    /// The run's directory, `runs/<timestamp>`.
    let url: URL

    /// Creates a fresh run directory under `runs` and deletes all but the newest runs.
    ///
    /// - Parameter runs: The cache's runs directory.
    /// - Returns: The new, empty run directory.
    /// - Throws: A file-system error when the directory cannot be created.
    static func create(under runs: URL) throws -> RunDirectory {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = runs.appendingPathComponent(formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(4))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []).sorted()
        for stale in existing.dropLast(retained) {
            try? FileManager.default.removeItem(at: runs.appendingPathComponent(stale))
        }
        return RunDirectory(url: url)
    }

    /// Returns the log file for the step named `step`.
    ///
    /// - Parameter step: A short step name such as `replay-cart`.
    /// - Returns: `logs/<step>.log` inside the run.
    func log(_ step: String) -> URL {
        url.appendingPathComponent("logs/\(step).log")
    }

    /// Returns the result bundle path for the step named `step`.
    ///
    /// - Parameter step: A short step name such as `replay-cart`.
    /// - Returns: `bundles/<step>.xcresult` inside the run.
    func bundle(_ step: String) -> URL {
        url.appendingPathComponent("bundles/\(step).xcresult")
    }
}
