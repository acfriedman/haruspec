import Foundation
import HaruspecSpec

/// The merge base's side of a check: which specs it declares, and one plan per spec stamped with
/// the source files its recording executed — all cached per base commit and plan schema.
///
/// Nothing is checked out or built until something is missing from the cache, so a repeat check on
/// the same base never touches the base at all.
struct BaseSide {
    /// A spec's coverage: the files its recording executed, and the base commit that recording ran at.
    struct Scope {
        /// Repo-relative source files the recording executed.
        let files: Set<String>
        /// The commit the recording ran at — this base, or an older one when predicting.
        let recordedAt: String
    }

    let directory: HaruspecDirectory
    let config: LocalConfig
    let baseSHA: String
    let run: RunDirectory
    let progress: @Sendable (String) -> Void
    private var checkout: BaseCheckout?

    /// Creates the base side of one check; nothing is read or written until asked.
    ///
    /// - Parameters:
    ///   - directory: The repository's `.haruspec/` layout.
    ///   - config: The repository's settings.
    ///   - baseSHA: The merge base's full hash.
    ///   - run: This check's run directory.
    ///   - progress: Receives a line as each step starts.
    init(
        directory: HaruspecDirectory,
        config: LocalConfig,
        baseSHA: String,
        run: RunDirectory,
        progress: @escaping @Sendable (String) -> Void
    ) {
        self.directory = directory
        self.config = config
        self.baseSHA = baseSHA
        self.run = run
        self.progress = progress
    }

