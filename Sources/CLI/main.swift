import Foundation
import HaruspecCore
import HaruspecTrace
import HaruspecDemo
import HaruspecMCP

// A thin, dependency-free CLI over the engine. Subcommands:
//   haruspec diff <baseline.json> <candidate.json> [--tolerance <spec.json>] [--intent <spec.json>] [--agent] [--json]
//   haruspec demo [--out <dir>]
//   haruspec canonicalize <trace.json> [--tolerance <spec.json>] [--out <file.json>]
//
// Exit codes:  0 ok / equivalent · 1 runtime error · 2 usage error · 3 behavioral divergence ·
//              4 cannot-verify (the oracle abstained — an uncovered/un-isolable surface).
// A CI gate should treat BOTH 3 and 4 as non-pass; only 0 is green.

enum ExitCode: Int32 { case ok = 0, runtime = 1, usage = 2, diverged = 3, cannotVerify = 4 }

/// Map a three-tier verdict to the process exit code. The bare two-file `diff` path never produces
/// `.cannotVerify` (it makes no coverage claim); this is shared so the replay/MCP paths stay honest.
func exitCode(for verdict: TraceDiff.Verdict) -> ExitCode {
    switch verdict {
    case .equivalent:   return .ok
    case .diverged:     return .diverged
    case .cannotVerify: return .cannotVerify
    }
}

func fail(_ message: String, code: ExitCode) -> Never {
    FileHandle.standardError.write(Data(("haruspec: " + message + "\n").utf8))
    exit(code.rawValue)
}

/// Pull `--flag value` pairs out of an argument list, returning the flags and the positional rest.
func parse(_ args: [String]) -> (flags: [String: String], positionals: [String]) {
    var flags: [String: String] = [:]
    var positionals: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                flags[key] = args[i + 1]; i += 2
            } else {
                flags[key] = ""; i += 1 // boolean flag
            }
        } else {
            positionals.append(arg); i += 1
        }
    }
    return (flags, positionals)
}

func loadTolerance(_ flags: [String: String]) -> ToleranceSpec {
    guard let path = flags["tolerance"], !path.isEmpty else { return .strict }
    do { return try ToleranceSpec(contentsOf: URL(fileURLWithPath: path)) }
    catch { fail("could not read tolerance spec at \(path): \(error)", code: .runtime) }
}

func loadIntent(_ flags: [String: String]) -> IntentSpec? {
    guard let path = flags["intent"], !path.isEmpty else { return nil }
    do { return try IntentSpec(contentsOf: URL(fileURLWithPath: path)) }
    catch { fail("could not read intent spec at \(path): \(error)", code: .runtime) }
}

let usage = """
haruspec — the behavioral-oracle engine

USAGE:
  haruspec diff <baseline.json> <candidate.json> [--tolerance <spec.json>] [--intent <spec.json>] [--agent] [--json] [--html <path>]
      Diff two captured traces. Exits 3 if they diverge.
      --intent <spec.json>  extension mode: absorb declared changes, gate only on collateral ones.
      --agent               append a relay guide telling a consuming agent how to report the verdict.
      --html <path>         also write a self-contained visual HTML report to <path>.

  haruspec demo [--out <dir>] [--html]
      Capture the built-in checkout scenario (baseline / refactor / regression / feature),
      write the traces, and print the verdicts — including parity vs. extension mode. Great first run.
      --html                also write a visual HTML report per verdict into <dir>.

  haruspec canonicalize <trace.json> [--tolerance <spec.json>] [--out <file.json>]
      Emit the canonical, redacted form of a trace.

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
        if let intent = loadIntent(flags) { result = result.classified(against: intent) }
        if let htmlPath = flags["html"], !htmlPath.isEmpty {
            try result.writeHTMLReport(to: URL(fileURLWithPath: htmlPath))
            FileHandle.standardError.write(Data("haruspec: wrote HTML report to \(htmlPath)\n".utf8))
        }
        if flags["json"] != nil {
            print(String(decoding: try result.jsonData(), as: UTF8.self))
        } else {
            print(result.report())
            if flags["agent"] != nil { print("\n" + result.agentBrief()) }
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
        let baseline = CheckoutScenario.baseline()
        let refactor = CheckoutScenario.refactor()
        let regression = CheckoutScenario.regression()
        let feature = CheckoutScenario.feature()
        try baseline.write(to: outDir.appendingPathComponent("baseline.json"))
        try refactor.write(to: outDir.appendingPathComponent("refactor.json"))
        try regression.write(to: outDir.appendingPathComponent("regression.json"))
        try feature.write(to: outDir.appendingPathComponent("feature.json"))

        let spec = CheckoutScenario.tolerances
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
        let featureDiff = featureRaw.classified(against: CheckoutScenario.intent)
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
        exit((asExpected ? ExitCode.ok : ExitCode.diverged).rawValue)
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
        exit(ExitCode.ok.rawValue)
    } catch {
        fail("canonicalize failed: \(error)", code: .runtime)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(ExitCode.ok.rawValue) }
let rest = Array(arguments.dropFirst())

switch command {
case "diff": runDiff(rest)
case "demo": runDemo(rest)
case "canonicalize": runCanonicalize(rest)
case "mcp": MCPServer().run()
case "help", "--help", "-h": print(usage); exit(ExitCode.ok.rawValue)
default: fail("unknown command \"\(command)\"\n\n\(usage)", code: .usage)
}
