import Foundation
import HaruspecCore

// `haruspec intent` — the CI half of PR-declared intent. The workflow hands it the PR description;
// it resolves every ```haruspec-intent <spec> block through `IntentGrammar` and writes the
// per-spec intent files the replay picks up via `HARUSPEC_INTENT_PATH`.

/// Resolves a PR body's `haruspec-intent` blocks into per-spec intent files — the bridge between
/// "intent declared where the PR is described" and the replay's `HARUSPEC_INTENT_PATH`.
///
/// `--bodies <dir>` is the record-on-merge form: one file per merged PR body, each parsed alone
/// (duplicate spec blocks within one body still refuse), then unioned per spec across bodies —
/// sound there because each body's excuses were individually endorsed by its own merge.
func runIntent(_ rest: [String]) -> Never {
    let (flags, _) = parse(rest)
    guard let outPath = flags["out"], !outPath.isEmpty else {
        fail("intent needs --out <dir>\n\n\(usage)", code: .usage)
    }
    do {
        let intents = try declaredIntents(flags)
        guard !intents.isEmpty else {
            print("no \(IntentGrammar.fenceLabel) blocks — parity mode")
            exit(ExitCode.success.rawValue)
        }
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        for (spec, intent) in intents.sorted(by: { $0.key < $1.key }) {
            let url = outDir.appendingPathComponent("\(spec).intent.json")
            try encoder.encode(intent).write(to: url)
            let texts = intent.declarationTexts
            print("\(spec): \(texts.count + intent.acceptedBlindSpots.count) declaration(s) → \(url.path)")
            for text in texts {
                print("    \(text)")
            }
            for channel in intent.acceptedBlindSpots {
                print("    Accepts(uncaptured: \"\(channel)\")")
            }
        }
        exit(ExitCode.success.rawValue)
    } catch let error as IntentGrammarError {
        fail("could not parse the PR's declared intent\n\(error)", code: .runtime)
    } catch {
        fail("intent failed: \(error)", code: .runtime)
    }
}

/// The per-spec intents the flags select: one `--body` file, or every file under `--bodies`
/// unioned per spec.
private func declaredIntents(_ flags: [String: String]) throws -> [String: Intent] {
    if let bodyPath = flags["body"], !bodyPath.isEmpty {
        let body = try String(contentsOf: URL(fileURLWithPath: bodyPath), encoding: .utf8)
        return try IntentGrammar.intents(inBody: body)
    }
    guard let bodiesPath = flags["bodies"], !bodiesPath.isEmpty else {
        fail("intent needs --body <file> or --bodies <dir>\n\n\(usage)", code: .usage)
    }
    let directory = URL(fileURLWithPath: bodiesPath, isDirectory: true)
    let bodies = try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var merged: [String: Intent] = [:]
    for url in bodies {
        let body = try String(contentsOf: url, encoding: .utf8)
        for (spec, intent) in try IntentGrammar.intents(inBody: body) {
            merged[spec] = merged[spec].map { $0.merging(intent) } ?? intent
        }
    }
    return merged
}
