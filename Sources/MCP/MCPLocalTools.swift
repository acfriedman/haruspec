import Foundation
import HaruspecLocal
import HaruspecSpec

// The local check over MCP: an agent working on a branch runs the same `haruspec check` a developer
// runs, reads the verdict, and — with the developer's agreement — records intended changes in the
// branch's intent doc. Progress goes to stderr; stdout is the protocol channel.

extension MCPServer {
    /// The tool definitions for the local check and the intent doc.
    var localToolDefinitions: [[String: Any]] {
        [
            [
                "name": "check",
                "title": "Check this branch for unintended behavior changes",
                "description": """
                Run the local continuous check in a repository opted in with .haruspec/config.json: \
                record the merge base's behavior (cached per base commit), replay it against the \
                working tree including uncommitted changes, under the branch's intent doc \
                (.haruspec/intent/<branch>.md), and return the verdict per spec. Takes minutes: it \
                builds and tests the app on a simulator. A red spec lists the declarations that would \
                mark its divergences intended — offer them to the user; never declare one they did not \
                mean, because a declared change stops gating. Exit code 0 is the only pass.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "root": rootProperty,
                        "base": ["type": "string", "description": "The branch to compare with"],
                        "specs": ["type": "array", "items": ["type": "string"], "description": "Only these specs"],
                        "all": ["type": "boolean", "description": "Replay specs the change does not touch too"]
                    ]
                ],
                "annotations": ["readOnlyHint": false, "idempotentHint": true]
            ],
            [
                "name": "save_intent",
                "title": "Declare an intended behavior change on this branch",
                "description": """
                Add declarations (the lines a red check offered, edited down to what the user means) \
                to one spec's section of the branch's intent doc, or replace its lines. Each line is \
                validated with the gate's own grammar. The doc is in the PR-description format, so the \
                user can attach it to their PR as evidence. Run check afterwards: it replays under the \
                new declarations and writes its verdict into the doc. An empty list with replace: true \
                removes the spec's section.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "root": rootProperty,
                        "spec": ["type": "string", "description": "The spec the declarations are for"],
                        "declarations": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": #"DSL lines, e.g. Changes("Receipt", field: "total").increases()"#
                        ],
                        "replace": ["type": "boolean", "description": "Replace the spec's lines instead of adding"]
                    ],
                    "required": ["spec", "declarations"]
                ],
                "annotations": ["readOnlyHint": false, "idempotentHint": true]
            ]
        ]
    }

    private var rootProperty: [String: Any] {
        ["type": "string", "description": "A directory inside the repository; default: the server's working directory"]
    }

    /// Runs the local check and returns its report, with one structured entry per spec.
    ///
    /// - Parameter args: The tool call's arguments: optional `root`, `base`, and `specs`.
    /// - Returns: An MCP tool result; `isError` when the check could not be set up.
    func check(_ args: [String: Any]) -> [String: Any] {
        do {
            let check = try LocalCheck.at(root(args)) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            let options = LocalCheck.Options(
                base: args["base"] as? String,
                specs: args["specs"] as? [String],
                all: args["all"] as? Bool ?? false
            )
            let outcome = try check.run(options)
            let specs = outcome.entries.map { entry -> [String: Any] in
                switch entry.result {
                case let .verdict(verdict, artifact, otherFailures):
                    ["spec": entry.spec,
                     "verdict": verdict.verdict.rawValue,
                     "exitCode": LocalCheckOutcome.exitCode(for: verdict),
                     "artifact": artifact.path,
                     "offeredDeclarations": verdict.offeredDeclarations,
                     "otherTestFailuresLog": otherFailures?.path ?? ""]
                case let .untouched(recordedAt):
                    ["spec": entry.spec, "verdict": "untouched", "coverageRecordedAt": recordedAt]
                case .noBaseline:
                    ["spec": entry.spec, "verdict": "no-baseline"]
                case let .failed(reason, log):
                    ["spec": entry.spec, "verdict": "no-verdict", "reason": reason, "log": log?.path ?? ""]
                }
            }
            return [
                "content": [["type": "text", "text": outcome.report()]],
                "structuredContent": [
                    "exitCode": outcome.exitCode,
                    "baseSHA": outcome.baseSHA,
                    "headSHA": outcome.headSHA,
                    "uncommitted": outcome.uncommitted,
                    "intentDocument": outcome.intentDocument?.path ?? "",
                    "runDirectory": outcome.runDirectory.path,
                    "specs": specs
                ],
                "isError": false
            ]
        } catch {
            return localToolError("check failed: \(error)")
        }
    }

    /// Edits the branch's intent doc and returns the spec's declarations as saved.
    ///
    /// - Parameter args: The tool call's arguments: `spec`, `declarations`, optional `replace` and `root`.
    /// - Returns: An MCP tool result; `isError` when a line does not parse or the doc cannot be written.
    func saveIntent(_ args: [String: Any]) -> [String: Any] {
        guard let spec = args["spec"] as? String, let declarations = args["declarations"] as? [String] else {
            return localToolError("spec and declarations are required")
        }
        let replacing = args["replace"] as? Bool ?? false
        do {
            let check = try LocalCheck.at(root(args)) { _ in }
            let url = try check.currentIntentDocument()
            let branch = String(url.deletingPathExtension().path.dropFirst(check.directory.intent.path.count + 1))
            let document = try IntentDocument.update(at: url, branch: branch) { document in
                if replacing, declarations.isEmpty {
                    try document.remove(spec)
                } else {
                    try document.save(declarations, for: spec, replacing: replacing)
                }
            }
            let saved = document.declarations(for: spec)
            let listing = saved.map { "\n    \($0)" }.joined()
            let text = saved.isEmpty
                ? "removed \(spec) from \(url.path)"
                : "\(spec): \(saved.count) declaration(s) in \(url.path)\(listing)\n"
                + "Run check to replay under them; it writes its verdict into the doc as evidence."
            return [
                "content": [["type": "text", "text": text]],
                "structuredContent": ["intentDocument": url.path, "spec": spec, "declarations": saved],
                "isError": false
            ]
        } catch {
            return localToolError("save_intent failed: \(error)")
        }
    }

    private func root(_ args: [String: Any]) -> URL {
        URL(fileURLWithPath: (args["root"] as? String) ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private func localToolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}
