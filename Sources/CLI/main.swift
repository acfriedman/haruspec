import Foundation
import HaruspecAudit
import HaruspecCore
import HaruspecDemo
import HaruspecMCP
import HaruspecSpec
import HaruspecTrace

// A thin, dependency-free CLI over the engine. Subcommands:
//   haruspec diff <baseline.json> <candidate.json> [--tolerance <spec.json>] [--intent <spec.json>] [--agent] [--json]
//   haruspec demo [--out <dir>]
//   haruspec canonicalize <trace.json> [--tolerance <spec.json>] [--out <file.json>]
//   haruspec report <result.json> [--markdown] [--html <path>] [--agent]
//   haruspec audit --root <dir> [--verdict <result.json>] [--covering <Sym,Sym>]
//
// Exit codes:  0 ok / equivalent · 1 runtime error · 2 usage error · 3 behavioral divergence ·
//              4 cannot-verify (the oracle abstained — an uncovered/un-isolable surface) ·
//              5 unstable (identical replays disagreed — the verdict cannot be reproduced).
// A CI gate should treat 3, 4 AND 5 as non-pass; only 0 is green.

enum ExitCode: Int32 { case success = 0, runtime = 1, usage = 2, diverged = 3, cannotVerify = 4, unstable = 5 }

/// Maps a four-tier `TraceDiff.Verdict` to the process `ExitCode`. The bare two-file `diff` path never produces
/// `.cannotVerify` or `.unstable` (it makes no coverage or repetition claim); this is shared so the
/// replay/MCP paths stay honest.
func exitCode(for verdict: TraceDiff.Verdict) -> ExitCode {
    switch verdict {
    case .equivalent: .success
    case .diverged: .diverged
    case .cannotVerify: .cannotVerify
    case .unstable: .unstable
    }
}

func fail(_ message: String, code: ExitCode) -> Never {
    FileHandle.standardError.write(Data(("haruspec: " + message + "\n").utf8))
    exit(code.rawValue)
}

/// Pulls `--flag value` pairs out of an argument list, returning the flags and the positional rest.
func parse(_ args: [String]) -> (flags: [String: String], positionals: [String]) {
    var flags: [String: String] = [:]
    var positionals: [String] = []
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                flags[key] = args[index + 1]; index += 2
            } else {
                flags[key] = ""; index += 1 // boolean flag
            }
        } else {
            positionals.append(arg); index += 1
        }
    }
    return (flags, positionals)
}

