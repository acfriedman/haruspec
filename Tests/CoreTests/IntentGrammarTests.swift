@testable import HaruspecCore
import XCTest

/// The text form of the intent DSL: every declaration spelling parses to the `Intent` its Swift
/// twin builds, every engine rendering parses back verbatim, and an unparseable line fails naming
/// itself — the grammar is an interface, and its errors are the documentation.
final class IntentGrammarTests: XCTestCase {
    // MARK: - Declaration spellings

    func testEveryDeclarationSpellingParses() throws {
        let intent = try IntentGrammar.intent(parsing: """
        Emits("LoyaltyPointsEarned")
        Omits("CartDidChange")
        Changes("Search.query")
        Changes("CheckoutDidComplete", field: "totalCents", "discount")
        Reorders("Drawer.first", "Drawer.second")
        Awaits("Inventory.reserve")
        Drops(synchronizationOf: "CatalogDidPrefetch")
        Relaxes(orderingOf: .queue("com.emporium.cart"))
        Moves("Searcher.products", from: .main, to: .ambient)
        Moves(everythingFrom: .queue("com.emporium.cart"), to: .actor("SwiftCartActor"))
        Accepts(uncaptured: "Combine")
        """)

        XCTAssertEqual(intent.expectedNewEvents, ["LoyaltyPointsEarned"])
        XCTAssertEqual(intent.expectedRemovedEvents, ["CartDidChange"])
        XCTAssertEqual(intent.expectedValueChanges["Search.query"], [])
        XCTAssertEqual(intent.expectedValueChanges["CheckoutDidComplete"], ["totalCents", "discount"])
        XCTAssertEqual(intent.expectedReorders, ["Drawer.first", "Drawer.second"])
        XCTAssertEqual(intent.expectedOrderingAdditions, ["Inventory.reserve"])
        XCTAssertEqual(intent.expectedOrderingLosses, ["CatalogDidPrefetch"])
        XCTAssertEqual(intent.expectedOrderingRelaxations, [.queue("com.emporium.cart")])
        XCTAssertEqual(intent.expectedDomainMigrations, [
            Intent.DomainMove(labels: ["Searcher.products"], from: .main, to: .ambient),
            Intent.DomainMove(from: .queue("com.emporium.cart"), to: .actor("SwiftCartActor"))
        ])
        XCTAssertEqual(intent.acceptedBlindSpots, ["Combine"])
    }

    func testActorTypeSelfSpellingParsesLikeSwift() throws {
        // A declaration pasted from a check site must parse unchanged.
        let intent = try IntentGrammar.intent(
            parsing: "Moves(\"Cart.add\", from: .ambient, to: .actor(SwiftCartActor.self))"
        )
        XCTAssertEqual(
            intent.expectedDomainMigrations,
            [Intent.DomainMove(labels: ["Cart.add"], from: .ambient, to: .actor("SwiftCartActor"))]
        )
    }

    func testBlankLinesAndCommentsAreIgnored() throws {
        let intent = try IntentGrammar.intent(parsing: """

        // the feature event
        Emits("LoyaltyPointsEarned")

        """)
        XCTAssertEqual(intent.expectedNewEvents, ["LoyaltyPointsEarned"])
    }

    // MARK: - Renderings parse back

    func testDeclarationTextsRoundTripThroughTheGrammar() throws {
        let declared = Intent {
            Emits("LoyaltyPointsEarned")
            Changes("CheckoutDidComplete", field: "totalCents")
            Reorders("Drawer.first")
            Moves("Cart.add", "CartDidChange", from: .queue("com.emporium.cart"), to: .actor("SwiftCartActor"))
            Relaxes(orderingOf: .queue("delivery"))
            Drops(synchronizationOf: "CatalogDidPrefetch")
            Awaits("Inventory.reserve")
            Omits("timer")
        }
        let reparsed = try IntentGrammar.intent(parsing: declared.declarationTexts.joined(separator: "\n"))
        XCTAssertEqual(reparsed, declared)
    }

