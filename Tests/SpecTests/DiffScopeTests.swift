import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace
import XCTest

// The diff-scoped continuous report, asserted over real replay verdicts: a verdict whose subject
// the diff touches renders in full, an untouched red leads the report, an untouched green
// collapses to a rollup line — and the two honesty exits (unreadable artifact, unscopable
// verdict) always render in full rather than hiding behind a diff nobody measured them against.

@Haruspec
protocol Abacus: AnyObject {
    func ring(amount: Int)
    func total() -> Int
}

private final class LegacyAbacus: Abacus {
    private var cents = 0
    func ring(amount: Int) {
        cents += amount
    }

    func total() -> Int {
        cents
    }
}

/// The port that diverges: every ring overcharges by one.
private final class OverchargingAbacus: Abacus {
    private var cents = 0
    func ring(amount: Int) {
        cents += amount + 1
    }

    func total() -> Int {
        cents
    }
}

final class DiffScopeTests: XCTestCase {
    /// This file's own repo-relative path — the one the fixtures' origins resolve to.
    private let fixtureFile = "Tests/SpecTests/DiffScopeTests.swift"

    /// The package checkout, resolved from `#filePath` (`<root>/Tests/SpecTests/…`).
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func abacus(system: @escaping (SeamContext) -> Abacus) -> BaselinedSpec<Abacus> {
        Spec<Abacus>("abacus.diffscope")
            .operations {
                Op("ring", varying: .oneOf(1, 2, 3)) { $0.ring(amount: $1) }
                Op("total") { _ = $0.total() }.last()
            }
            .baselined(on: system)
    }

    private func equivalentVerdict() async -> SpecVerdict {
        let plan = await abacus { _ in LegacyAbacus() }.record()
        return await abacus { _ in LegacyAbacus() }.verify(replaying: plan)
    }

    private func divergedVerdict() async -> SpecVerdict {
        let plan = await abacus { _ in LegacyAbacus() }.record()
        return await abacus { _ in OverchargingAbacus() }.verify(replaying: plan)
    }

    private func entry(_ verdict: SpecVerdict) -> ContinuousReport.Entry {
        ContinuousReport.Entry(
            verdict: verdict,
            source: "result.json",
            subjectFiles: verdict.subjectFiles(root: root)
        )
    }

    func testSubjectFilesResolveAgainstTheCheckout() async {
        let verdict = await equivalentVerdict()
        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertEqual(verdict.subjectFiles(root: root), [fixtureFile])
    }

    func testATouchedSpecRendersInFull() async {
        let report = await ContinuousReport(
            entries: [entry(equivalentVerdict())],
            changed: [fixtureFile]
        )
        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("### ✅ EQUIVALENT — `abacus.diffscope`"))
        XCTAssertFalse(markdown.contains("Untouched by this diff"))
    }

    func testAnUntouchedGreenCollapsesToARollupLine() async {
        let report = await ContinuousReport(
            entries: [entry(equivalentVerdict())],
            changed: ["LegacyApp/Somewhere/Else.swift"]
        )
        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("### Untouched by this diff"))
        XCTAssertTrue(markdown.contains("- ✅ `abacus.diffscope` — EQUIVALENT, subject untouched by this diff"))
        XCTAssertFalse(markdown.contains("### ✅ EQUIVALENT"), "an untouched green renders no full block")
    }

    func testAnUntouchedRedLeadsTheReport() async {
        let report = await ContinuousReport(
            entries: [entry(equivalentVerdict()), entry(divergedVerdict())],
            changed: ["LegacyApp/Somewhere/Else.swift"]
        )
        let markdown = report.markdown()
        XCTAssertTrue(
            markdown.hasPrefix("### ⚠️ Not equivalent outside this diff"),
            "the surprise leads, ahead of every in-scope block"
        )
        XCTAssertTrue(markdown.contains("### ❌ DIVERGED — `abacus.diffscope`"), "the red still renders in full")
        XCTAssertTrue(markdown.contains("- ✅ `abacus.diffscope`"), "the untouched green still rolls up")
    }

    func testAnUnscopableVerdictRendersInFullWithTheCaveat() async {
        let verdict = await equivalentVerdict()
        let report = ContinuousReport(
            entries: [ContinuousReport.Entry(verdict: verdict, source: "result.json", subjectFiles: nil)],
            changed: ["LegacyApp/Somewhere/Else.swift"]
        )
        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("### ✅ EQUIVALENT — `abacus.diffscope`"))
        XCTAssertTrue(markdown.contains("could not be resolved against the checkout"))
        XCTAssertFalse(markdown.contains("Untouched by this diff"))
    }

    func testAnUnreadableArtifactRendersAsInfrastructureFailure() async {
        let report = await ContinuousReport(
            entries: [
                ContinuousReport.Entry(verdict: nil, source: "results/abacus/result.json", subjectFiles: nil),
                entry(equivalentVerdict())
            ],
            changed: [fixtureFile]
        )
        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("### ⚠️ no verdict produced — `results/abacus/result.json`"))
        XCTAssertTrue(markdown.contains("### ✅ EQUIVALENT — `abacus.diffscope`"))
        XCTAssertEqual(report.verdicts, [nil, .equivalent])
    }

    func testAnUnscopedReportConcatenatesFullBlocks() async {
        let report = await ContinuousReport(
            entries: [entry(equivalentVerdict()), entry(divergedVerdict())],
            changed: nil
        )
        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("### ✅ EQUIVALENT — `abacus.diffscope`"))
        XCTAssertTrue(markdown.contains("### ❌ DIVERGED — `abacus.diffscope`"))
        XCTAssertFalse(markdown.contains("outside this diff"))
        XCTAssertFalse(markdown.contains("Untouched by this diff"))
    }
}