func loadTolerance(_ flags: [String: String]) -> Tolerance {
    guard let path = flags["tolerance"], !path.isEmpty else { return .strict }
    do {
        return try Tolerance(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("could not read tolerance spec at \(path): \(error)", code: .runtime)
    }
}

func loadIntent(_ flags: [String: String]) -> Intent? {
    guard let path = flags["intent"], !path.isEmpty else { return nil }
    do {
        return try Intent(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("could not read intent spec at \(path): \(error)", code: .runtime)
    }
}

let usage = """
haruspec — the behavioral-oracle engine

USAGE:
  haruspec diff <baseline.json> <candidate.json> [--tolerance <spec.json>] [--intent <spec.json>]\
 [--agent] [--json] [--html <path>]
      Diff two captured traces. Exits 3 if they diverge.
      --intent <spec.json>  extension mode: absorb declared changes, gate only on collateral ones.
      --agent               append a relay guide telling a consuming agent how to report the verdict.
      --html <path>         also write a self-contained visual HTML report to <path>.

  haruspec demo [--out <dir>] [--html]
      Capture the built-in checkout spec (baseline / refactor / regression / feature),
      write the traces, and print the verdicts — including parity vs. extension mode. Great first run.
      --html                also write a visual HTML report per verdict into <dir>.

  haruspec canonicalize <trace.json> [--tolerance <spec.json>] [--out <file.json>]
      Emit the canonical, redacted form of a trace.

  haruspec report <result.json> [--markdown] [--html <path>] [--agent]
      Render a spec verdict artifact (the result.json a verify(replaying:) run writes) and exit
      with its verdict code — the CI gate reads THIS exit code, not the test runner's.
      --markdown            GitHub-flavored markdown (PR comment / job summary) instead of text.
      --html <path>         also write the self-contained visual report to <path>.
      --agent               append the relay guide telling a consuming agent how to report the verdict.

  haruspec audit --root <dir> [--verdict <result.json>] [--covering <Sym,Sym>]
      Capture-completeness audit: resolve the covered declarations to source under <dir>, then read
      that source for effect channels the capture cannot see (NotificationCenter.default, Timer,
      Combine, KVO, delayed dispatch). Exits 4 if any channel is found OR any declaration's source
      cannot be located — both mean the verdict cannot claim it saw everything.
      --verdict <result.json>  audit exactly what that verdict covered (its recorded origins).
      --covering <Sym,Sym>     audit these declarations by name (Obj-C classes, Swift types).

  haruspec mcp
      Serve the engine as MCP tools over stdio (verify_behavioral_parity, canonicalize_trace),
      so agents (Claude Code, Cursor, …) can gate changes on behavioral proof. Register with:
      { "command": "haruspec", "args": ["mcp"] }
"""

func runDiff(_ rest: [String]) -> Never {
    let (flags, positionals) = parse(rest)
    guard positionals.count == 2 else { fail("diff needs <baseline.json> <candidate.json>\n\n\(usage)", code: .usage) }
    let spec = loadTolerance(flags)
    do {
        let baseline = try Trace(contentsOf: URL(fileURLWithPath: positionals[0]))
        let candidate = try Trace(contentsOf: URL(fileURLWithPath: positionals[1]))
        var result = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: spec)
        // With `--intent`, run in extension mode: intended deltas are absorbed, collateral ones gate.
        if let intent = loadIntent(flags) {
            result = result.classified(against: intent)
        }
        if let htmlPath = flags["html"], !htmlPath.isEmpty {
            try result.writeHTMLReport(to: URL(fileURLWithPath: htmlPath))
            FileHandle.standardError.write(Data("haruspec: wrote HTML report to \(htmlPath)\n".utf8))
        }
        if flags["json"] != nil {
            try print(String(decoding: result.jsonData(), as: UTF8.self))
        } else {
            print(result.report())
            if flags["agent"] != nil {
                print("\n" + result.agentBrief())
            }
        }
        exit(exitCode(for: result.verdict).rawValue)
    } catch {
        fail("diff failed: \(error)", code: .runtime)
    }
}

func runDemo(_ rest: [String]) -> Never {
    let (flags, _) = parse(rest)
    let outDir = URL(fileURLWithPath: flags["out"].flatMap { $0.isEmpty ? nil : $0 } ?? "haruspec-demo")
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let baseline = CheckoutSpec.baseline()
        let refactor = CheckoutSpec.refactor()
        let regression = CheckoutSpec.regression()
        let feature = CheckoutSpec.feature()
        try baseline.write(to: outDir.appendingPathComponent("baseline.json"))
        try refactor.write(to: outDir.appendingPathComponent("refactor.json"))
        try regression.write(to: outDir.appendingPathComponent("regression.json"))
        try feature.write(to: outDir.appendingPathComponent("feature.json"))

        let spec = CheckoutSpec.tolerances
        print("Wrote traces to \(outDir.path)\n")
        print("── Refactor · parity mode (expected: EQUIVALENT) ────────────────")
        let refactorDiff = BehavioralDiff.compare(baseline: baseline, candidate: refactor, tolerances: spec)
        print(refactorDiff.report())
        print("\n── Regression · parity mode (expected: DIVERGED) ────────────────")
        let regressionDiff = BehavioralDiff.compare(baseline: baseline, candidate: regression, tolerances: spec)
        print(regressionDiff.report())

        // Extension mode: a feature change (loyalty points) that also carries a collateral regression.
        // Without declared intent every change looks like a regression; with it, the intended deltas
        // are absorbed and only the collateral one gates.
        let featureRaw = BehavioralDiff.compare(baseline: baseline, candidate: feature, tolerances: spec)
        print("\n── Feature · parity mode — no intent, every change is flagged ───")
        print(featureRaw.report())
        let featureDiff = featureRaw.classified(against: CheckoutSpec.intent)
        print("\n── Feature · extension mode — intended vs. collateral ───────────")
        print(featureDiff.report())
        print("\n" + featureDiff.agentBrief())

        if flags["html"] != nil {
            for (name, diff) in [("refactor", refactorDiff), ("regression", regressionDiff), ("feature", featureDiff)] {
                try diff.writeHTMLReport(to: outDir.appendingPathComponent("\(name).html"))
            }
            print("\nWrote HTML reports to \(outDir.path)")
        }

        // The demo's own contract: refactor passes, regression is caught, and extension mode absorbs
        // the two intended deltas while still catching the one collateral regression.
        let asExpected = refactorDiff.isEquivalent && !regressionDiff.isEquivalent
            && !featureDiff.isEquivalent
            && featureDiff.intendedCount == 2 && featureDiff.collateralCount == 1
        exit((asExpected ? ExitCode.success : ExitCode.diverged).rawValue)
    } catch {
        fail("demo failed: \(error)", code: .runtime)
    }
}

