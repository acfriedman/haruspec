@testable import HaruspecCore
import XCTest

/// The modifier half of the grammar: every chained `.modifier(…)` spelling parses to the data its
/// Swift twin builds, renders back to the same line, and a modifier that contradicts or does not
/// belong is refused naming the fix — precise intent is only precise if the text form is exact.
final class IntentModifierGrammarTests: XCTestCase {
    func testEveryModifierSpellingParses() throws {
        let intent = try IntentGrammar.intent(parsing: """
        Changes("CheckoutDidComplete", field: "totalCents").to(11363)
        Changes("Receipt", field: "discountCents").increases()
        Changes("Receipt", field: "shippingCents").decreases()
        Changes("LoyaltyPointsEarned", field: "points").within(1 ... 64)
        Changes("Receipt", field: "discountCents").when("applyPromo.code", is: "SAVE10")
        Changes("Cart.total", field: "value").to(1.5).when("add.quantity", is: 2)
        Changes("Flags", field: "promo").to(true)
        Changes("Receipt", field: "coupon").to(null)
        Emits("CartRewardsDidUpdate").when("add.quantity", is: 1)
        Omits("Inventory.reserve").when("add.quantity", is: 0)
        """)

        XCTAssertEqual(intent.expectedValueChanges, [
            .init("CheckoutDidComplete", field: "totalCents", relation: .to(11363)),
            .init("Receipt", field: "discountCents", relation: .increases),
            .init("Receipt", field: "shippingCents", relation: .decreases),
            .init("LoyaltyPointsEarned", field: "points", relation: .within(1 ... 64)),
            .init("Receipt", field: "discountCents", when: [.init(seam: "applyPromo.code", is: "SAVE10")]),
            .init("Cart.total", field: "value", relation: .to(1.5), when: [.init(seam: "add.quantity", is: 2)]),
            .init("Flags", field: "promo", relation: .to(true)),
            .init("Receipt", field: "coupon", relation: .to(.null))
        ])
        XCTAssertEqual(intent.expectedNewEvents, [
            .init("CartRewardsDidUpdate", when: [.init(seam: "add.quantity", is: 1)])
        ])
        XCTAssertEqual(intent.expectedRemovedEvents, [
            .init("Inventory.reserve", when: [.init(seam: "add.quantity", is: 0)])
        ])
    }

    func testModifiedDeclarationTextsRoundTripThroughTheGrammar() throws {
        // Value changes render label-sorted, so declare them that way and the round-trip is exact.
        let declared = Intent {
            Changes("Cart.total").to(-2.5)
            Changes("CheckoutDidComplete", field: "totalCents").to(11363)
            Changes("LoyaltyPointsEarned", field: "points").within(1 ... 64)
            Changes("Receipt", field: "discountCents").increases().when("applyPromo.code", is: "SAVE10")
            Emits("CartRewardsDidUpdate").when("add.quantity", is: 1)
        }
        let reparsed = try IntentGrammar.intent(parsing: declared.declarationTexts.joined(separator: "\n"))
        XCTAssertEqual(reparsed, declared)
    }

    func testASecondValueRelationIsRefusedNamingBoth() {
        XCTAssertThrowsError(
            try IntentGrammar.intent(parsing: #"Changes("Receipt", field: "total").to(5).increases()"#)
        ) { error in
            let description = "\(error)"
            XCTAssertTrue(description.contains(".increases() contradicts .to(5)"), description)
            XCTAssertTrue(description.contains("one value relation per declaration"), description)
        }
    }

    func testAModifierOnTheWrongDeclarationIsRefusedNamingTheAllowedOnes() {
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: #"Emits("X").increases()"#)) { error in
            let description = "\(error)"
            XCTAssertTrue(description.contains("\".increases\" does not narrow this declaration"), description)
            XCTAssertTrue(description.contains("modifiers here are .when"), description)
        }
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: #"Awaits("X").when("s", is: 1)"#)) { error in
            XCTAssertTrue("\(error)".contains("takes no modifiers"), "\(error)")
        }
    }

    func testAnEmptyRangeIsRefused() {
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: #"Changes("X").within(64 ... 1)"#)) { error in
            XCTAssertTrue("\(error)".contains("an empty range"), "\(error)")
        }
    }

    // MARK: - Suggestions

    /// The offer is the narrowest line the divergence proves: a scalar new value pins `.to(…)`; a
    /// structured value has no literal, so the bare field is as narrow as the grammar can say.
    func testASuggestionPinsTheScalarValueItObserved() throws {
        let pinned = Divergence(
            kind: .valueMismatch,
            label: "CheckoutDidComplete",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "",
            field: "totalCents",
            baselineValue: 12000,
            candidateValue: 11363
        )
        let suggested = try XCTUnwrap(pinned.suggestedDeclaration)
        XCTAssertEqual(suggested, #"Changes("CheckoutDidComplete", field: "totalCents").to(11363)"#)
        XCTAssertTrue(try IntentGrammar.intent(parsing: suggested).declares(pinned), "the offer absorbs its own cause")

        let structured = Divergence(
            kind: .valueMismatch,
            label: "Cart.items",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "",
            field: "items",
            baselineValue: [1],
            candidateValue: [1, 2]
        )
        XCTAssertEqual(structured.suggestedDeclaration, #"Changes("Cart.items", field: "items")"#)
    }
}
