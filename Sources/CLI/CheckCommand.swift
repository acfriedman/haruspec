import Foundation
import HaruspecLocal

// `haruspec check` and `haruspec intent save|remove` — the local, opt-in half of the continuous
// shape. The check compares the merge base with the working tree on the developer's machine; the
// intent subcommands edit the branch's intent doc under `.haruspec/intent/`. The logic lives in
// HaruspecLocal, shared with the MCP server; this file parses flags and prints.

/// Runs the local check and exits with its worst verdict code.
///
/// - Parameter rest: The arguments after `check`: `--base`, `--spec`, `--intent`, `--root`.
func runCheck(_ rest: [String]) -> Never {
    let (flags, positionals) = parse(rest)
    guard positionals.isEmpty else {
        fail("check takes no positional arguments\n\n\(usage)", code: .usage)
    }
    do {
        let check = try LocalCheck.at(rootURL(flags)) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        let options = LocalCheck.Options(
            base: nonEmpty(flags["base"]),
            specs: nonEmpty(flags["spec"]).map { $0.split(separator: ",").map(String.init) },
            intentDocument: nonEmpty(flags["intent"]).map { URL(fileURLWithPath: $0) }
        )
        let outcome = try check.run(options)
        print(outcome.report())
        exit(outcome.exitCode)
    } catch let error as LocalCheckError {
        fail(error.description, code: .runtime)
    } catch {
        fail("check failed: \(error)", code: .runtime)
    }
}

/// Edits the branch's intent doc for `haruspec intent save` and `haruspec intent remove`, validating
/// every line with the grammar the gate uses.
///
/// - Parameters:
///   - subcommand: `"save"` or `"remove"`.
///   - rest: The arguments after the subcommand: the spec, then declarations for `save`, and flags.
func runIntentEdit(_ subcommand: String, _ rest: [String]) -> Never {
    // Stripped before parsing: `--replace` is boolean, and the parser would read the next word as its value.
    let replacing = rest.contains("--replace")
    let (flags, positionals) = parse(rest.filter { $0 != "--replace" })
    guard let spec = positionals.first else {
        fail("intent \(subcommand) needs <spec>\n\n\(usage)", code: .usage)
    }
    let declarations = Array(positionals.dropFirst())
    do {
        let (url, branch) = try intentDocument(flags)
        let document = try IntentDocument.update(at: url, branch: branch) { document in
            if subcommand == "remove" {
                try document.remove(spec)
            } else {
                try document.save(declarations, for: spec, replacing: replacing)
            }
        }
        if subcommand == "remove" {
            print("removed \(spec) from \(url.path)")
        } else {
            let lines = document.declarations(for: spec)
            print("\(spec): \(lines.count) declaration(s) in \(url.path)")
            lines.forEach { print("    \($0)") }
            print("run `haruspec check` to replay under them; the check writes its verdict into the doc as evidence")
        }
        exit(ExitCode.success.rawValue)
    } catch let error as LocalCheckError {
        fail(error.description, code: .runtime)
    } catch {
        fail("intent \(subcommand) failed: \(error)", code: .runtime)
    }
}

/// Returns the intent doc the flags select — `--intent <file>`, or the current branch's.
///
/// - Parameter flags: The parsed command-line flags.
/// - Returns: The doc's path and the name a new doc's title uses.
/// - Throws: ``LocalCheckError`` when the repository is not opted in or `HEAD` is detached.
private func intentDocument(_ flags: [String: String]) throws -> (url: URL, branch: String) {
    if let path = nonEmpty(flags["intent"]) {
        let url = URL(fileURLWithPath: path)
        return (url, url.deletingPathExtension().lastPathComponent)
    }
    let check = try LocalCheck.at(rootURL(flags)) { _ in }
    let url = try check.currentIntentDocument()
    let prefix = check.directory.intent.path + "/"
    return (url, String(url.deletingPathExtension().path.dropFirst(prefix.count)))
}

private func rootURL(_ flags: [String: String]) -> URL {
    URL(fileURLWithPath: nonEmpty(flags["root"]) ?? FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func nonEmpty(_ value: String?) -> String? {
    value.flatMap { $0.isEmpty ? nil : $0 }
}
