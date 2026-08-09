@testable import HaruspecCore
import XCTest

/// The declaration DSL — sentences about the port, folded into one `Intent`.
final class IntentionsTests: XCTestCase {
    func testTheBuilderFoldsEveryKind() {
        let intent = Intent {
            Moves("CartDidChange", from: .queue("com.emporium.cart"), to: .actor("SwiftCartActor"))
            Relaxes(orderingOf: .queue("com.emporium.cart"))
            Drops(synchronizationOf: "Inventory.reserve")
            Awaits("Analytics.flush")
            Emits("LoyaltyPointsEarned")
            Omits("LegacyPing")
            Changes("CheckoutDidComplete", field: "totalCents")
        }

        XCTAssertEqual(intent.expectedDomainMigrations.count, 1)
        XCTAssertEqual(intent.expectedOrderingRelaxations, [.queue("com.emporium.cart")])
        XCTAssertEqual(intent.expectedOrderingLosses, ["Inventory.reserve"])
        XCTAssertEqual(intent.expectedOrderingAdditions, ["Analytics.flush"])
        XCTAssertEqual(intent.expectedNewEvents, ["LoyaltyPointsEarned"])
        XCTAssertEqual(intent.expectedRemovedEvents, ["LegacyPing"])
        XCTAssertEqual(intent.expectedValueChanges, ["CheckoutDidComplete": ["totalCents"]])
    }

    /// A queue is declared by label, whichever discipline it has: the *move* is what is declared,
    /// and a discipline change is separately gated by `orderingRelaxed` — so nothing is lost.
    func testAQueueNameMatchesEitherDiscipline() {
        let intent = Intent { Moves("Analytics.track", from: .queue("com.emporium.delivery"), to: .ambient) }

        for discipline in ["queue(serial)", "queue(concurrent)"] {
            let move = Divergence(
                kind: .domainMigration,
                label: "Analytics.track",
                baselineSeq: 0,
                candidateSeq: 0,
                detail: "",
                fromDomain: "\(discipline):com.emporium.delivery",
                toDomain: "ambient"
            )
            XCTAssertTrue(intent.declares(move), "\(discipline) should match a discipline-blind declaration")
        }
    }

    /// A declaration is a standing excuse, so it covers exactly the events it names: a different
    /// event migrating between the same pair gates again — breadth never happens by accident.
    func testALabeledMoveDoesNotExcuseAnotherEventOnTheSamePair() {
        let intent = Intent { Moves("Inventory.reserve", from: .queue("com.emporium.cart"), to: .ambient) }
        func move(_ label: String) -> Divergence {
            Divergence(
                kind: .domainMigration,
                label: label,
                baselineSeq: 0,
                candidateSeq: 0,
                detail: "",
                fromDomain: "queue(serial):com.emporium.cart",
                toDomain: "ambient"
            )
        }

        XCTAssertTrue(intent.declares(move("Inventory.reserve")))
        XCTAssertFalse(intent.declares(move("CheckoutDidComplete")), "an unnamed event must still gate")
    }

    /// The wholesale spelling covers every label on the pair — deliberately, in a word a reviewer
    /// can see and question.
    func testEverythingFromCoversAnyLabelOnThePair() {
        let intent = Intent { Moves(everythingFrom: .queue("com.emporium.cart"), to: .ambient) }
        let move = Divergence(
            kind: .domainMigration,
            label: "SomeEventNobodyForesaw",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "",
            fromDomain: "queue(serial):com.emporium.cart",
            toDomain: "ambient"
        )

        XCTAssertTrue(intent.declares(move))
    }

    /// A relaxation is declared by the domain that lost its guarantee, matched structurally against
    /// the divergence's origin — not against prose.
    func testARelaxationIsDeclaredByItsOriginDomain() {
        let intent = Intent { Relaxes(orderingOf: .queue("com.emporium.cart")) }
        let relaxed = Divergence(
            kind: .orderingRelaxed,
            label: "com.emporium.cart",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "",
            fromDomain: "queue(serial):com.emporium.cart",
            toDomain: "ambient"
        )

        XCTAssertTrue(intent.declares(relaxed))
        XCTAssertFalse(Intent { Relaxes(orderingOf: .queue("com.emporium.checkout")) }.declares(relaxed))
    }

    /// `Changes` with no field named means any field of that event — and only that event.
    func testChangesWithoutAFieldDeclaresAnyValueChangeOnThatLabel() {
        let intent = Intent { Changes("CheckoutDidComplete") }
        func mismatch(_ label: String) -> Divergence {
            Divergence(
                kind: .valueMismatch,
                label: label,
                baselineSeq: 0,
                candidateSeq: 0,
                detail: "totalCents: baseline=1 candidate=2"
            )
        }

        XCTAssertTrue(intent.declares(mismatch("CheckoutDidComplete")))
        XCTAssertFalse(intent.declares(mismatch("CartDidChange")))
    }

    /// The declaration spellings survive a round-trip (an intent is a JSON artifact for the CLI and
    /// the CI intent-file story), and an unrecognized spelling is refused, never coerced.
    func testDomainNamesRoundTripAndRefuseUnknownSpellings() throws {
        let names: [DomainName] = [.main, .ambient, .queue("com.emporium.cart"), .actor("SwiftCartActor")]
        for name in names {
            let data = try JSONEncoder().encode(name)
            XCTAssertEqual(try JSONDecoder().decode(DomainName.self, from: data), name)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(DomainName.self, from: Data("\"worker-3\"".utf8))
        )
    }
}