    func testSuggestedDeclarationsParseBack() throws {
        let divergences = [
            Divergence(
                kind: .unexpectedEvent,
                label: "LoyaltyPointsEarned",
                baselineSeq: 0,
                candidateSeq: 0,
                detail: ""
            ),
            Divergence(
                kind: .valueMismatch,
                label: "Search.query",
                baselineSeq: 0,
                candidateSeq: 0,
                detail: "query.0: baseline=MUG candidate=mug"
            ),
            Divergence(
                kind: .domainMigration,
                label: "Cart.add",
                baselineSeq: 0,
                candidateSeq: 0,
                detail: "",
                fromDomain: "queue(serial):com.emporium.cart",
                toDomain: "actor:SwiftCartActor#2"
            ),
            Divergence(
                kind: .orderingRelaxed,
                label: "com.emporium.cart",
                baselineSeq: 0,
                candidateSeq: 0,
                detail: "",
                fromDomain: "queue(serial):com.emporium.cart"
            )
        ]
        for divergence in divergences {
            let suggested = try XCTUnwrap(divergence.suggestedDeclaration)
            let intent = try IntentGrammar.intent(parsing: suggested)
            XCTAssertTrue(
                intent.declares(divergence),
                "the suggested declaration must absorb the divergence that suggested it: \(suggested)"
            )
        }
    }

    func testATimingRegressionSuggestsNothing() {
        XCTAssertNil(Divergence(kind: .timingRegression, label: "checkout", baselineSeq: 0, candidateSeq: 0, detail: "")
            .suggestedDeclaration)
    }

    // MARK: - Body extraction

    func testBodyBlocksParsePerSpec() throws {
        let intents = try IntentGrammar.intents(inBody: """
        This PR lowercases the query before dedupe.

        ```haruspec-intent search.combine
        Changes("Search.query")
        ```

        And renames the cart event.

        ```haruspec-intent cart.objc-to-swift
        Emits("CartDidSync")
        ```
        """)
        XCTAssertEqual(intents.count, 2)
        XCTAssertEqual(intents["search.combine"]?.expectedValueChanges["Search.query"], [])
        XCTAssertEqual(intents["cart.objc-to-swift"]?.expectedNewEvents, ["CartDidSync"])
    }

    func testABodyWithoutBlocksIsParityMode() throws {
        XCTAssertEqual(try IntentGrammar.intents(inBody: "Just a description."), [:])
    }

    func testAQuotedFenceDoesNotOpenABlock() throws {
        // A body quoting a log or diff that mentions the marker must not activate it.
        let intents = try IntentGrammar.intents(inBody: """
        ```text
        the docs say: open a ```haruspec-intent search.combine block
        ```
        """)
        XCTAssertEqual(intents, [:])
    }

    func testASecondBlockForTheSameSpecIsRefused() {
        XCTAssertThrowsError(try IntentGrammar.intents(inBody: """
        ```haruspec-intent search.combine
        Emits("A")
        ```
        ```haruspec-intent search.combine
        Emits("B")
        ```
        """)) { error in
            XCTAssertTrue("\(error)".contains("already has an intent block"), "\(error)")
        }
    }

    func testABlockNamingNoSpecIsRefusedWithTheFix() {
        XCTAssertThrowsError(try IntentGrammar.intents(inBody: """
        ```haruspec-intent
        Emits("A")
        ```
        """)) { error in
            XCTAssertTrue("\(error)".contains("names no spec"), "\(error)")
        }
    }

    func testAnUnclosedBlockIsRefused() {
        XCTAssertThrowsError(try IntentGrammar.intents(inBody: """
        ```haruspec-intent search.combine
        Emits("A")
        """)) { error in
            XCTAssertTrue("\(error)".contains("never closed"), "\(error)")
        }
    }

    // MARK: - Teaching errors

    func testAnUnknownDeclarationNamesTheVocabulary() {
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: "Tolerates(\"jitter\")")) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("is not a declaration"), message)
            XCTAssertTrue(message.contains("Changes"), "the error must teach the vocabulary: \(message)")
        }
    }

    func testAParseErrorNamesItsLineInTheEnclosingBody() {
        XCTAssertThrowsError(try IntentGrammar.intents(inBody: """
        line one

        ```haruspec-intent search.combine
        Emits("Fine")
        Emits(Unquoted)
        ```
        """)) { error in
            guard let grammarError = error as? IntentGrammarError else {
                return XCTFail("expected IntentGrammarError, got \(error)")
            }
            XCTAssertEqual(grammarError.line, 5, "line numbers are the body's, not the block's")
            XCTAssertTrue(grammarError.description.contains("quoted"), grammarError.description)
        }
    }

    func testTrailingTextIsRefused() {
        XCTAssertThrowsError(try IntentGrammar.intent(parsing: "Emits(\"A\") Emits(\"B\")")) { error in
            XCTAssertTrue("\(error)".contains("one declaration per line"), "\(error)")
        }
    }
}
