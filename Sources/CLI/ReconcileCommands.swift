import Foundation
import HaruspecSpec

// `haruspec stamp` / `haruspec sweep` — the CLI half of record-on-merge. The record job stamps a
// freshly recorded plan with its provenance (checkout SHA + executed sources), and the sweep reads
// every committed plan's stamp, asks git what changed since, and prints the reconciliation the
// workflow acts on. The decision logic lives in `PlanSweep`; this file only feeds it the repository.

/// Writes a `PlanProvenance` stamp into an existing plan artifact, in place.
func runStamp(_ rest: [String]) -> Never {
    let (flags, _) = parse(rest)
    guard let planPath = flags["plan"], !planPath.isEmpty else {
        fail("stamp needs --plan <plan.json[.gz]>\n\n\(usage)", code: .usage)
    }
    guard let recordedAt = flags["recorded-at"], !recordedAt.isEmpty else {
        fail("stamp needs --recorded-at <sha>\n\n\(usage)", code: .usage)
    }
    guard let coveragePath = flags["coverage"], !coveragePath.isEmpty else {
        fail("stamp needs --coverage <file> (newline-separated repo-relative paths)\n\n\(usage)", code: .usage)
    }
    do {
        let planURL = URL(fileURLWithPath: planPath)
        var plan = try SpecPlan(contentsOf: planURL)
        let coverage = try String(contentsOf: URL(fileURLWithPath: coveragePath), encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
        guard !coverage.isEmpty else {
            // An empty dependency list would make the plan permanently fresh — a recording that
            // executed nothing is a broken coverage extraction, not a plan with no dependencies.
            fail(
                "stamp refused: \(coveragePath) lists no files — a recording always executes "
                    + "sources, so an empty list means the coverage extraction failed",
                code: .runtime
            )
        }
        plan.provenance = PlanProvenance(
            recordedAt: recordedAt,
            coverageFiles: Array(Set(coverage)).sorted()
        )
        try plan.write(to: planURL)
        print("stamped \(plan.specName): recordedAt \(recordedAt), "
            + "\(plan.provenance!.coverageFiles.count) covered files")
        exit(ExitCode.success.rawValue)
    } catch {
        fail("stamp failed: \(error)", code: .runtime)
    }
}

/// Prints the record-on-merge reconciliation for a plans directory as JSON on stdout.
func runSweep(_ rest: [String]) -> Never {
    let (flags, _) = parse(rest)
    guard let plansPath = flags["plans"], !plansPath.isEmpty else {
        fail("sweep needs --plans <dir>\n\n\(usage)", code: .usage)
    }
    guard let rootPath = flags["root"], !rootPath.isEmpty else {
        fail("sweep needs --root <repo checkout>\n\n\(usage)", code: .usage)
    }
    do {
        var plans: [(spec: String, plan: SpecPlan)] = []
        var unreadable: [(spec: String, reason: String)] = []
        for url in try planURLs(in: URL(fileURLWithPath: plansPath, isDirectory: true)) {
            guard let spec = ContinuousRun.specName(inPlanPath: url.path) else { continue }
            do {
                try plans.append((spec: spec, plan: SpecPlan(contentsOf: url)))
            } catch {
                // An artifact the current engine cannot read has no usable baseline: record fresh.
                // A schema bump landing in the engine re-records every plan this way, unguarded —
                // there is nothing left to attribute a delta against.
                unreadable.append((spec: spec, reason: "\(error)"))
            }
        }
        var sweep = try PlanSweep.run(
            plans: plans,
            census: censusSpecs(flags["census"]),
            testSources: flags["test-sources"].flatMap { $0.isEmpty ? nil : $0 },
            changedFiles: { try changedFiles(root: rootPath, since: $0) }
        )
        for (spec, reason) in unreadable.sorted(by: { $0.spec < $1.spec }) {
            sweep.unreadable.append(spec)
            sweep.reasons[spec] = "plan artifact is unreadable (\(reason)) — re-record"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let json = try encoder.encode(sweep)
        print(String(bytes: json, encoding: .utf8) ?? "")
        FileHandle.standardError.write(Data(sweep.summaryLines.utf8))
        exit(ExitCode.success.rawValue)
    } catch {
        fail("sweep failed: \(error)", code: .runtime)
    }
}

/// Returns the committed plan artifacts under `directory` (the `<spec>.plan.json[.gz]` convention);
/// anything else in the directory — a README, a result — is not a plan and is skipped.
private func planURLs(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { ContinuousRun.specName(inPlanPath: $0.path) != nil }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Returns the spec names a census run wrote into `path` (`<spec>.census.json` markers), or `nil`
/// when no census directory was supplied.
private func censusSpecs(_ path: String?) throws -> [String]? {
    guard let path, !path.isEmpty else { return nil }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent)
        .filter { $0.hasSuffix(".census.json") }
        .map { String($0.dropLast(".census.json".count)) }
        .sorted()
}

/// Returns `git diff --name-only <sha>..HEAD` for the checkout at `root`.
///
/// A failing git — an unknown commit, history too shallow to reach it — throws, which the sweep
/// reads as "freshness cannot be proven".
private func changedFiles(root: String, since sha: String) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", root, "diff", "--name-only", sha, "HEAD"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        struct GitDiffFailure: Error, CustomStringConvertible {
            let description: String
        }
        let detail = String(bytes: errors, encoding: .utf8) ?? ""
        throw GitDiffFailure(
            description: "git diff \(sha)..HEAD exited \(process.terminationStatus): "
                + detail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    return (String(bytes: output, encoding: .utf8) ?? "")
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.isEmpty }
}