func runCanonicalize(_ rest: [String]) -> Never {
    let (flags, positionals) = parse(rest)
    guard positionals.count == 1 else { fail("canonicalize needs <trace.json>\n\n\(usage)", code: .usage) }
    let spec = loadTolerance(flags)
    do {
        let trace = try Trace(contentsOf: URL(fileURLWithPath: positionals[0]))
        let canonical = Canonicalizer.canonicalize(trace, spec: spec)
        let data = try canonical.jsonData()
        if let out = flags["out"], !out.isEmpty {
            try data.write(to: URL(fileURLWithPath: out))
            print("Wrote canonical trace to \(out)")
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(ExitCode.success.rawValue)
    } catch {
        fail("canonicalize failed: \(error)", code: .runtime)
    }
}

/// Capture-completeness audit: resolve what a verdict covered back to source, then lint that source
/// for effect channels the capture cannot see. Static, so it runs on the CI host beside `report` —
/// the verify itself may have run somewhere with no source tree at all (a simulator, a device).
///
/// Exits 4 (CANNOT-VERIFY) on any blind spot, resolved or not: a channel found and a declaration that
/// could not be read are the same fact about the verdict — it cannot claim it saw everything.
func runAudit(_ rest: [String]) -> Never {
    let (flags, _) = parse(rest)
    guard let rootPath = flags["root"], !rootPath.isEmpty else {
        fail("audit needs --root <dir>\n\n\(usage)", code: .usage)
    }
    let root = URL(fileURLWithPath: rootPath)
    do {
        let origins = try auditOrigins(flags)
        guard !origins.isEmpty else {
            fail("audit needs --verdict <result.json> or --covering <Sym,Sym>\n\n\(usage)", code: .usage)
        }
        let report = AuditReport.audit(origins: origins, root: root)
        print(report.report())
        exit(report.isClean ? ExitCode.success.rawValue : ExitCode.cannotVerify.rawValue)
    } catch {
        fail("audit failed: \(error)", code: .runtime)
    }
}

/// The declarations to audit: a verdict's own origins, or symbols named on the command line (the
/// form CI can use before a verdict artifact exists — and the form an Obj-C class needs anyway).
func auditOrigins(_ flags: [String: String]) throws -> [TraceOrigin] {
    if let path = flags["verdict"], !path.isEmpty {
        return try SpecVerdict(contentsOf: URL(fileURLWithPath: path)).qualification.origins
    }
    guard let covering = flags["covering"], !covering.isEmpty else { return [] }
    return covering.split(separator: ",").map { symbol in
        let name = symbol.trimmingCharacters(in: .whitespaces)
        return TraceOrigin(label: name, symbol: name)
    }
}

func runReport(_ rest: [String]) -> Never {
    let (flags, positionals) = parse(rest)
    guard positionals.count == 1 else { fail("report needs <result.json>\n\n\(usage)", code: .usage) }
    do {
        let verdict = try SpecVerdict(contentsOf: URL(fileURLWithPath: positionals[0]))
        if let htmlPath = flags["html"], !htmlPath.isEmpty {
            try verdict.writeHTMLReport(to: URL(fileURLWithPath: htmlPath))
            FileHandle.standardError.write(Data("haruspec: wrote HTML report to \(htmlPath)\n".utf8))
        }
        let markdown = flags["markdown"] != nil
        print(markdown ? verdict.markdownReport() : verdict.report())
        if flags["agent"] != nil {
            // `result` is run 1's single pass; on UNSTABLE its gate (PASS/FAIL) is exactly what the
            // repetition disproved, so the brief must not be relayed as-is.
            let brief = verdict.verdict == .unstable
                ? """
                ── FOR THE AGENT · how to relay this verdict ──
                • Gate: UNSTABLE (exit code 5) — \(verdict.stability.replays) replays of identical \
                recorded inputs disagreed. This check does NOT pass.
                • Do NOT relay any single run's outcome as the verdict; the finding is the run-to-run \
                delta printed above, which points at an unmodeled nondeterministic axis (a missing \
                tolerance, projection, or seam).
                """
                : verdict.result.agentBrief()
            // In markdown mode the brief is machine-facing text, not prose — fence it.
            print(markdown ? "\n```text\n\(brief)\n```" : "\n" + brief)
        }
        exit(exitCode(for: verdict.verdict).rawValue)
    } catch {
        fail("report failed: \(error)", code: .runtime)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(ExitCode.success.rawValue) }
let rest = Array(arguments.dropFirst())

switch command {
case "diff": runDiff(rest)
case "demo": runDemo(rest)
case "canonicalize": runCanonicalize(rest)
case "report": runReport(rest)
case "audit": runAudit(rest)
case "mcp": MCPServer().run()
case "help", "--help", "-h": print(usage); exit(ExitCode.success.rawValue)
default: fail("unknown command \"\(command)\"\n\n\(usage)", code: .usage)
}
