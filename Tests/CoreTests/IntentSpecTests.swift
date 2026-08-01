@testable import HaruspecCore
import XCTest

/// `IntentSpec` is the symmetric complement to `ToleranceSpec`: it reclassifies *declared* divergences
/// as `.intended` (non-gating) so an extension-mode verdict gates only on the residual `.collateral`
/// ones. These tests pin the classification logic against hand-built divergences — no capture needed.
final class IntentSpecTests: XCTestCase {
    private func diff(_ divergences: [Divergence]) -> TraceDiff {
        TraceDiff(verdict: divergences.contains(where: \.isGating) ? .diverged : .equivalent,
                  baselineName: "b", candidateName: "c", divergences: divergences)
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
            .classified(against: IntentSpec(expectedNewEvents: ["LoyaltyPointsEarned"]))
        XCTAssertTrue(classified.isEquivalent, "only declared changes remain — nothing gates")
        XCTAssertEqual(classified.intendedCount, 1)
        XCTAssertEqual(classified.collateralCount, 0)
    }

    func testUndeclaredChangeStaysCollateralAndGates() {
        let classified = diff([
            d(.unexpectedEvent, "LoyaltyPointsEarned"),
            d(.missingEvent, "CartDidChange")
        ]).classified(against: IntentSpec(expectedNewEvents: ["LoyaltyPointsEarned"]))

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
        ]).classified(against: IntentSpec(expectedValueChanges: ["CheckoutDidComplete": ["pointsEarned"]]))

        XCTAssertEqual(classified.intendedCount, 1, "only pointsEarned was declared")
        XCTAssertEqual(classified.collateralCount, 1, "the totalCents change is collateral")
        XCTAssertFalse(classified.isEquivalent)
    }

    func testEmptyFieldListAbsorbsAnyValueChangeOnThatLabel() {
        let classified = diff([d(.valueMismatch, "CheckoutDidComplete", "totalCents: baseline=2525 candidate=2526")])
            .classified(against: IntentSpec(expectedValueChanges: ["CheckoutDidComplete": []]))
        XCTAssertTrue(classified.isEquivalent)
    }

    func testReorderAndTimingAreNotYetDeclarable() {
        let classified = diff([
            d(.reordered, "CartDidChange"),
            d(.timingRegression, "CartService.checkout")
        ]).classified(against: IntentSpec(expectedNewEvents: ["CartDidChange"],
                                          expectedValueChanges: ["CartService.checkout": []]))
        XCTAssertEqual(classified.collateralCount, 2, "reorder/timing intent is not expressible yet")
    }

    func testIntentSpecDecodesPartialJSON() throws {
        let json = Data(#"{"expectedNewEvents":["LoyaltyPointsEarned"]}"#.utf8)
        let intent = try JSONDecoder().decode(IntentSpec.self, from: json)
        XCTAssertEqual(intent.expectedNewEvents, ["LoyaltyPointsEarned"])
        XCTAssertTrue(intent.expectedRemovedEvents.isEmpty)
        XCTAssertTrue(intent.expectedValueChanges.isEmpty)
    }
}
