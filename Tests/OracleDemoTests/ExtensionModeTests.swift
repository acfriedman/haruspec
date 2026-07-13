import XCTest
@testable import OracleCore
@testable import OracleDemo

/// Extension mode end-to-end on a real captured module: an *intended* feature change (loyalty points)
/// that also carries a **collateral** regression. The oracle must absorb the declared additions while
/// still catching the undeclared one. Migration parity is the special case where nothing is declared.
final class ExtensionModeTests: XCTestCase {

    private func featureDiff() -> TraceDiff {
        BehavioralDiff.compare(baseline: CheckoutScenario.baseline(),
                               candidate: CheckoutScenario.feature(),
                               tolerances: CheckoutScenario.tolerances)
    }

    /// Without an intent spec (parity mode), the feature's intended additions look just like the
    /// collateral regression: every divergence is `.collateral` and gates.
    func testParityModeFlagsEveryChange() {
        let diff = featureDiff()
        XCTAssertFalse(diff.isEquivalent)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .unexpectedEvent && $0.label == "LoyaltyPointsEarned" },
                      "the new product notification should surface\n\(diff.report())")
        XCTAssertTrue(diff.divergences.contains { $0.kind == .valueMismatch && $0.label == "CheckoutDidComplete" },
                      "the new userInfo field should surface\n\(diff.report())")
        XCTAssertTrue(diff.divergences.contains { $0.kind == .missingEvent && $0.label == "CartDidChange" },
                      "the dropped notification should surface\n\(diff.report())")
        XCTAssertTrue(diff.divergences.allSatisfy { $0.classification == .collateral },
                      "with no intent declared, nothing is intended")
    }

    /// With the feature's intent declared, the two loyalty additions become `.intended` (non-gating)
    /// while the unintended dropped `CartDidChange` stays `.collateral` and gates — a caught regression.
    func testExtensionModeAbsorbsIntendedAndCatchesCollateral() {
        let diff = featureDiff().classified(against: CheckoutScenario.intent)

        XCTAssertEqual(diff.intendedCount, 2, "the new loyalty event + the new payload field are declared\n\(diff.report())")
        XCTAssertEqual(diff.collateralCount, 1, "only the dropped CartDidChange is undeclared\n\(diff.report())")
        XCTAssertFalse(diff.isEquivalent, "a collateral regression still fails the gate")

        let collateral = diff.divergences.filter(\.isGating)
        XCTAssertEqual(collateral.count, 1)
        XCTAssertEqual(collateral.first?.kind, .missingEvent)
        XCTAssertEqual(collateral.first?.label, "CartDidChange")
    }

    /// The happy path / acceptance loop: if the dropped notification were *also* intended and declared,
    /// the change verifies as a clean, safe extension — nothing collateral remains.
    func testFullyDeclaredFeatureVerifiesClean() {
        var intent = CheckoutScenario.intent
        intent.expectedRemovedEvents = ["CartDidChange"]
        let diff = featureDiff().classified(against: intent)
        XCTAssertTrue(diff.isEquivalent, "every change is now declared — no collateral remains\n\(diff.report())")
        XCTAssertEqual(diff.collateralCount, 0)
    }
}
