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

    private func d(_ kind: Divergence.Kind, _ label: String) -> Divergence {
        Divergence(kind: kind, label: label, baselineSeq: 0, candidateSeq: 0, detail: "")
    }

    /// A value mismatch as the diff builds one: the field and both values carried structurally.
    private func changed(
        _ label: String,
        _ field: String,
        from baseline: CanonicalValue,
        to candidate: CanonicalValue
    ) -> Divergence {
        Divergence(
            kind: .valueMismatch,
            label: label,
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "\(field): baseline=\(baseline.canonicalString) candidate=\(candidate.canonicalString)",
            field: field,
            baselineValue: baseline,
            candidateValue: candidate
        )
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
            changed("CheckoutDidComplete", "pointsEarned", from: .null, to: 25),
            changed("CheckoutDidComplete", "totalCents", from: 2525, to: 2526)
        ]).classified(against: Intent { Changes("CheckoutDidComplete", field: "pointsEarned") })

        XCTAssertEqual(classified.intendedCount, 1, "only pointsEarned was declared")
        XCTAssertEqual(classified.collateralCount, 1, "the totalCents change is collateral")
        XCTAssertFalse(classified.isEquivalent)
    }

    func testEmptyFieldListAbsorbsAnyValueChangeOnThatLabel() {
        let classified = diff([changed("CheckoutDidComplete", "totalCents", from: 2525, to: 2526)])
            .classified(against: Intent { Changes("CheckoutDidComplete") })
        XCTAssertTrue(classified.isEquivalent)
    }

    func testReorderAndTimingAreNotYetDeclarable() {
        let classified = diff([
            d(.reordered, "CartDidChange"),
            d(.timingRegression, "CartService.checkout")
        ]).classified(against: Intent {
            Emits("CartDidChange")
            Changes("CartService.checkout")
        })
        XCTAssertEqual(classified.collateralCount, 2, "reorder/timing intent is not expressible yet")
    }

    func testIntentSpecDecodesPartialJSON() throws {
        let json = Data(#"{"expectedNewEvents":["LoyaltyPointsEarned"]}"#.utf8)
        let intent = try JSONDecoder().decode(Intent.self, from: json)
        XCTAssertEqual(intent.expectedNewEvents, ["LoyaltyPointsEarned"])
        XCTAssertTrue(intent.expectedRemovedEvents.isEmpty)
        XCTAssertTrue(intent.expectedValueChanges.isEmpty)
    }

    func testIntentSpecRoundTripsModifiersThroughJSON() throws {
        let intent = Intent {
            Emits("Inventory.reserve").when("add.quantity", is: 1)
            Changes("Receipt", field: "discountCents").increases().when("applyPromo.code", is: "SAVE10")
            Changes("LoyaltyPointsEarned", field: "points").within(1 ... 64)
            Changes("CheckoutDidComplete", field: "totalCents").to(11363)
        }
        let data = try JSONEncoder().encode(intent)
        XCTAssertEqual(try JSONDecoder().decode(Intent.self, from: data), intent)
    }

    // MARK: - Modifiers narrow the match

    /// The tripwire: a declaration that says which way the value moves rejects the other way, and
    /// the rejected divergence stays collateral — the declaration cannot be a blanket by accident.
    func testAValueRelationRejectsTheOtherDirection() {
        let intent = Intent { Changes("Receipt", field: "discountCents").increases() }
        XCTAssertTrue(intent.declares(changed("Receipt", "discountCents", from: 100, to: 150)))
        XCTAssertFalse(intent.declares(changed("Receipt", "discountCents", from: 150, to: 100)))
        XCTAssertFalse(
            intent.declares(changed("Receipt", "discountCents", from: "a", to: "b")),
            "a direction needs numbers; strings never satisfy it"
        )
    }

    func testToMatchesExactlyOneNewValue() {
        let intent = Intent { Changes("CheckoutDidComplete", field: "totalCents").to(11363) }
        XCTAssertTrue(intent.declares(changed("CheckoutDidComplete", "totalCents", from: 12000, to: 11363)))
        XCTAssertTrue(
            intent.declares(changed("CheckoutDidComplete", "totalCents", from: 12000, to: 11363.0)),
            "an int and a double are one number"
        )
        XCTAssertFalse(intent.declares(changed("CheckoutDidComplete", "totalCents", from: 12000, to: 11364)))
    }

    func testWithinBoundsTheNewValue() {
        let intent = Intent { Changes("LoyaltyPointsEarned", field: "points").within(1 ... 64) }
        XCTAssertTrue(intent.declares(changed("LoyaltyPointsEarned", "points", from: 0, to: 16)))
        XCTAssertFalse(
            intent.declares(changed("LoyaltyPointsEarned", "points", from: 16, to: 128)),
            "the promo-doubled overshoot is exactly what the range is there to catch"
        )
    }

    /// The Rewards-PR shape: the first-round declaration narrowed to what the counterexample proved
    /// catches the promo-doubled points in the same round, instead of absorbing them.
    func testANarrowedFirstDeclarationIsATripwireForTheDoubledValue() {
        let classified = diff([
            changed("LoyaltyPointsEarned", "points", from: 0, to: 16),
            changed("LoyaltyPointsEarned", "points", from: 0, to: 32)
        ]).classified(against: Intent { Changes("LoyaltyPointsEarned", field: "points").to(16) })
        XCTAssertEqual(classified.intendedCount, 1)
        XCTAssertEqual(classified.collateralCount, 1, "32 is not 16: it gates")
        XCTAssertFalse(classified.isEquivalent)
    }

    func testAnInputConditionMatchesOnlyTheProbeThatReadTheValue() {
        let intent = Intent { Changes("Receipt", field: "discountCents").when("applyPromo.code", is: "SAVE10") }
        let mismatch = changed("Receipt", "discountCents", from: 0, to: 1000)
        XCTAssertTrue(intent.declares(mismatch, inputs: ["applyPromo.code": ["SAVE10"]]))
        XCTAssertFalse(intent.declares(mismatch, inputs: ["applyPromo.code": ["FREESHIP"]]))
        XCTAssertFalse(
            intent.declares(mismatch, inputs: ["applyPromo.code": ["SAVE10", "FREESHIP"]]),
            "a mixed probe cannot yet attribute the divergence to one read — it stays collateral"
        )
        XCTAssertFalse(intent.declares(mismatch, inputs: [:]), "a seam the probe never read")
        XCTAssertFalse(intent.declares(mismatch), "no probe at all — a bare diff — satisfies no condition")
    }

    func testAnInputConditionNarrowsAnEventDeclaration() {
        let intent = Intent { Omits("Inventory.reserve").when("add.quantity", is: 0) }
        XCTAssertTrue(intent.declares(d(.missingEvent, "Inventory.reserve"), inputs: ["add.quantity": [0]]))
        XCTAssertFalse(intent.declares(d(.missingEvent, "Inventory.reserve"), inputs: ["add.quantity": [2]]))
    }

    func testClassificationThreadsTheProbeInputs() {
        let intent = Intent { Emits("PromoApplied").when("applyPromo.code", is: "SAVE10") }
        let promo = diff([d(.unexpectedEvent, "PromoApplied")])
        XCTAssertTrue(promo.classified(against: intent, inputs: ["applyPromo.code": ["SAVE10"]]).isEquivalent)
        XCTAssertFalse(promo.classified(against: intent, inputs: ["applyPromo.code": ["NONE"]]).isEquivalent)
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
        let classified = diff([changed("CheckoutDidComplete", "pointsEarned", from: .null, to: 25)])
            .classified(against: Intent { Changes("CheckoutDidComplete", field: "pointsEarned", "totalCents") })
        XCTAssertEqual(classified.unobservedIntent, [#"Changes("CheckoutDidComplete", field: "totalCents")"#])
    }

    /// A modifier that rejects every divergence is a dead declaration too: the warning names the
    /// modified spelling, which is exactly the line to fix.
    func testARejectingModifierIsUnobservedByItsFullSpelling() {
        let classified = diff([changed("Receipt", "discountCents", from: 150, to: 100)])
            .classified(against: Intent { Changes("Receipt", field: "discountCents").increases() })
        XCTAssertFalse(classified.isEquivalent, "the decrease stays collateral")
        XCTAssertEqual(classified.unobservedIntent, [#"Changes("Receipt", field: "discountCents").increases()"#])
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
            expectedValueChanges: [.init("Receipt", field: "total")],
            expectedDomainMigrations: [.init(from: .main, to: .ambient)]
        )
        let second = Intent(
            expectedNewEvents: ["LoyaltyPointsEarned", "CartRewardsDidUpdate"],
            expectedValueChanges: [.init("Receipt", field: "points"), .init("Search.query")],
            expectedDomainMigrations: [.init(from: .main, to: .ambient)],
            acceptedBlindSpots: ["Combine"]
        )
        let merged = first.merging(second)
        XCTAssertEqual(merged.expectedNewEvents, ["LoyaltyPointsEarned", "CartRewardsDidUpdate"])
        XCTAssertEqual(merged.expectedValueChanges, [
            .init("Receipt", field: "total"),
            .init("Receipt", field: "points"),
            .init("Search.query")
        ])
        XCTAssertEqual(merged.expectedDomainMigrations.count, 1)
        XCTAssertEqual(merged.acceptedBlindSpots, ["Combine"])
    }

    func testMergingAWholesaleValueChangeSubsumesPerFieldForms() {
        let wholesale = Intent { Changes("Receipt") }
        let perField = Intent { Changes("Receipt", field: "total").increases() }
        XCTAssertEqual(wholesale.merging(perField).expectedValueChanges, [.init("Receipt")])
        XCTAssertEqual(perField.merging(wholesale).expectedValueChanges, [.init("Receipt")])
    }

    /// Two PRs narrowing the same field keep both narrow forms: a union of tripwires is still a
    /// tripwire, never the bare declaration neither PR made.
    func testMergingKeepsModifiersRatherThanWidening() {
        let increases = Intent { Changes("Receipt", field: "total").increases() }
        let pinned = Intent { Changes("Receipt", field: "total").to(500) }
        let merged = increases.merging(pinned)
        XCTAssertEqual(merged.expectedValueChanges, [
            .init("Receipt", field: "total", relation: .increases),
            .init("Receipt", field: "total", relation: .to(500))
        ])
        XCTAssertFalse(merged.declares(changed("Receipt", "total", from: 600, to: 400)), "neither PR excused a drop")
    }
}
