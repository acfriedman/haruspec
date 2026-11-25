import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

private struct PromoCartSpec: SpecProviding {
    var spec: Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.check")
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 4)
            }
    }
}

final class CheckTests: XCTestCase {
    private let subject = PromoCartSpec().baselined(on: makeGood)

    func testASpecThatDeclaresNoCandidatesStillChecksAPort() async throws {
        try await subject.check("RefactorCart", reportsIn: scratch(), port(RefactorCart.init))
    }

    func testACounterexamplePassesByDivergingExactlyAsTheTestDeclares() async throws {
        try await subject.check(
            "RoundBugCart",
            expecting: .diverged,
            reportsIn: scratch(),
            port(RoundBugCart.init)
        )
    }

    func testAnUnmetExpectationThrowsSayingWhichWayItWasSupposedToGo() async {
        await XCTAssertThrowsErrorAsync {
            // Declared as a counterexample, but it is in fact a faithful port.
            try await subject.check(
                "RefactorCart",
                expecting: .diverged,
                reportsIn: scratch(),
                port(RefactorCart.init)
            )
        } handler: { error in
            XCTAssertTrue(
                (error as? SpecCatalog.CheckFailure)?
                    .description.hasPrefix("expected diverged, got equivalent") ?? false,
                "\(error)"
            )
        }
    }

    func testAFaithfulPortThatRegressesFailsTheCheck() async {
        await XCTAssertThrowsErrorAsync {
            try await subject
                .check("RoundBugCart", reportsIn: scratch(), port(RoundBugCart.init))
        } handler: { error in
            XCTAssertTrue(
                (error as? SpecCatalog.CheckFailure)?
                    .description.hasPrefix("expected equivalent, got diverged") ?? false,
                "\(error)"
            )
            // The console already printed the report; the thrown error repeats only its headline.
            XCTAssertFalse("\(error)".contains("\n"), "\(error)")
        }
    }

    func testTheReportIsWrittenUnderTheNameTheCheckGaveIt() async {
        let directory = scratch()
        let verdict = await subject
            .verify("RefactorCart", reportsIn: directory, port(RefactorCart.init))

        XCTAssertEqual(verdict.actual, .equivalent)
        XCTAssertTrue(verdict.metExpectation)
        XCTAssertEqual(
            verdict.htmlReportPath,
            directory.appendingPathComponent("RefactorCart.html").path
        )
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true)
    }
}

// Checking a build the spec never declared: that the port is an argument of the test rather than a line
// in the declaration, that the expectation travels with the call (so a deliberate counterexample passes
// by diverging and a faithful port under `.diverged` fails saying which way it was supposed to go), and
// that the report is written under the name the check gave it.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

/// Returns the wiring an adopting app writes once, so each check is a one-liner: an unapplied
/// initializer reference with the shared collaborators bound here rather than repeated per port.
///
/// - Parameter make: Builds the cart, given the notification center it posts to.
/// - Returns: A factory that builds the cart on a seam context's notification center.
private func port(_ make: @escaping (NotificationCenter) -> some PromoCart) -> (SeamContext) -> PromoCart {
    { context in make(context.notifications) }
}
