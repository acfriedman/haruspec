import Foundation
import HaruspecCore
import HaruspecSpec

/// The local continuous check: compares the working tree's behavior with the merge base's, on the
/// developer's machine, for the slice of code the change touches.
///
/// A spec is replayed only when the files its base recording executed overlap the files changed
/// since the merge base, and then only its own test suite runs. The base's behavior is recorded once
/// per base commit and plan schema into the cache, so repeat checks pay only the replay.
public struct LocalCheck: Sendable {
    /// What one check compares and under which declarations.
    public struct Options: Sendable {
        /// The branch to compare against; `nil` uses the configuration's.
        public var base: String?
        /// The specs to check; `nil` uses the configuration's, or every declared spec.
        public var specs: [String]?
        /// The intent doc to check under; `nil` uses the current branch's.
        public var intentDocument: URL?
        /// Whether to replay every selected spec, including those the change does not touch.
        public var all: Bool

        /// Creates options; every `nil` falls back to the configuration or the branch.
        ///
        /// - Parameters:
        ///   - base: The branch to compare against.
        ///   - specs: The specs to check.
        ///   - intentDocument: The intent doc to check under.
        ///   - all: Whether to replay specs the change does not touch too.
        public init(base: String? = nil, specs: [String]? = nil, intentDocument: URL? = nil, all: Bool = false) {
            self.base = base
            self.specs = specs
            self.intentDocument = intentDocument
            self.all = all
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

    /// Runs the check: replays every spec the change touches against the working tree, under the
    /// intent doc, recording any missing baseline at the merge base first.
    ///
    /// - Parameter options: What to compare; defaults come from the configuration and branch.
    /// - Returns: One entry per selected spec: its verdict, or why it has none or was not replayed.
    /// - Throws: ``LocalCheckError`` when the comparison cannot be set up — no merge base, an
    ///   unparseable intent doc, a base that declares no specs or does not build — and file-system
    ///   errors writing the cache. A spec whose recording or replay fails is an entry, not a throw.
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
        let changed = try Set(git.changedFiles(since: baseSHA))

        try directory.prepareCache()
        let run = try RunDirectory.create(under: directory.runs)
        var baseSide = BaseSide(directory: directory, config: config, baseSHA: baseSHA, run: run, progress: progress)
        let catalog = try baseSide.catalog()
        let selected = options.specs ?? config.specs ?? catalog.map(\.spec)
        var (results, replaying) = try slice(
            selected,
            of: catalog,
            changed: changed,
            all: options.all,
            base: &baseSide
        )
        try results.merge(replay(replaying, plans: baseSide, intents: intents, run: run)) { $1 }
        let outcome = try LocalCheckOutcome(
            base: base,
            baseSHA: baseSHA,
            headSHA: git.commit("HEAD"),
            branch: branch,
            uncommitted: git.hasUncommittedChanges(),
            entries: selected.map { spec in
                LocalCheckOutcome.Entry(spec: spec, result: results[spec] ?? .failed(reason: "not run", log: nil))
            },
            undeclaredIntent: intents.keys.filter { spec in !replaying.contains { $0.spec == spec } }.sorted(),
            wholeTargetSpecs: replaying.filter { $0.suite == nil }.map(\.spec),
            uncoveredChanges: uncovered(changed, by: selected.compactMap { baseSide.scope(of: $0)?.files }),
            changedFiles: Array(changed).sorted(),
            repositoryRoot: directory.repositoryRoot,
            intentDocument: documentURL,
            runDirectory: run.url
        )
        if let document, let documentURL {
            try write(outcome, asEvidenceIn: document, at: documentURL)
        }
        return outcome
    }

    // MARK: - Steps

    /// Splits the selected specs into those this change touches and those whose check ends here.
    ///
    /// - Parameters:
    ///   - selected: The spec names to check.
    ///   - catalog: The specs the merge base declares, with their suites.
    ///   - changed: Repo-relative files changed since the merge base.
    ///   - all: Whether every declared spec is in the slice regardless of coverage.
    ///   - base: The merge base's side, which records into the cache.
    /// - Returns: The ended specs' results, and the specs to replay in selection order.
    /// - Throws: The errors of preparing and recording the base.
    private func slice(
        _ selected: [String],
        of catalog: [CensusMarker],
        changed: Set<String>,
        all: Bool,
        base: inout BaseSide
    ) throws -> ([String: LocalCheckOutcome.SpecResult], [CensusMarker]) {
        var ended: [String: LocalCheckOutcome.SpecResult] = [:]
        var replaying: [CensusMarker] = []
        for spec in selected {
            guard let marker = catalog.first(where: { $0.spec == spec }) else {
                ended[spec] = .noBaseline
                continue
            }
            let expanded = RecordedCoverage.expandingHeaders(changed)
            if let result = try scope(marker, changed: expanded, all: all, base: &base) {
                ended[spec] = result
            } else {
                replaying.append(marker)
            }
        }
        return (ended, replaying)
    }

    /// Writes `outcome`'s verdicts into the intent doc as evidence, when that changes the file.
    ///
    /// - Parameters:
    ///   - outcome: This check's outcome.
    ///   - document: The intent doc as the check read it.
    ///   - url: The doc's path.
    /// - Throws: A file-system error when the doc cannot be written.
    private func write(_ outcome: LocalCheckOutcome, asEvidenceIn document: IntentDocument, at url: URL) throws {
        var refreshed = document
        outcome.refreshEvidence(in: &refreshed)
        if refreshed != document {
            try Data(refreshed.text.utf8).write(to: url)
        }
    }

