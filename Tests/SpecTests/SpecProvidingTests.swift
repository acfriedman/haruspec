import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// The per-file shape: a spec declaration carries its own test surface, so a project with fifty specs
// keeps no central list to forget an entry in. These cover what a per-spec suite calls — the
// candidate arguments, the one-call check, and the continuous selection that keeps an ordinary run
// untouched.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> PromoCart {
    RoundBugCart(center: ctx.notifications)
}

private struct PromoCartSpec: SpecProviding {
    var spec: Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.perfile")
            .system(makeGood)
            .operations {
                Op("addCoffee") { $0.addItem(priceCents: 999, qty: 3) }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .candidates {
                Candidate("RefactorCart", makeRefactor)
                Candidate("RoundBugCart", expecting: .diverged, makeRoundBug)
            }
    }
}

final class SpecProvidingTests: XCTestCase {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("perfile-\(UUID().uuidString)", isDirectory: true)
    }

    func testCandidateNamesAreTheMigrationArguments() {
        XCTAssertEqual(PromoCartSpec().candidateNames, ["RefactorCart", "RoundBugCart"])
    }

    func testCheckPassesWhenAPortEarnsItsDeclaredVerdict() throws {
        // The counterexample meets its expectation by diverging, so neither throws.
        try PromoCartSpec().check(candidate: "RefactorCart", reportsIn: scratch())
        try PromoCartSpec().check(candidate: "RoundBugCart", reportsIn: scratch())
    }

    func testCheckNamesACandidateThatIsNoLongerDeclared() {
        XCTAssertThrowsError(try PromoCartSpec().check(candidate: "Renamed")) { error in
            XCTAssertEqual(
                (error as? SpecCatalog.CheckFailure)?.description,
                "Renamed is no longer a declared candidate"
            )
        }
    }

    func testNoModeSelectsNothingSoAnOrdinaryTestRunIsUntouched() {
        XCTAssertEqual(PromoCartSpec().continuousModes(environment: [:]), [])
        XCTAssertEqual(
            PromoCartSpec().continuousModes(environment: ["HARUSPEC_MODE": "replay"]),
            [.replay]
        )
    }

    func testContinuousRecordAndReplayRoundTripPerSpec() throws {
        let planURL = scratch().appendingPathComponent("plan.json")
        let resultsDir = scratch()

        try PromoCartSpec().checkContinuous(.record, environment: [
            "HARUSPEC_MODE": "record",
            "HARUSPEC_PLAN_PATH": planURL.path
        ])
        try PromoCartSpec().checkContinuous(.replay, environment: [
            "HARUSPEC_MODE": "replay",
            "HARUSPEC_PLAN_PATH": planURL.path,
            "HARUSPEC_RESULTS_DIR": resultsDir.path
        ])
    }

    func testContinuousReportsAMissingDestinationRatherThanThrowingRaw() {
        XCTAssertThrowsError(
            try PromoCartSpec().checkContinuous(.record, environment: ["HARUSPEC_MODE": "record"])
        ) { error in
            XCTAssertTrue(
                (error as? SpecCatalog.CheckFailure)?.description.contains("HARUSPEC_PLAN_PATH") ?? false,
                "\(error)"
            )
        }
    }
}
