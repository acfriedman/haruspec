@testable import HaruspecCore
import XCTest

/// `Intent` is the symmetric complement to `Tolerance`: it reclassifies *declared* divergences
/// as `.intended` (non-gating) so an extension-mode verdict gates only on the residual `.collateral`
/// ones. These tests pin the classification logic against hand-built divergences — no capture needed.
final class IntentTests: XCTestCase {
    private func diff(_ divergences: [Divergence]) -> TraceDiff {
        TraceDiff(
            verdict: divergences.contains(where: \.isGating) ? .diverged : .equivalent,
            baselineName: "b",
            candidateName: "c",
            divergences: divergences
        )
    }

    private func d(_ kind: Divergence.Kind, _ label: String, _ detail: String = "") -> Divergence {
        Divergence(kind: kind, label: label, baselineSeq: 0, candidateSeq: 0, detail: detail)
    }

    func testEmptyIntentIsParityMode() {
        let classified = diff([d(.unexpectedEvent, "LoyaltyPointsEarned")]).classified(against: .none)
        XCTAssertFalse(classified.isEquivalent)
        XCTAssertEqual(classified.collateralCount, 1)
        XCTAssertEqual(classified.intendedCount, 0)
    }

    func testDeclaredNewEventBecomesIntendedAndDoesNotGate() {
        let classified = diff([d(.unexpectedEvent, "LoyaltyPointsEarned")])
            .classified(against: Intent(expectedNewEvents: ["LoyaltyPointsEarned"]))
        XCTAssertTrue(classified.isEquivalent, "only declared changes remain — nothing gates")
        XCTAssertEqual(classified.intendedCount, 1)
        XCTAssertEqual(classified.collateralCount, 0)
    }

    func testUndeclaredChangeStaysCollateralAndGates() {
        let classified = diff([
            d(.unexpectedEvent, "LoyaltyPointsEarned"),
            d(.missingEvent, "CartDidChange")
        ]).classified(against: Intent(expectedNewEvents: ["LoyaltyPointsEarned"]))

        XCTAssertFalse(classified.isEquivalent, "the undeclared dropped notification still gates")
        XCTAssertEqual(classified.intendedCount, 1)
        XCTAssertEqual(classified.collateralCount, 1)
        XCTAssertTrue(classified.divergences.first(where: { $0.label == "CartDidChange" })?.isGating == true)
    }

    /// Soundness: declaring one field of an event does NOT excuse a change to another field of it.
    /// You cannot hide a regression behind a broad-sounding declaration.
    func testIntentIsFieldSpecific() {
        let classified = diff([
            d(.valueMismatch, "CheckoutDidComplete", "pointsEarned: baseline=null candidate=25"),
            d(.valueMismatch, "CheckoutDidComplete", "totalCents: baseline=2525 candidate=2526")
        ]).classified(against: Intent(expectedValueChanges: ["CheckoutDidComplete": ["pointsEarned"]]))

        XCTAssertEqual(classified.intendedCount, 1, "only pointsEarned was declared")
        XCTAssertEqual(classified.collateralCount, 1, "the totalCents change is collateral")
        XCTAssertFalse(classified.isEquivalent)
    }

    func testEmptyFieldListAbsorbsAnyValueChangeOnThatLabel() {
        let classified = diff([d(.valueMismatch, "CheckoutDidComplete", "totalCents: baseline=2525 candidate=2526")])
            .classified(against: Intent(expectedValueChanges: ["CheckoutDidComplete": []]))
        XCTAssertTrue(classified.isEquivalent)
    }

    func testReorderAndTimingAreNotYetDeclarable() {
        let classified = diff([
            d(.reordered, "CartDidChange"),
            d(.timingRegression, "CartService.checkout")
        ]).classified(against: Intent(
            expectedNewEvents: ["CartDidChange"],
            expectedValueChanges: ["CartService.checkout": []]
        ))
        XCTAssertEqual(classified.collateralCount, 2, "reorder/timing intent is not expressible yet")
    }

