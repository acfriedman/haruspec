@testable import HaruspecCore
import XCTest

/// The offer a red makes when it has seen several failing cases: one case proves one value, several
/// prove a shape, and the offer is the narrowest shape every case satisfies.
final class IntentSuggestionsTests: XCTestCase {
    func testOneCasePinsItsValue() {
        let offer = Divergence.suggestedDeclarations(across: [changed("Receipt", "total", from: 100, to: 120)])
        XCTAssertEqual(offer, [#"Changes("Receipt", field: "total").to(120)"#])
    }

    func testTheSameValueInEveryCaseStillPins() {
        let offer = Divergence.suggestedDeclarations(across: [
            changed("Receipt", "total", from: 100, to: 120),
            changed("Receipt", "total", from: 50, to: 120)
        ])
        XCTAssertEqual(offer, [#"Changes("Receipt", field: "total").to(120)"#])
    }

    func testOneDirectionAcrossCasesOffersIt() {
        XCTAssertEqual(
            Divergence.suggestedDeclarations(across: [
                changed("Points", "points", from: 16, to: 32),
                changed("Points", "points", from: 8, to: 16)
            ]),
            [#"Changes("Points", field: "points").increases()"#]
        )
        XCTAssertEqual(
            Divergence.suggestedDeclarations(across: [
                changed("Points", "points", from: 16, to: 8),
                changed("Points", "points", from: 8, to: 4)
            ]),
            [#"Changes("Points", field: "points").decreases()"#]
        )
    }

    func testMixedDirectionsOfferTheRangeOfNewValues() {
        let offer = Divergence.suggestedDeclarations(across: [
            changed("Receipt", "total", from: 100, to: 99),
            changed("Receipt", "total", from: 100, to: 101),
            changed("Receipt", "total", from: 100, to: 150)
        ])
        XCTAssertEqual(offer, [#"Changes("Receipt", field: "total").within(99 ... 150)"#])
    }

    func testNonNumericDifferencesFallBackToTheBareField() {
        let offer = Divergence.suggestedDeclarations(across: [
            changed("Search", "query", from: "MUG", to: "mug"),
            changed("Search", "query", from: "CUP", to: "cup")
        ])
        XCTAssertEqual(offer, [#"Changes("Search", field: "query")"#])
    }

    func testOtherKindsAreOfferedOnceAndIntendedDivergencesAreSkipped() {
        var absorbed = Divergence(
            kind: .unexpectedEvent,
            label: "Absorbed",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: ""
        )
        absorbed.classification = .intended
        let offer = Divergence.suggestedDeclarations(across: [
            Divergence(kind: .unexpectedEvent, label: "Rewards", baselineSeq: 0, candidateSeq: 0, detail: ""),
            Divergence(kind: .unexpectedEvent, label: "Rewards", baselineSeq: 1, candidateSeq: 1, detail: ""),
            absorbed,
            changed("Receipt", "total", from: 1, to: 2)
        ])
        XCTAssertEqual(offer, [#"Emits("Rewards")"#, #"Changes("Receipt", field: "total").to(2)"#])
    }

    func testDeclarationsMatchingNamesWhatAbsorbsADivergence() {
        let intent = Intent {
            Changes("Receipt", field: "total").increases()
            Changes("Receipt", field: "total").when("promo", is: "SAVE10")
            Emits("Unrelated")
        }
        XCTAssertEqual(
            intent.declarationsMatching(changed("Receipt", "total", from: 1, to: 2), inputs: ["promo": ["SAVE10"]]),
            [
                #"Changes("Receipt", field: "total").increases()"#,
                #"Changes("Receipt", field: "total").when("promo", is: "SAVE10")"#
            ]
        )
        XCTAssertEqual(intent.declarationsMatching(changed("Receipt", "total", from: 2, to: 1)), [])
    }

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
}
