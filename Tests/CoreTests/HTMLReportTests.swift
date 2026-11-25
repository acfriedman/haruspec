@testable import HaruspecCore
import XCTest

final class HTMLReportTests: XCTestCase {
    private let valueMismatch = Divergence(
        kind: .valueMismatch,
        label: "cart.total",
        baselineSeq: 3,
        candidateSeq: 3,
        detail: "cart.total: baseline=1200 candidate=1500",
        field: "cart.total",
        baselineValue: 1200,
        candidateValue: 1500
    )
    private let missing = Divergence(
        kind: .missingEvent,
        label: "LoyaltyAwarded",
        baselineSeq: 5,
        candidateSeq: nil,
        detail: "notification present in baseline, absent in candidate"
    )

    private func diff(_ verdict: TraceDiff.Verdict, _ divergences: [Divergence] = []) -> TraceDiff {
        TraceDiff(verdict: verdict, baselineName: "ObjCCart", candidateName: "SwiftCart", divergences: divergences)
    }

    // MARK: - Self-containment (the load-bearing property: works over file://)

    func testDivergedReportContainsBannerAndValues() {
        let html = diff(.diverged, [valueMismatch, missing]).htmlReport()
        assertSelfContained(html)
        XCTAssertTrue(html.contains("❌ DIVERGED"))
        XCTAssertTrue(html.contains("cart.total"))
        XCTAssertTrue(html.contains("LoyaltyAwarded"))
        // The side-by-side panel surfaces both raw values and the numeric delta.
        XCTAssertTrue(html.contains(">1200<"))
        XCTAssertTrue(html.contains(">1500<"))
        XCTAssertTrue(html.contains("Δ +300"))
        XCTAssertTrue(html.contains("ObjCCart"))
        XCTAssertTrue(html.contains("SwiftCart"))
    }

    func testEquivalentReportRendersCleanPanel() {
        let html = diff(.equivalent).htmlReport()
        assertSelfContained(html)
        XCTAssertTrue(html.contains("✅ EQUIVALENT"))
        XCTAssertTrue(html.contains("Behavior matched"))
        XCTAssertFalse(html.contains("class=\"card"), "no divergence cards when equivalent")
    }

    /// All three tiers render without crashing (cannot-verify via the VerificationResult path).
    func testAllThreeTiersRender() {
        XCTAssertFalse(diff(.equivalent).htmlReport().isEmpty)
        XCTAssertFalse(diff(.diverged, [missing]).htmlReport().isEmpty)

        let miss = Coverage(
            declared: ["clock", "rng"],
            exercised: ["clock"],
            gaps: [Coverage.Gap(boundary: "rng", ordinal: 0, reason: .unrecorded)]
        )
        let cannotVerify = VerificationResult(diff: diff(.equivalent), coverage: miss)
        XCTAssertEqual(cannotVerify.verdict, .cannotVerify)
        let html = cannotVerify.htmlReport()
        assertSelfContained(html)
        XCTAssertTrue(html.contains("⚠️ CANNOT-VERIFY"))
        XCTAssertTrue(html.contains("abstain"))
    }

    func testVerificationReportIncludesCoverage() {
        let complete = Coverage(declared: ["clock", "rng"], exercised: ["clock", "rng"], gaps: [])
        let html = VerificationResult(diff: diff(.equivalent), coverage: complete).htmlReport()
        assertSelfContained(html)
        XCTAssertTrue(html.contains("Coverage"))
        XCTAssertTrue(html.contains("2/2"))
    }

    /// No page produced anywhere may reference a remote asset — that's what makes it openable offline.
    private func assertSelfContained(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
        for needle in ["http://", "https://", "src=", "//cdn", "url("] {
            XCTAssertFalse(
                html.contains(needle),
                "HTML report must be self-contained; found \(needle)",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(html.contains("<!doctype html>"), "expected a full document", file: file, line: line)
        XCTAssertTrue(html.contains("<style>"), "CSS must be inlined", file: file, line: line)
    }

    /// HTML metacharacters in labels/values must not break out of the markup.
    func testEscapingOfHostileContent() {
        let hostile = Divergence(
            kind: .valueMismatch,
            label: "<script>& \"x\"",
            baselineSeq: 1,
            candidateSeq: 1,
            detail: "a<b: baseline=1 candidate=2",
            field: "a<b",
            baselineValue: 1,
            candidateValue: 2
        )
        let html = diff(.diverged, [hostile]).htmlReport()
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    // MARK: - Writing to disk (HTMLReporting)

    /// ``HTMLReporting/writeHTMLReport(to:)`` renders and persists the exact bytes ``HTMLReporting/htmlReport()``
    /// produces.
    func testWriteHTMLReportToExactURL() throws {
        let divergedDiff = diff(.diverged, [valueMismatch])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-exact-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: url) }

        try divergedDiff.writeHTMLReport(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), divergedDiff.htmlReport())
    }

    /// ``HTMLReporting/writeHTMLReport(named:in:)`` creates the directory, writes `<name>.html`, and returns its URL.
    func testWriteHTMLReportNamedCreatesDirectoryAndReturnsURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("haruspec-named-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "precondition: dir absent")

        let url = try XCTUnwrap(diff(.equivalent).writeHTMLReport(named: "cart", in: dir))
        XCTAssertEqual(url.lastPathComponent, "cart.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try assertSelfContained(String(contentsOf: url, encoding: .utf8))
    }

    /// The default destination is a `HaruspecReports` folder under the system temp dir.
    func testWriteHTMLReportNamedDefaultsToTempHaruspecReports() throws {
        let name = "default-loc-\(UUID().uuidString)"
        let url = try XCTUnwrap(diff(.equivalent).writeHTMLReport(named: name))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "HaruspecReports")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// An unwritable destination returns `nil` rather than throwing — the convenience swallows failure so a
    /// missing report never crashes a test run.
    func testWriteHTMLReportNamedReturnsNilOnFailure() {
        // A path whose parent is an existing *file* can't be turned into a directory.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-dir-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNil(diff(.equivalent).writeHTMLReport(named: "x", in: file))
    }
}
