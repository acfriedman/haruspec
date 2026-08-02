import Foundation
import HaruspecCore
import HaruspecScenario
import HaruspecSeams
import XCTest

// The catalog is what lets a test target stop naming scenarios: it flattens several differently-typed
// scenarios into plain `scenario/candidate` strings and runs one by name. These cover the flattening,
// the lookup failures a rename produces, and the continuous selection rule (one declared scenario
// needs no selection; several must be named).

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> PromoCart {
    RoundBugCart(center: ctx.notifications)
}

final class ScenarioCatalogTests: XCTestCase {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
    }

    private func cart(_ name: String) -> Scenario<PromoCart> {
        Scenario<PromoCart>(name)
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

    private func catalog() -> ScenarioCatalog {
        ScenarioCatalog(cart("promo-cart").entry(), cart("promo-cart.second").entry())
    }

    // MARK: Migration cases

    func testEveryScenarioCandidatePairBecomesOneCase() {
        XCTAssertEqual(catalog().migrationCases, [
            "promo-cart/RefactorCart",
            "promo-cart/RoundBugCart",
            "promo-cart.second/RefactorCart",
            "promo-cart.second/RoundBugCart"
        ])
    }

    func testACaseRunsTheCandidateItNames() throws {
        let verdict = try XCTUnwrap(
            catalog().verify(migrationCase: "promo-cart/RoundBugCart", reportsIn: scratch())
        )

        XCTAssertEqual(verdict.name, "RoundBugCart")
        XCTAssertEqual(verdict.actual, .diverged)
        // Declared as a counterexample, so diverging is how it passes.
        XCTAssertTrue(verdict.metExpectation)
    }

    func testARenamedHalfOfACaseFailsTheLookup() {
        let catalog = catalog()

        XCTAssertNil(catalog.verify(migrationCase: "promo-cart/Renamed"))
        XCTAssertNil(catalog.verify(migrationCase: "renamed/RefactorCart"))
        XCTAssertNil(catalog.verify(migrationCase: "no-separator"))
    }

    // MARK: Continuous selection

    func testNoModeSelectsNoScenariosSoAnOrdinaryTestRunIsUntouched() {
        XCTAssertEqual(catalog().continuousScenarios(environment: [:]), [])
    }

    func testASingleDeclaredScenarioNeedsNoSelection() {
        let single = ScenarioCatalog(cart("promo-cart").entry())

        XCTAssertEqual(
            single.continuousScenarios(environment: ["HARUSPEC_MODE": "replay"]),
            ["promo-cart"]
        )
    }

    func testSeveralDeclaredScenariosMustBeNamed() {
        let catalog = catalog()

        XCTAssertEqual(catalog.continuousScenarios(environment: ["HARUSPEC_MODE": "replay"]), [])
        XCTAssertEqual(
            catalog.continuousScenarios(environment: [
                "HARUSPEC_MODE": "replay",
                "HARUSPEC_SCENARIO": "promo-cart.second"
            ]),
            ["promo-cart.second"]
        )
    }

    // MARK: Continuous runs

    func testRecordAndReplayRoundTripThroughTheCatalog() throws {
        let catalog = catalog()
        let planURL = scratch().appendingPathComponent("plan.json")
        let resultsDir = scratch()

        let recorded = try XCTUnwrap(catalog.runContinuous(scenario: "promo-cart", environment: [
            "HARUSPEC_MODE": "record",
            "HARUSPEC_PLAN_PATH": planURL.path
        ]))
        XCTAssertTrue(recorded.succeeded, recorded.summary)

        let replayed = try XCTUnwrap(catalog.runContinuous(scenario: "promo-cart", environment: [
            "HARUSPEC_MODE": "replay",
            "HARUSPEC_PLAN_PATH": planURL.path,
            "HARUSPEC_RESULTS_DIR": resultsDir.path
        ]))
        XCTAssertTrue(replayed.succeeded, replayed.summary)
    }

    func testAnUndeclaredScenarioFailsTheLookup() {
        XCTAssertNil(catalog().runContinuous(scenario: "renamed", environment: ["HARUSPEC_MODE": "record"]))
    }
}
