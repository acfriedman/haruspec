import Foundation
import HaruspecCore
@testable import HaruspecMCP
import XCTest

// Drives the MCP server exactly as a client does — one JSON-RPC line in, one out — through the
// full handshake and both tools, including the divergence and failure paths. No process boundary:
// `handle(_:)` IS the wire protocol minus stdio.

final class MCPServerTests: XCTestCase {
    private let server = MCPServer()

    private func send(_ object: [String: Any]) -> [String: Any]? {
        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
            XCTFail("request object is not encodable as JSON")
            return nil
        }
        let line = String(decoding: encoded, as: UTF8.self)
        guard let reply = server.handle(line) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
    }

    private func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let reply = send(["jsonrpc": "2.0",
                          "id": 9,
                          "method": "tools/call",
                          "params": ["name": name, "arguments": arguments]])
        return (reply?["result"] as? [String: Any]) ?? [:]
    }

    private func text(of result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// Two tiny traces on disk: a golden, an identical copy, and a diverging candidate.
    private func writeTraces() throws -> (golden: URL, same: URL, diverged: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-traces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func trace(_ name: String, total: Int) -> Trace {
            Trace(name: name, events: [
                TraceEvent(seq: 1, kind: .call, label: "Cart.checkout"),
                TraceEvent(
                    seq: 2,
                    kind: .notification,
                    label: "CheckoutCompleted",
                    payload: .object(["total": .int(Int64(total))]),
                    tier: .semantic
                ),
                TraceEvent(seq: 3, kind: .ret, label: "Cart.checkout")
            ])
        }
        let golden = dir.appendingPathComponent("golden.json")
        let same = dir.appendingPathComponent("same.json")
        let diverged = dir.appendingPathComponent("diverged.json")
        try trace("golden", total: 100).write(to: golden)
        try trace("same", total: 100).write(to: same)
        try trace("diverged", total: 101).write(to: diverged)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (golden, same, diverged)
    }

    func testHandshakeAndToolListing() {
        let initReply = send(["jsonrpc": "2.0",
                              "id": 1,
                              "method": "initialize",
                              "params": ["protocolVersion": "2025-06-18",
                                         "clientInfo": ["name": "test", "version": "0"],
                                         "capabilities": [:]]])
        let result = initReply?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result?["serverInfo"] as? [String: Any])?["name"])

        // `initialized` is a notification: no response line may be written.
        XCTAssertNil(send(["jsonrpc": "2.0", "method": "notifications/initialized"]))

        let listReply = send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = ((listReply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["verify_behavioral_parity", "canonicalize_trace"])
        XCTAssertTrue(
            tools.allSatisfy { ($0["inputSchema"] as? [String: Any]) != nil },
            "every tool must publish a JSON Schema for its inputs"
        )
    }

    func testEquivalentTracesVerifyEquivalent() throws {
        let traces = try writeTraces()
        let result = callTool(
            "verify_behavioral_parity",
            ["baseline_trace": traces.golden.path, "candidate_trace": traces.same.path]
        )

        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = result["structuredContent"] as? [String: Any]
        XCTAssertEqual(structured?["verdict"] as? String, "equivalent")
        XCTAssertTrue(text(of: result).contains("EQUIVALENT"))
    }

    func testDivergenceIsReportedWithRelayGuide() throws {
        let traces = try writeTraces()
        let result = callTool(
            "verify_behavioral_parity",
            ["baseline_trace": traces.golden.path, "candidate_trace": traces.diverged.path]
        )

        XCTAssertEqual(result["isError"] as? Bool, false, "a divergence is a verdict, not a tool failure")
        let structured = result["structuredContent"] as? [String: Any]
        XCTAssertEqual(structured?["verdict"] as? String, "diverged")
        let diff = structured?["diff"] as? [String: Any]
        XCTAssertGreaterThan((diff?["divergences"] as? [Any])?.count ?? 0, 0)
        XCTAssertTrue(text(of: result).contains("DIVERGED"))
        XCTAssertFalse(text(of: result).isEmpty, "the agent relay guide rides in the text content")
    }

    func testIntentAbsorbsDeclaredDeltaOverMCP() throws {
        let traces = try writeTraces()
        let intent = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-\(UUID().uuidString).json")
        try Data(#"{"expectedValueChanges": {"CheckoutCompleted": ["total"]}}"#.utf8).write(to: intent)
        addTeardownBlock { try? FileManager.default.removeItem(at: intent) }

        let result = callTool(
            "verify_behavioral_parity",
            ["baseline_trace": traces.golden.path,
             "candidate_trace": traces.diverged.path,
             "intent": intent.path]
        )
        let structured = result["structuredContent"] as? [String: Any]
        XCTAssertEqual(
            structured?["verdict"] as? String,
            "equivalent",
            "the declared value change is intended; nothing collateral remains"
        )
        XCTAssertGreaterThan(structured?["intendedCount"] as? Int ?? 0, 0)
    }

    func testMissingFileIsAToolErrorNotAProtocolError() {
        let result = callTool(
            "verify_behavioral_parity",
            ["baseline_trace": "/nonexistent/a.json", "candidate_trace": "/nonexistent/b.json"]
        )
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertFalse(text(of: result).isEmpty)
    }

    func testCanonicalizeReturnsCanonicalJSON() throws {
        let traces = try writeTraces()
        let result = callTool("canonicalize_trace", ["trace": traces.golden.path])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(text(of: result).contains("Cart.checkout"))
    }

    func testUnknownMethodAndMalformedInput() {
        let unknown = send(["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
        XCTAssertEqual(((unknown?["error"] as? [String: Any])?["code"] as? Int), -32601)

        let garbled = server.handle("not json at all")
        XCTAssertTrue(garbled?.contains("-32700") ?? false)
    }
}
