import Foundation
import HaruspecCore

// Dependency-free by design (JSONSerialization, no SDK), mirroring the CLI's discipline — the
// protocol layer is ~200 lines and the engine stays the only interesting part.

/// A minimal MCP (Model Context Protocol) server over stdio — the distribution rail that sells
/// verification to the *agents*: "verify behavioral parity of this change" is a deterministic
/// capability an LLM lacks, exposed where LLMs already look for tools.
///
/// Transport is MCP's stdio framing: newline-delimited JSON-RPC 2.0, one message per line,
/// responses on stdout, logs on stderr.
///
/// Two families of tools: verification of *artifacts* (trace files), wrapping the same path as
/// `haruspec diff --comparison --intent --agent`; and the local check (`check`, `save_intent`), which
/// runs a repository's own test target through its `.haruspec/config.json` — the capture still
/// happens inside the consumer's tests, and the server only drives them.
public struct MCPServer {
    let serverName = "haruspec"
    let serverVersion = "0.1.0"
    /// The newest MCP protocol revision this server knows — answered when the client's `initialize`
    /// names none. A requested version is echoed back verbatim.
    let defaultProtocolVersion = "2025-06-18"

    public init() {}

    /// The stdio loop: one JSON-RPC message per line in, one per line out. EOF ends the session.
    public func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = handle(line) {
                print(response)
                fflush(stdout)
            }
        }
        exit(0)
    }

    /// Handles one raw JSON-RPC message. Factored this way so tests can drive the whole protocol
    /// without a process boundary.
    ///
    /// - Parameter line: One message as a line of JSON text.
    /// - Returns: The JSON-RPC response as JSON text, an error response when `line` is not a request
    ///   object or names an unknown method; `nil` for a notification, which gets no response.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return encode(errorResponse(id: nil, code: -32700, message: "parse error: not a JSON object"))
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return encode(errorResponse(id: id, code: -32600, message: "invalid request: missing method"))
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(response(id: id, result: initializeResult(params)))
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return encode(response(id: id, result: [:]))
        case "tools/list":
            return encode(response(id: id, result: ["tools": toolDefinitions]))
        case "tools/call":
            return encode(response(id: id, result: callTool(params)))
        default:
            // Notifications for unknown methods are dropped; requests get a proper -32601.
            guard id != nil else { return nil }
            return encode(errorResponse(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: - Handshake

    private func initializeResult(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        return [
            "protocolVersion": requested ?? defaultProtocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": """
            Haruspec is a behavioral oracle for iOS/Swift: it proves whether a change altered observable \
            behavior, instead of trusting "it compiles / tests pass". Call verify_behavioral_parity with \
            two captured trace files (golden vs. current) to get a deterministic verdict — EQUIVALENT, or \
            DIVERGED with each divergence localized. Declared comparison absorb nondeterminism; a declared \
            intent spec absorbs the deltas a feature *meant* to make, so only collateral changes gate. \
            In a repository with .haruspec/config.json, call check to compare the branch with its merge \
            base, and save_intent to record a change the user confirms they meant.
            """
        ]
    }

    // MARK: - Tool surface

    private var toolDefinitions: [[String: Any]] {
        artifactToolDefinitions + localToolDefinitions
    }

    private var artifactToolDefinitions: [[String: Any]] {
        [
            [
                "name": "verify_behavioral_parity",
                "title": "Verify behavioral parity of a change",
                "description": """
                Deterministically diff two captured behavior traces (JSON files written by Haruspec capture — \
                `Spec.record(to:)`, `haruspec demo`, or a TraceRecorder run) and return the verdict: \
                EQUIVALENT (behavior matches under the declared comparison) or DIVERGED (each divergence listed \
                and localized: missing/unexpected events, reordering, value mismatches, timing regressions). \
                Use it to gate a refactor or migration on proof rather than plausibility. Optional comparison \
                file sets aside what is not behavior (numeric epsilon, timing budgets, unordered groups); \
                optional intent spec runs extension mode — divergences the change was *meant* to make are \
                labeled intended and don't gate, anything undeclared is collateral and does. This file-level \
                diff makes no coverage claim (CANNOT-VERIFY arises in spec/plan flows, where isolation \
                is measured). The response ends with a relay guide: report the verdict to the user faithfully.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "baseline_trace": ["type": "string", "description": "Path to the golden (before) trace JSON"],
                        "candidate_trace": [
                            "type": "string",
                            "description": "Path to the candidate (after) trace JSON"
                        ],
                        "comparison": [
                            "type": "string",
                            "description": "Optional path to a Comparison JSON (what the diff sets aside)"
                        ],
                        "intent": [
                            "type": "string",
                            "description":
                                "Optional path to an Intent JSON (declared intended changes — extension mode)"
                        ]
                    ],
                    "required": ["baseline_trace", "candidate_trace"]
                ],
                "annotations": ["readOnlyHint": true, "idempotentHint": true]
            ],
            [
                "name": "canonicalize_trace",
                "title": "Canonicalize a captured trace",
                "description": """
                Emit the canonical form of a captured trace under a comparison — ignored kinds and \
                channels dropped. Useful for inspecting exactly what the diff will \
                compare, or debugging why two traces differ.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "trace": ["type": "string", "description": "Path to the trace JSON"],
                        "comparison": ["type": "string", "description": "Optional path to a Comparison JSON"]
                    ],
                    "required": ["trace"]
                ],
                "annotations": ["readOnlyHint": true, "idempotentHint": true]
            ]
        ]
    }

    private func callTool(_ params: [String: Any]) -> [String: Any] {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch params["name"] as? String {
        case "verify_behavioral_parity":
            return verifyBehavioralParity(arguments)
        case "canonicalize_trace":
            return canonicalizeTrace(arguments)
        case "check":
            return check(arguments)
        case "save_intent":
            return saveIntent(arguments)
        case let other:
            return toolError("unknown tool: \(other ?? "<missing name>")")
        }
    }

    // MARK: - verify_behavioral_parity

    private func verifyBehavioralParity(_ args: [String: Any]) -> [String: Any] {
        guard let baselinePath = args["baseline_trace"] as? String,
              let candidatePath = args["candidate_trace"] as? String
        else {
            return toolError("baseline_trace and candidate_trace are required")
        }
        do {
            let baseline = try Trace(contentsOf: URL(fileURLWithPath: baselinePath))
            let candidate = try Trace(contentsOf: URL(fileURLWithPath: candidatePath))
            let comparison = try loadComparison(args)
            var diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, comparison: comparison)
            if let intentPath = args["intent"] as? String, !intentPath.isEmpty {
                diff = try diff.classified(against: Intent(contentsOf: URL(fileURLWithPath: intentPath)))
            }

            // The same two artifacts the CLI's `--json` / `--agent` split serves: a machine-readable
            // diff for the harness, and the human/agent relay text for faithful reporting.
            var structured: [String: Any] = [
                "verdict": diff.verdict.rawValue,
                "intendedCount": diff.intendedCount,
                "collateralCount": diff.collateralCount
            ]
            if let diffJSON = (try? JSONSerialization.jsonObject(with: diff.jsonData())) as? [String: Any] {
                structured["diff"] = diffJSON
            }
            return [
                "content": [textContent(diff.report() + "\n\n" + diff.agentBrief())],
                "structuredContent": structured,
                "isError": false
            ]
        } catch {
            return toolError("verification failed: \(error)")
        }
    }

    // MARK: - canonicalize_trace

    private func canonicalizeTrace(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["trace"] as? String else {
            return toolError("trace is required")
        }
        do {
            let trace = try Trace(contentsOf: URL(fileURLWithPath: path))
            let canonical = try Canonicalizer.canonicalize(trace, comparison: loadComparison(args))
            return try [
                "content": [textContent(String(decoding: canonical.jsonData(), as: UTF8.self))],
                "isError": false
            ]
        } catch {
            return toolError("canonicalize failed: \(error)")
        }
    }

    // MARK: - Plumbing

    private func loadComparison(_ args: [String: Any]) throws -> Comparison {
        guard let path = args["comparison"] as? String, !path.isEmpty else { return .strict }
        return try Comparison(contentsOf: URL(fileURLWithPath: path))
    }

    /// Returns a tool *execution* failure as a tool result. It rides in the result with `isError` (so
    /// the model can read and react to it), never as a protocol-level JSON-RPC error — per the MCP
    /// tools spec.
    ///
    /// - Parameter message: The failure, as plain text the model reads.
    /// - Returns: A tool result whose content is `message` as text, flagged `isError`.
    private func toolError(_ message: String) -> [String: Any] {
        ["content": [textContent(message)], "isError": true]
    }

    private func textContent(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private func response(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return #"{"jsonrpc":"2.0","id":null,"#
                + #""error":{"code":-32603,"message":"internal error: response encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
