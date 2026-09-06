import Foundation
import HaruspecCore

// `haruspec intent` — the CI half of PR-declared intent. The workflow hands it the PR description;
// it resolves every ```haruspec-intent <spec> block through `IntentGrammar` and writes the
// per-spec intent files the replay picks up via `HARUSPEC_INTENT_PATH`.

/// Resolves a PR body's `haruspec-intent` blocks into per-spec intent files — the bridge between
/// "intent declared where the PR is described" and the replay's `HARUSPEC_INTENT_PATH`.
func runIntent(_ rest: [String]) -> Never {
    let (flags, _) = parse(rest)
    guard let bodyPath = flags["body"], !bodyPath.isEmpty else {
        fail("intent needs --body <file>\n\n\(usage)", code: .usage)
    }
    guard let outPath = flags["out"], !outPath.isEmpty else {
        fail("intent needs --out <dir>\n\n\(usage)", code: .usage)
    }
    do {
        let body = try String(contentsOf: URL(fileURLWithPath: bodyPath), encoding: .utf8)
        let intents = try IntentGrammar.intents(inBody: body)
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