    func testIntentSpecDecodesPartialJSON() throws {
        let json = Data(#"{"expectedNewEvents":["LoyaltyPointsEarned"]}"#.utf8)
        let intent = try JSONDecoder().decode(Intent.self, from: json)
        XCTAssertEqual(intent.expectedNewEvents, ["LoyaltyPointsEarned"])
        XCTAssertTrue(intent.expectedRemovedEvents.isEmpty)
        XCTAssertTrue(intent.expectedValueChanges.isEmpty)
    }

    // MARK: - Declared but not observed

    func testADeclarationMatchingNothingIsNamedUnobserved() {
        let classified = diff([d(.unexpectedEvent, "LoyaltyPointsEarned")])
            .classified(against: Intent(expectedNewEvents: ["LoyaltyPointsEarned", "NeverEmitted"]))
        XCTAssertTrue(classified.isEquivalent, "the matched declaration still absorbs")
        XCTAssertEqual(classified.unobservedIntent, [#"Emits("NeverEmitted")"#])
    }

    func testParityModeHasNoUnobservedIntent() {
        XCTAssertEqual(diff([d(.unexpectedEvent, "X")]).classified(against: .none).unobservedIntent, [])
    }

    func testUnobservedIsPerField() {
        // Declaring two fields and observing one leaves the OTHER declaration dead — the same
        // specificity that keeps a broad declaration from hiding a regression, read in reverse.
        let classified = diff([d(.valueMismatch, "CheckoutDidComplete", "pointsEarned: baseline=null candidate=25")])
            .classified(against: Intent(expectedValueChanges: ["CheckoutDidComplete": ["pointsEarned", "totalCents"]]))
        XCTAssertEqual(classified.unobservedIntent, [#"Changes("CheckoutDidComplete", field: "totalCents")"#])
    }

    func testUnobservedListsEveryDeclarationKindInItsDSLSpelling() {
        let intent = Intent {
            Moves("Cart.add", from: .queue("com.emporium.cart"), to: .actor("SwiftCartActor"))
            Relaxes(orderingOf: .queue("delivery"))
        }
        let classified = diff([d(.unexpectedEvent, "Unrelated")]).classified(against: intent)
        XCTAssertEqual(classified.unobservedIntent, [
            #"Relaxes(orderingOf: .queue("delivery"))"#,
            #"Moves("Cart.add", from: .queue("com.emporium.cart"), to: .actor("SwiftCartActor"))"#
        ])
    }

    func testAnUnobservedDeclarationFailsTheAgentBriefGate() {
        let classified = diff([]).classified(against: Intent(expectedNewEvents: ["NeverEmitted"]))
        XCTAssertTrue(classified.isEquivalent, "behavior itself matched")
        XCTAssertTrue(classified.agentBrief().contains("Gate: FAIL"), "exit 6 is a non-pass")
        XCTAssertTrue(classified.report().contains("declared but not observed"), classified.report())
    }

    // MARK: Merging (the record-on-merge union)

    func testMergingUnionsEveryKindAndDeduplicates() {
        let first = Intent(
            expectedNewEvents: ["LoyaltyPointsEarned"],
            expectedValueChanges: ["Receipt": ["total"]],
            expectedDomainMigrations: [.init(from: .main, to: .ambient)]
        )
        let second = Intent(
            expectedNewEvents: ["LoyaltyPointsEarned", "CartRewardsDidUpdate"],
            expectedValueChanges: ["Receipt": ["points"], "Search.query": []],
            expectedDomainMigrations: [.init(from: .main, to: .ambient)],
            acceptedBlindSpots: ["Combine"]
        )
        let merged = first.merging(second)
        XCTAssertEqual(merged.expectedNewEvents, ["LoyaltyPointsEarned", "CartRewardsDidUpdate"])
        XCTAssertEqual(merged.expectedValueChanges["Receipt"], ["total", "points"])
        XCTAssertEqual(merged.expectedValueChanges["Search.query"], [])
        XCTAssertEqual(merged.expectedDomainMigrations.count, 1)
        XCTAssertEqual(merged.acceptedBlindSpots, ["Combine"])
    }

    func testMergingAWholesaleValueChangeSubsumesPerFieldForms() {
        let wholesale = Intent(expectedValueChanges: ["Receipt": []])
        let perField = Intent(expectedValueChanges: ["Receipt": ["total"]])
        XCTAssertEqual(wholesale.merging(perField).expectedValueChanges["Receipt"], [])
        XCTAssertEqual(perField.merging(wholesale).expectedValueChanges["Receipt"], [])
    }
}