    /// Returns the specs the base declares and the suite hosting each, running a census of the base
    /// the first time and reading the cache after.
    ///
    /// - Returns: One marker per declared spec, sorted by name.
    /// - Throws: ``LocalCheckError/noSpecs(_:)`` when the base declares none, and the errors of
    ///   checking out and building the base.
    mutating func catalog() throws -> [CensusMarker] {
        let cached = plans.appendingPathComponent("census", isDirectory: true)
        let markers = CensusMarker.read(from: cached)
        if !markers.isEmpty {
            return markers
        }
        let checkout = try prepared()
        progress("▸ finding the specs the merge base declares (once per base commit)")
        let staged = run.url.appendingPathComponent("census", isDirectory: true)
        var census = XcodeTestRun(
            checkout: checkout.root,
            config: config,
            action: .test(.census),
            derivedData: directory.derivedData("base")
        )
        census.results = staged
        census.resultBundle = run.bundle("census")
        let status = try census.run(log: run.log("census"))
        let found = CensusMarker.read(from: staged)
        guard !found.isEmpty else {
            throw LocalCheckError.noSpecs(
                status == 0
                    ? "\(config.testTarget) declares no continuous specs at the merge base — nothing to check"
                    : "the merge base's census failed before any spec declared itself — see \(run.log("census").path)"
            )
        }
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: staged, to: cached)
        return found
    }

    /// Returns what `spec`'s coverage says about the change: the files its recording at this base
    /// executed, or failing that, the newest recording of it at another base.
    ///
    /// - Parameter spec: A spec name.
    /// - Returns: The coverage and where it came from, or `nil` when no recording of `spec` has any.
    func scope(of spec: String) -> Scope? {
        if let files = Self.coverage(inPlan: plan(for: spec)) {
            return Scope(files: files, recordedAt: baseSHA)
        }
        let schema = "schema-\(SpecPlan.supportedSchemaVersion)"
        let root = directory.cache.appendingPathComponent("plans", isDirectory: true)
        let older = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 != baseSHA }
            .map { root.appendingPathComponent("\($0)/\(schema)/\(spec).plan.json.gz") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { Self.modified($0) > Self.modified($1) }
        for candidate in older {
            if let files = Self.coverage(inPlan: candidate) {
                return Scope(files: files, recordedAt: candidate.pathComponents.dropLast(2).last ?? "")
            }
        }
        return nil
    }

    private static func coverage(inPlan url: URL) -> Set<String>? {
        guard let files = (try? SpecPlan(contentsOf: url))?.provenance?.coverageFiles, !files.isEmpty else {
            return nil
        }
        return Set(files)
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Records `spec` at the base into the cache, stamped with the files the recording worked in
    /// beyond what launching the app runs.
    ///
    /// - Parameter marker: The spec and the suite hosting it; `nil` suite runs the whole target.
    /// - Returns: `nil` once the plan is cached, or the result that ends the spec's check.
    /// - Throws: The errors of checking out and building the base, and file-system errors.
    mutating func record(_ marker: CensusMarker) throws -> LocalCheckOutcome.SpecResult? {
        let checkout = try prepared()
        progress("▸ recording \(marker.spec) at the merge base")
        let bundle = run.bundle("record-\(marker.spec)")
        // Staged in the run directory: a failed recording never lands in the cache.
        let staged = run.url.appendingPathComponent("recording/\(marker.spec).plan.json.gz")
        try FileManager.default.createParentDirectory(of: staged)
        var record = XcodeTestRun(
            checkout: checkout.root,
            config: config,
            action: .test(.record),
            derivedData: directory.derivedData("base")
        )
        record.only = marker.suite.map { ["\(config.testTarget)/\($0.path)"] } ?? []
        record.plan = staged
        record.coverage = true
        record.resultBundle = bundle
        let status = try record.run(log: run.log("record-\(marker.spec)"))
        guard var recorded = try? SpecPlan(contentsOf: staged) else {
            return status == 0
                ? .noBaseline
                : .failed(reason: "recording the merge base failed", log: run.log("record-\(marker.spec)"))
        }
        let counts = try RecordedCoverage.lineCounts(inResultBundle: bundle, under: checkout.root)
        let files = try RecordedCoverage.ownFiles(counts, beyond: startupFootprint(suite: marker.suite))
        if !files.isEmpty {
            recorded.provenance = PlanProvenance(recordedAt: baseSHA, coverageFiles: files)
            try recorded.write(to: staged)
        }
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: plan(for: marker.spec))
        try FileManager.default.moveItem(at: staged, to: plan(for: marker.spec))
        return nil
    }

    /// Returns the line counts of a run that only launches the app host, measured once per base
    /// commit, which a recording's coverage is compared against to find the spec's own files.
    ///
    /// - Parameter suite: A continuous suite to select; in `settle` mode it waits and runs nothing,
    ///   so only the launch and its asynchronous work execute. `nil` when no suite named itself.
    /// - Returns: The launch's line counts, or `nil` without a suite — then nothing is subtracted.
    /// - Throws: The errors of preparing the base, and file-system errors writing the cache.
    private mutating func startupFootprint(suite: ContinuousSuite?) throws -> RecordedCoverage.LineCounts? {
        let cached = plans.appendingPathComponent("startup.coverage.json")
        if let data = try? Data(contentsOf: cached),
           let counts = try? JSONDecoder().decode(RecordedCoverage.LineCounts.self, from: data) {
            return counts
        }
        guard let suite else {
            return nil
        }
        let checkout = try prepared()
        progress("▸ measuring what launching the app runs (once per base commit)")
        var launch = XcodeTestRun(
            checkout: checkout.root,
            config: config,
            action: .test(.settle),
            derivedData: directory.derivedData("base")
        )
        launch.only = ["\(config.testTarget)/\(suite.path)"]
        launch.coverage = true
        launch.resultBundle = run.bundle("startup")
        guard try launch.run(log: run.log("startup")) == 0 else {
            return nil
        }
        let counts = try RecordedCoverage.lineCounts(inResultBundle: run.bundle("startup"), under: checkout.root)
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        try JSONEncoder().encode(counts).write(to: cached)
        return counts
    }

    /// Returns the base checkout, built for testing with coverage, preparing it on first use.
    ///
    /// - Returns: The worktree at the merge base.
    /// - Throws: ``LocalCheckError/buildFailed(_:log:)`` when the base does not build for testing,
    ///   and the errors of ``BaseCheckout/prepare(commit:directory:config:)``.
    private mutating func prepared() throws -> BaseCheckout {
        if let checkout {
            return checkout
        }
        progress("▸ checking out the merge base \(baseSHA.prefix(7)) and building it for testing")
        let prepared = try BaseCheckout.prepare(commit: baseSHA, directory: directory, config: config)
        var build = XcodeTestRun(
            checkout: prepared.root,
            config: config,
            action: .buildForTesting,
            derivedData: directory.derivedData("base")
        )
        build.coverage = true
        guard try build.run(log: run.log("build-base")) == 0 else {
            throw LocalCheckError.buildFailed("the merge base \(baseSHA.prefix(7))", log: run.log("build-base").path)
        }
        checkout = prepared
        return prepared
    }

    /// Returns the plan path for `spec` at this base, whether or not it exists.
    ///
    /// - Parameter spec: A spec name.
    /// - Returns: `<plans>/<spec>.plan.json.gz`.
    func plan(for spec: String) -> URL {
        plans.appendingPathComponent("\(spec).plan.json.gz")
    }

    /// The cache directory for this base's plans and census.
    var plans: URL {
        directory.plans(baseSHA: baseSHA, schema: SpecPlan.supportedSchemaVersion)
    }
}
