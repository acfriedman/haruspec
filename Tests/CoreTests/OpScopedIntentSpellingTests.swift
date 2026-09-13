@testable import HaruspecCore
import XCTest

/// The op-scoped and positioned modifiers as text and JSON, the offer that proposes them, and the
/// union that keeps them apart.
final class OpScopedIntentSpellingTests: XCTestCase {
    private let add0 = OpIdentity(label: "add", position: 0)
    private let add1 = OpIdentity(label: "add", position: 1)
    private let checkout = OpIdentity(label: "checkout", position: 2)

    // MARK: - Spellings

    func testEveryNewSpellingParsesAndRoundTrips() throws {
        let declared = Intent {
            Changes("Receipt", field: "total").increases().only(in: "checkout")
            Emits("RewardsDidUpdate").when("add.quantity", is: 1).once(per: "add").after("CartDidChange")
            Emits("Receipt").only(in: "checkout").before("CheckoutDidComplete")
            Omits("Inventory.reserve").only(in: "add")
            Reorders("Archive.archive", before: "CartDidChange")
            Reorders("A", "B", after: "C")
            Reorders("Plain")
            Moves("Inventory.reserve", from: .main, to: .actor("SwiftCartActor")).only(in: "checkout")
        }
        let texts = declared.declarationTexts
        XCTAssertTrue(
            texts
                .contains(
                    #"Emits("RewardsDidUpdate").when("add.quantity", is: 1).once(per: "add").after("CartDidChange")"#
                ),
            "\(texts)"
        )
        XCTAssertTrue(texts.contains(#"Reorders("Archive.archive", before: "CartDidChange")"#), "\(texts)")
        XCTAssertTrue(
            texts
                .contains(
                    #"Moves("Inventory.reserve", from: .main, to: .actor("SwiftCartActor")).only(in: "checkout")"#
                ),
            "\(texts)"
        )
        XCTAssertEqual(try IntentGrammar.intent(parsing: texts.joined(separator: "\n")), declared)

        XCTAssertEqual(declared.expectedReorders, [
            .init("Archive.archive", position: .before("CartDidChange")),
            .init("A", position: .after("C")),
            .init("B", position: .after("C")),
            "Plain"
        ])
    }

    func testTheNewSpellingsRoundTripThroughJSON() throws {
        let intent = Intent {
            Emits("RewardsDidUpdate").once(per: "add").after("CartDidChange")
            Omits("Legacy").only(in: "checkout")
            Changes("Receipt", field: "total").to(5).only(in: "checkout")
            Reorders("Archive.archive", before: "CartDidChange")
            Reorders("Plain")
            Moves("Inventory.reserve", from: .main, to: .ambient).only(in: "checkout")
        }
        let data = try JSONEncoder().encode(intent)
        XCTAssertEqual(try JSONDecoder().decode(Intent.self, from: data), intent)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""expectedReorders":[{"#), "a directed reorder is an object")
        XCTAssertTrue(json.contains(#""Plain""#), "a bare reorder is still a string")
    }

    func testContradictingAndMisplacedModifiersAreRefused() {
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: #"Emits("X").only(in: "a").once(per: "b")"#)) { error in
            XCTAssertTrue("\(error)".contains(#".once(per: "b") contradicts .only(in: "a")"#), "\(error)")
        }
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: #"Emits("X").after("a").before("b")"#)) { error in
            XCTAssertTrue("\(error)".contains(#".before("b") contradicts .after("a")"#), "\(error)")
        }
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: #"Changes("X").once(per: "add")"#)) { error in
            XCTAssertTrue("\(error)".contains("does not narrow this declaration"), "\(error)")
        }
        XCTAssertThrowsError(try IntentGrammar
            .intent(parsing: #"Moves("X", from: .main, to: .ambient).after("Y")"#)) { error in
                XCTAssertTrue("\(error)".contains("modifiers here are .only"), "\(error)")
            }
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: #"Reorders("A", beside: "B")"#)) { error in
            XCTAssertTrue("\(error)".contains("\"beside\" is not a direction"), "\(error)")
        }
    }

    // MARK: - The offer

    func testAnOfferIsScopedToTheOpEveryCaseShares() throws {
        let emitted = Divergence(
            kind: .unexpectedEvent,
            label: "RewardsDidUpdate",
            baselineSeq: nil,
            candidateSeq: 1,
            detail: "",
            op: add1
        )
        let offered = try XCTUnwrap(emitted.suggestedDeclaration)
        XCTAssertEqual(offered, #"Emits("RewardsDidUpdate").only(in: "add")"#)
        XCTAssertTrue(try IntentGrammar.intent(parsing: offered).declares(emitted), "the offer absorbs its own cause")

        let raised = { (op: OpIdentity?, to: CanonicalValue) in
            Divergence(
                kind: .valueMismatch,
                label: "Points",
                baselineSeq: 0,
                candidateSeq: 0,
                detail: "",
                field: "points",
                baselineValue: 16,
                candidateValue: to,
                op: op
            )
        }
        XCTAssertEqual(
            Divergence.suggestedDeclarations(across: [raised(checkout, 32), raised(checkout, 64)]),
            [#"Changes("Points", field: "points").increases().only(in: "checkout")"#]
        )
        XCTAssertEqual(
            Divergence.suggestedDeclarations(across: [raised(checkout, 32), raised(add0, 64)]),
            [#"Changes("Points", field: "points").increases()"#],
            "cases under different ops — the bare form is the narrowest provable one"
        )
        XCTAssertEqual(
            Divergence.suggestedDeclarations(across: [raised(checkout, 32), raised(nil, 64)]),
            [#"Changes("Points", field: "points").increases()"#],
            "a case with no op cannot be scoped"
        )
    }

    // MARK: - Rejections

    /// A declaration about the divergence whose modifier said no is recorded on it, and the offer
    /// leaves that divergence out: the only absorbing line is wider than the author's, so the
    /// report names the tripwire instead of proposing to loosen it.
    func testARejectedDivergenceNamesItsDeclarationAndGetsNoOffer() {
        let intent = Intent {
            Changes("Receipt", field: "total").increases()
            Emits("RewardsDidUpdate").only(in: "add")
        }
        let dropped = Divergence(
            kind: .valueMismatch,
            label: "Receipt",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "",
            field: "total",
            baselineValue: 100,
            candidateValue: 90,
            op: checkout
        )
        let elsewhere = Divergence(
            kind: .unexpectedEvent,
            label: "RewardsDidUpdate",
            baselineSeq: nil,
            candidateSeq: 1,
            detail: "",
            op: checkout
        )
        let unrelated = Divergence(
            kind: .unexpectedEvent,
            label: "Analytics.track",
            baselineSeq: nil,
            candidateSeq: 2,
            detail: "",
            op: checkout
        )
        let diff = TraceDiff(
            verdict: .diverged,
            baselineName: "b",
            candidateName: "c",
            divergences: [dropped, elsewhere, unrelated]
        )
        let classified = diff.classified(against: intent)

        XCTAssertEqual(classified.divergences.map(\.rejectedBy), [
            [#"Changes("Receipt", field: "total").increases()"#],
            [#"Emits("RewardsDidUpdate").only(in: "add")"#],
            []
        ])
        XCTAssertEqual(
            Divergence.suggestedDeclarations(across: classified.divergences),
            [#"Emits("Analytics.track").only(in: "checkout")"#],
            "only the divergence nobody declared gets an offer"
        )
    }

    func testRejectionsRoundTripThroughJSONAndAnEmptyListIsNotWritten() throws {
        let rejected = Divergence(
            kind: .unexpectedEvent,
            label: "X",
            baselineSeq: nil,
            candidateSeq: 1,
            detail: "",
            rejectedBy: [#"Emits("X").only(in: "add")"#]
        )
        let plain = Divergence(kind: .unexpectedEvent, label: "Y", baselineSeq: nil, candidateSeq: 2, detail: "")
        let data = try JSONEncoder().encode([rejected, plain])
        XCTAssertEqual(try JSONDecoder().decode([Divergence].self, from: data), [rejected, plain])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json.components(separatedBy: "rejectedBy").count - 1, 1)
    }

    // MARK: - Merging

    func testMergingKeepsScopedFormsDistinct() {
        let inAdd = Intent { Emits("X").only(in: "add") }
        let inCheckout = Intent { Emits("X").only(in: "checkout") }
        let merged = inAdd.merging(inCheckout)
        XCTAssertEqual(merged.expectedNewEvents.count, 2, "two scopes are two excuses, never one wide one")
        let elsewhere = Divergence(
            kind: .unexpectedEvent,
            label: "X",
            baselineSeq: nil,
            candidateSeq: 0,
            detail: "",
            op: OpIdentity(label: "remove", position: 0)
        )
        XCTAssertFalse(merged.declares(elsewhere))
    }
}
