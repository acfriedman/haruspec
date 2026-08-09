import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// Declaring candidates alongside the ops: that each is verified against the same baseline, that the
// expectation declared with a candidate is what `metExpectation` answers (so a deliberate
// counterexample passes by diverging), and that a name that no longer exists fails the lookup rather
// than silently verifying nothing.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> PromoCart {
    RoundBugCart(center: ctx.notifications)
}

/// The wiring an adopting app writes once so each candidate is a one-liner: an unapplied initializer
/// reference, with the shared collaborators bound here rather than repeated per port.
private func port(_ make: @escaping (NotificationCenter) -> some PromoCart) -> (SeamContext) -> PromoCart {
    { context in make(context.notifications) }
}

final class CandidatesTests: XCTestCase {
    private func reportsDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("candidates-\(UUID().uuidString)", isDirectory: true)
    }

    private func cart() -> Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.candidates")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .candidates {
                // Both spellings an adopting app will reach for: a factory reference, and the
                // trailing-closure form that wires collaborators inline.
                Candidate("RefactorCart", makeRefactor)
                Candidate("RoundBugCart", expecting: .diverged) { context in
                    RoundBugCart(center: context.notifications)
                }
            }
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 4)
            }
    }

    func testCandidateNamesAreDeclarationOrderAndCarryNoVerdict() {
        XCTAssertEqual(cart().candidateNames, ["RefactorCart", "RoundBugCart"])
    }

    func testEveryCandidateIsVerifiedAgainstTheSameBaseline() async {
        let verdicts = await cart().verifyAll(reportsIn: reportsDirectory())

        XCTAssertEqual(verdicts.map(\.name), ["RefactorCart", "RoundBugCart"])
        XCTAssertEqual(verdicts[0].actual, .equivalent)
        XCTAssertEqual(verdicts[1].actual, .diverged)
    }

    func testADeclaredCounterexampleMeetsItsExpectationByDiverging() async {
        let verdicts = await cart().verifyAll(reportsIn: reportsDirectory())

        // Both pass: one by matching the baseline, one by diverging exactly as declared.
        XCTAssertTrue(verdicts.allSatisfy(\.metExpectation), verdicts.map { $0.report() }.joined())
    }

    func testAnUnmetExpectationSaysWhichWayItWasSupposedToGo() async throws {
        let spec = cart().candidates {
            // Declared as a counterexample, but it is in fact a faithful port.
            Candidate("RefactorCart", expecting: .diverged, makeRefactor)
        }

        let named = await spec.verify(candidateNamed: "RefactorCart")
        let verdict = try XCTUnwrap(named)

        XCTAssertEqual(verdict.actual, .equivalent)
        XCTAssertFalse(verdict.metExpectation)
        XCTAssertTrue(
            verdict.report().hasPrefix("expected diverged, got equivalent"),
            verdict.report()
        )
    }

    func testEachCandidateGetsItsOwnNamedReport() async {
        let directory = reportsDirectory()
        let verdicts = await cart().verifyAll(reportsIn: directory)

        XCTAssertEqual(
            verdicts.compactMap(\.htmlReportPath),
            ["RefactorCart", "RoundBugCart"].map { directory.appendingPathComponent("\($0).html").path }
        )
    }

    func testAnUndeclaredNameFailsTheLookup() async {
        let renamed = await cart().verify(candidateNamed: "SwiftCartRenamed")
        XCTAssertNil(renamed)
    }

    /// The table form an adopting app writes: one line per port, unapplied initializer references
    /// bound through a single wiring helper. Proves the generic inference and the existential return.
    func testCandidatesReadAsATableOfInitializerReferences() async {
        let verdicts = await cart()
            .candidates {
                Candidate("RefactorCart", port(RefactorCart.init))
                Candidate("RoundBugCart", expecting: .diverged, port(RoundBugCart.init))
            }
            .verifyAll(reportsIn: reportsDirectory())

        XCTAssertEqual(verdicts.map(\.name), ["RefactorCart", "RoundBugCart"])
        XCTAssertTrue(verdicts.allSatisfy(\.metExpectation), verdicts.map { $0.report() }.joined())
    }
}
