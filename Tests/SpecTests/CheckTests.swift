import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// Checking a build the spec never declared: that the port is an argument of the test rather than a line
// in the declaration, that the expectation travels with the call (so a deliberate counterexample passes
// by diverging and a faithful port under `.diverged` fails saying which way it was supposed to go), and
// that the report is written under the name the check gave it.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

/// The wiring an adopting app writes once, so each check is a one-liner: an unapplied initializer
/// reference with the shared collaborators bound here rather than repeated per port.
private func port(_ make: @escaping (NotificationCenter) -> some PromoCart) -> (SeamContext) -> PromoCart {
    { context in make(context.notifications) }
}

private struct PromoCartSpec: SpecProviding {
    var spec: Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.check")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 4)
            }
    }
}

final class CheckTests: XCTestCase {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true)
    }

    func testASpecThatDeclaresNoCandidatesStillChecksAPort() throws {
        try PromoCartSpec().check("RefactorCart", reportsIn: scratch(), port(RefactorCart.init))
    }

    func testACounterexamplePassesByDivergingExactlyAsTheTestDeclares() throws {
        try PromoCartSpec().check(
            "RoundBugCart",
            expecting: .diverged,
            reportsIn: scratch(),
            port(RoundBugCart.init)
        )
    }

    func testAnUnmetExpectationThrowsSayingWhichWayItWasSupposedToGo() {
        XCTAssertThrowsError(
            // Declared as a counterexample, but it is in fact a faithful port.
            try PromoCartSpec().check(
                "RefactorCart",
                expecting: .diverged,
                reportsIn: scratch(),
                port(RefactorCart.init)
            )
        ) { error in
            XCTAssertTrue(
                (error as? SpecCatalog.CheckFailure)?
                    .description.hasPrefix("expected diverged, got equivalent") ?? false,
                "\(error)"
            )
        }
    }

    func testAFaithfulPortThatRegressesFailsTheCheck() {
        XCTAssertThrowsError(
            try PromoCartSpec().check("RoundBugCart", reportsIn: scratch(), port(RoundBugCart.init))
        ) { error in
            XCTAssertTrue(
                (error as? SpecCatalog.CheckFailure)?
                    .description.hasPrefix("expected equivalent, got diverged") ?? false,
                "\(error)"
            )
        }
    }

    func testTheReportIsWrittenUnderTheNameTheCheckGaveIt() {
        let directory = scratch()
        let verdict = PromoCartSpec().spec
            .verify("RefactorCart", reportsIn: directory, port(RefactorCart.init))

        XCTAssertEqual(verdict.actual, .equivalent)
        XCTAssertTrue(verdict.metExpectation)
        XCTAssertEqual(
            verdict.htmlReportPath,
            directory.appendingPathComponent("RefactorCart.html").path
        )
    }
}
