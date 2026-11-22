import HaruspecAudit
import HaruspecTrace
import XCTest

/// Reaches through held stand-ins, and the hand-off spellings the dispatch rule names.
final class HeldStandInLintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A reach through a stand-in the capture held work through is reported, not gated; the same
    /// source with nothing held gates.
    func testAReachThroughAHeldStandInIsReportedWithoutGating() throws {
        try write(
            "import Combine\nfinal class Shipper {\n    func ship() {\n        queue.addOperation { }\n    }\n}\n",
            to: "App/Shipper.swift"
        )
        let origins = [TraceOrigin(label: "S", symbol: "Shipper", source: "App/Shipper.swift")]

        let held = AuditReport.audit(origins: origins, root: root, heldStandIns: ["scheduler", "operationQueue"])
        let unheld = AuditReport.audit(origins: origins, root: root)

        XCTAssertTrue(held.isClean, held.report())
        XCTAssertEqual(held.held.map(\.channel), ["Combine", "dispatch"])
        XCTAssertEqual(held.outcome(accepting: []).entries, ["Combine (held)", "dispatch (held)"])
        XCTAssertTrue(held.report().contains("through a held stand-in"), held.report())
        XCTAssertEqual(Set(unheld.blindSpots), ["Combine", "dispatch"])
    }

    /// A queue of the subject's own making gates beside a held one: the stand-in covers using a
    /// queue, never building one. As a defaulted parameter it is an injection point.
    func testAQueueTheSubjectBuildsGatesEvenBesideAHeldOne() throws {
        try write(
            """
            final class Shipper {
                init(queue: OperationQueue = OperationQueue()) {}
                func ship() {
                    let spare = OperationQueue()
                    spare.addOperation { }
                }
            }
            """,
            to: "App/Shipper.swift"
        )

        let report = AuditReport.audit(
            origins: [TraceOrigin(label: "S", symbol: "Shipper", source: "App/Shipper.swift")],
            root: root,
            heldStandIns: ["operationQueue"]
        )

        XCTAssertEqual(report.bypasses.map(\.line), [4], report.report())
        XCTAssertEqual(report.injectableDefaults.map(\.line), [2])
        XCTAssertEqual(report.held.map(\.line), [5])
    }

    /// Declaring a channel that only held stand-ins reach is a declaration nothing needs.
    func testADeclarationOnlyAHeldReachSatisfiesIsUnmatched() throws {
        try write("import Combine\nfinal class Feed {}\n", to: "App/Feed.swift")

        let report = AuditReport.audit(
            origins: [TraceOrigin(label: "F", symbol: "Feed", source: "App/Feed.swift")],
            root: root,
            heldStandIns: ["scheduler"]
        )
        let outcome = report.outcome(accepting: ["Combine"])

        XCTAssertEqual(outcome.unmatched, ["Combine"], "the declaration is no longer needed")
        XCTAssertEqual(outcome.held, ["Combine"])
        XCTAssertFalse(outcome.gates)
    }

    /// Each newly named hand-off is a dispatch finding on its own.
    func testFindsEveryHandOffSpelling() throws {
        let handOffs = [
            "Task(priority: .high) { }",
            "Task<Void, Never> { }",
            "Task{ }",
            "[queue addOperation:op];",
            "Thread.detachNewThread { }",
            "[self performSelectorInBackground:@selector(load) withObject:nil];",
            "[self performSelectorOnMainThread:@selector(show) withObject:nil waitUntilDone:NO];",
            "NSThread *worker = [[NSThread alloc] init];",
            "dispatch_apply(4, queue, ^(size_t i) {});",
            "DispatchQueue.concurrentPerform(iterations: 4) { _ in }",
            "let timer = DispatchSource.makeTimerSource()",
            "dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);",
            "let item = DispatchWorkItem { }",
            "URLSession.shared.dataTask(with: url) { _, _, _ in }",
            "session.downloadTask(with: url) { _, _, _ in }",
            "session.uploadTask(with: request, from: data) { _, _, _ in }"
        ]
        for (index, handOff) in handOffs.enumerated() {
            let path = "App/HandOff\(index).swift"
            try write("final class Loader {\n    func load() {\n        \(handOff)\n    }\n}\n", to: path)

            let report = audit([TraceOrigin(label: "L", symbol: "Loader", source: path)])

            XCTAssertEqual(report.blindSpots, ["dispatch"], handOff)
        }
    }

    private func write(_ contents: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func audit(_ origins: [TraceOrigin]) -> AuditReport {
        AuditReport.audit(origins: origins, root: root)
    }
}