    /// Returns the changed source files no spec's recording worked in — the part of the change no
    /// check guards.
    ///
    /// - Parameters:
    ///   - changed: Repo-relative files changed since the merge base.
    ///   - coverage: Each spec's own files.
    /// - Returns: The unguarded source files, sorted; a header counts as guarded when its
    ///   implementation file is.
    private func uncovered(_ changed: Set<String>, by coverage: [Set<String>]) -> [String] {
        let guarded = coverage.reduce(into: Set<String>()) { $0.formUnion($1) }
        let sources: Set = ["swift", "m", "mm", "h", "c", "cc", "cpp"]
        return changed.filter { path in
            sources.contains((path as NSString).pathExtension)
                && RecordedCoverage.expandingHeaders([path]).isDisjoint(with: guarded)
        }.sorted()
    }

    /// Decides whether `marker`'s spec is part of this change's slice, recording its baseline first
    /// when no recording of it says which files it covers.
    ///
    /// - Parameters:
    ///   - marker: The spec and its hosting suite.
    ///   - changed: Repo-relative files changed since the merge base.
    ///   - all: Whether every spec is in the slice regardless of coverage.
    ///   - base: The merge base's side, which records into the cache.
    /// - Returns: `nil` to replay the spec, or the result that ends its check — untouched, or no
    ///   baseline.
    /// - Throws: The errors of preparing and recording the base.
    private func scope(
        _ marker: CensusMarker,
        changed: Set<String>,
        all: Bool,
        base: inout BaseSide
    ) throws -> LocalCheckOutcome.SpecResult? {
        // Coverage from an older base predicts the slice before paying for a recording at this one.
        if !all, let scope = base.scope(of: marker.spec), scope.files.isDisjoint(with: changed) {
            return .untouched(recordedAt: scope.recordedAt)
        }
        if !FileManager.default.fileExists(atPath: base.plan(for: marker.spec).path),
           let ended = try base.record(marker) {
            return ended
        }
        if !all, let scope = base.scope(of: marker.spec), scope.files.isDisjoint(with: changed) {
            return .untouched(recordedAt: scope.recordedAt)
        }
        return nil
    }

    /// Builds the working tree once and replays each spec's own suite against it.
    ///
    /// - Parameters:
    ///   - markers: The specs in the slice and their hosting suites.
    ///   - plans: The merge base's side, holding each spec's cached plan.
    ///   - intents: The intent doc's declarations, by spec.
    ///   - run: This check's run directory.
    /// - Returns: Each spec's result; empty when `markers` is.
    /// - Throws: File-system errors writing the run directory.
    private func replay(
        _ markers: [CensusMarker],
        plans: BaseSide,
        intents: [String: Intent],
        run: RunDirectory
    ) throws -> [String: LocalCheckOutcome.SpecResult] {
        guard !markers.isEmpty else {
            return [:]
        }
        progress("▸ building the working tree for testing")
        let build = XcodeTestRun(
            checkout: directory.repositoryRoot,
            config: config,
            action: .buildForTesting,
            derivedData: directory.derivedData("head")
        )
        guard try build.run(log: run.log("build-head")) == 0 else {
            let failure = LocalCheckOutcome.SpecResult.failed(
                reason: "the working tree does not build for testing",
                log: run.log("build-head")
            )
            return Dictionary(uniqueKeysWithValues: markers.map { ($0.spec, failure) })
        }
        var results: [String: LocalCheckOutcome.SpecResult] = [:]
        for marker in markers {
            results[marker.spec] = try replay(
                marker,
                plan: plans.plan(for: marker.spec),
                intent: intents[marker.spec],
                run: run
            )
        }
        return results
    }

    private func replay(
        _ marker: CensusMarker,
        plan: URL,
        intent: Intent?,
        run: RunDirectory
    ) throws -> LocalCheckOutcome.SpecResult {
        let spec = marker.spec
        progress("▸ replaying \(spec) against the working tree" + (intent == nil ? "" : " under its declared intent"))
        var test = XcodeTestRun(
            checkout: directory.repositoryRoot,
            config: config,
            action: .test(.replay),
            derivedData: directory.derivedData("head")
        )
        test.only = marker.suite.map { ["\(config.testTarget)/\($0.path)"] } ?? []
        test.plan = plan
        test.results = run.url.appendingPathComponent("results/\(spec)", isDirectory: true)
        test.resultBundle = run.bundle("replay-\(spec)")
        if let intent {
            let file = run.url.appendingPathComponent("intent/\(spec).intent.json")
            try FileManager.default.createParentDirectory(of: file)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(intent).write(to: file)
            test.intent = file
        }
        let status = try test.run(log: run.log("replay-\(spec)"))
        let artifact = run.url.appendingPathComponent("results/\(spec)/result.json")
        guard let verdict = try? SpecVerdict(contentsOf: artifact) else {
            let reason = "the replay wrote no verdict (a build or test failure)"
            return .failed(reason: reason, log: run.log("replay-\(spec)"))
        }
        // A red verdict fails its own test; only a run that failed despite a passing verdict had
        // other tests fail beside it.
        let otherFailures = status != 0 && LocalCheckOutcome.exitCode(for: verdict) == 0
        return .verdict(verdict, artifact: artifact, otherFailures: otherFailures ? run.log("replay-\(spec)") : nil)
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
