import Foundation
@testable import HaruspecLocal
import HaruspecSpec
import XCTest

// The report a developer or agent reads after `haruspec check`, built from the Spec tests' committed
// DIVERGED verdict so it renders a real offer.

final class LocalCheckOutcomeTests: XCTestCase {
    private let artifact = URL(fileURLWithPath: "/r.json")

    func testARedSpecEndsWithTheCommandThatDeclaresIt() throws {
        let verdict = try divergedVerdict()
        let report = outcome([
            .init(spec: "cart", result: .verdict(verdict, artifact: artifact, otherFailures: nil))
        ]).report()

        XCTAssertFalse(verdict.offeredDeclarations.isEmpty, "the fixture must offer a declaration")
        XCTAssertTrue(report.contains("haruspec intent save cart \\"), report)
        XCTAssertTrue(report.contains("'" + verdict.offeredDeclarations[0] + "'"), report)
        XCTAssertTrue(report.contains("+ uncommitted changes"))
        XCTAssertTrue(report.contains("declares serach, which this check did not replay"))
    }

    func testTheExitCodeIsTheWorstAcrossSpecs() throws {
        let verdict = try divergedVerdict()
        XCTAssertEqual(outcome([.init(spec: "new", result: .noBaseline)]).exitCode, 0, "no baseline is no failure")
        XCTAssertEqual(outcome([.init(spec: "a", result: .failed(reason: "x", log: nil))]).exitCode, 1)
        XCTAssertEqual(outcome([
            .init(spec: "a", result: .failed(reason: "x", log: nil)),
            .init(spec: "b", result: .verdict(verdict, artifact: artifact, otherFailures: nil))
        ]).exitCode, 3)
    }

    func testSpecsWithoutAVerdictAndOtherFailuresAreNamed() throws {
        let log = URL(fileURLWithPath: "/repo/logs/replay-cart.log")
        let report = try outcome([
            .init(spec: "cart", result: .verdict(divergedVerdict(), artifact: artifact, otherFailures: log)),
            .init(spec: "rewards", result: .noBaseline),
            .init(spec: "search", result: .failed(reason: "recording the merge base failed", log: log))
        ]).report()

        XCTAssertTrue(report.contains("cart: other tests failed in the same run"), report)
        XCTAssertTrue(report.contains("rewards: no baseline"), report)
        XCTAssertTrue(report.contains("search: NO VERDICT — recording the merge base failed"), report)
        XCTAssertTrue(report.contains("search: its suite does not name itself"), report)
    }

    func testUntouchedSpecsAreListedAndNeverFail() {
        let untouched = outcome([
            .init(spec: "cart", result: .untouched(recordedAt: String(repeating: "a", count: 40))),
            .init(spec: "search", result: .untouched(recordedAt: String(repeating: "c", count: 40)))
        ])
        XCTAssertEqual(untouched.exitCode, 0)
        let report = untouched.report()
        XCTAssertTrue(report.contains("Nothing to replay"), report)
        XCTAssertTrue(report.contains("- cart\n"), "coverage from this base needs no note")
        XCTAssertTrue(report.contains("- search (coverage recorded at ccccccc)"), report)
        XCTAssertTrue(report.contains("no spec exercises it"), report)
        XCTAssertTrue(report.contains("- LegacyApp/App/AppDelegate.m"), report)
    }

    func testEvidenceLandsUnderDeclaredSpecsOnly() throws {
        var document = IntentDocument.empty(branch: "feature/points")
        try document.save([#"Changes("LoyaltyPointsEarned", field: "points")"#], for: "cart", replacing: false)
        let verdict = try divergedVerdict()
        outcome([
            .init(spec: "cart", result: .verdict(verdict, artifact: artifact, otherFailures: nil)),
            .init(spec: "search", result: .verdict(verdict, artifact: artifact, otherFailures: nil))
        ]).refreshEvidence(in: &document)

        let stamp = "**Checked** · base `main` @ `aaaaaaa` → `bbbbbbb` + uncommitted changes"
        XCTAssertTrue(document.text.contains(stamp))
        XCTAssertEqual(document.sectionSpecs, ["cart"], "a spec without a section gains none")
        XCTAssertEqual(try document.intents().keys.sorted(), ["cart"], "evidence never adds a declaration block")
    }

    private func divergedVerdict() throws -> SpecVerdict {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SpecTests/Fixtures/diverged.result.json")
        return try SpecVerdict(contentsOf: fixture)
    }

    private func outcome(_ entries: [LocalCheckOutcome.Entry]) -> LocalCheckOutcome {
        LocalCheckOutcome(
            base: "main",
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40),
            branch: "feature/points",
            uncommitted: true,
            entries: entries,
            undeclaredIntent: ["serach"],
            wholeTargetSpecs: ["search"],
            uncoveredChanges: ["LegacyApp/App/AppDelegate.m"],
            changedFiles: [],
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            intentDocument: nil,
            runDirectory: URL(fileURLWithPath: "/repo/.haruspec/cache/runs/1")
        )
    }
}
