import Foundation
import HaruspecCore
@testable import HaruspecLocal
import XCTest

// The intent doc is two things at once: a file the developer edits and may attach to a PR, and a
// PR body the CI gate parses. Every edit must keep both readings intact.

final class IntentDocumentTests: XCTestCase {
    private let points = #"Changes("LoyaltyPointsEarned", field: "points").increases()"#
    private let query = #"Changes("Search.query")"#

    func testSavedDeclarationsParseAsThePRGateReadsThem() throws {
        var document = IntentDocument.empty(branch: "feature/rewards")
        try document.save([points], for: "cart", replacing: false)

        let intents = try document.intents()
        XCTAssertEqual(Array(intents.keys), ["cart"])
        XCTAssertEqual(intents["cart"]?.declarationTexts, [points])
        XCTAssertEqual(document.declarations(for: "cart"), [points])
    }

    func testSavingAgainAddsNewLinesAndSkipsRepeats() throws {
        var document = IntentDocument.empty(branch: "b")
        try document.save([points], for: "cart", replacing: false)
        try document.save([points, query], for: "cart", replacing: false)

        XCTAssertEqual(document.declarations(for: "cart"), [points, query])
        XCTAssertEqual(try document.intents().count, 1, "one block per spec, or the gate refuses the body")
    }

    func testReplacingDropsTheEarlierLines() throws {
        var document = IntentDocument.empty(branch: "b")
        try document.save([points, query], for: "cart", replacing: false)
        try document.save([query], for: "cart", replacing: true)

        XCTAssertEqual(document.declarations(for: "cart"), [query])
    }

    func testAnUnparseableLineIsRefusedAndTheDocumentIsUnchanged() {
        var document = IntentDocument.empty(branch: "b")
        let before = document
        XCTAssertThrowsError(try document.save(["Changes("], for: "cart", replacing: false))
        XCTAssertEqual(document, before)
    }

    func testProseAroundTheSectionsSurvivesEveryEdit() throws {
        var document = IntentDocument(text: "# Mine\n\nWhy this branch exists.\n")
        try document.save([points], for: "cart", replacing: false)
        try document.save([query], for: "search", replacing: false)
        document.setEvidence("**Checked**", for: "cart")
        try document.remove("search")

        XCTAssertTrue(document.text.hasPrefix("# Mine\n\nWhy this branch exists.\n"))
        XCTAssertEqual(document.sectionSpecs, ["cart"])
        XCTAssertEqual(document.declarations(for: "cart"), [points])
    }

    func testEvidenceWithAPlainFenceDoesNotBecomeADeclaration() throws {
        var document = IntentDocument.empty(branch: "b")
        try document.save([points], for: "cart", replacing: false)
        document.setEvidence("```text\nverdict: EQUIVALENT\n```", for: "cart")

        XCTAssertEqual(try document.intents()["cart"]?.declarationTexts, [points])
        XCTAssertTrue(document.text.contains("verdict: EQUIVALENT"))
    }

    func testSavingNewDeclarationsResetsTheEvidence() throws {
        var document = IntentDocument.empty(branch: "b")
        try document.save([points], for: "cart", replacing: false)
        document.setEvidence("old verdict", for: "cart")
        try document.save([query], for: "cart", replacing: false)

        XCTAssertFalse(document.text.contains("old verdict"), "evidence must describe the current declarations")
    }

    func testAHandWrittenBlockForTheSameSpecIsRefused() {
        var document = IntentDocument(text: "```haruspec-intent cart\n\(query)\n```\n")
        XCTAssertThrowsError(try document.save([points], for: "cart", replacing: false)) { error in
            guard case LocalCheckError.intentDocument = error else {
                return XCTFail("expected an intent-document error, got \(error)")
            }
        }
    }

    func testRemovingASpecWithNoSectionIsRefused() {
        var document = IntentDocument.empty(branch: "b")
        XCTAssertThrowsError(try document.remove("cart"))
    }

    func testUpdateCreatesTheFileAndItsDirectories() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-\(UUID().uuidString)/feature/rewards.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        try IntentDocument.update(at: url, branch: "feature/rewards") { document in
            try document.save([points], for: "cart", replacing: false)
        }
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("`feature/rewards`"))
        XCTAssertEqual(IntentDocument(text: written).declarations(for: "cart"), [points])
    }
}
