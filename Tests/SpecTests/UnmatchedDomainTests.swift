import Foundation
import HaruspecCore
@testable import HaruspecSpec
import XCTest

/// The last unchecked string in the DSL. Typed op arguments removed the key an *argument* is joined by,
/// but a seam the SUT reaches rather than the spec passes — a clock, an RNG, a `UserDefaults` key, a
/// file path — is still named by a string, and the name is one the author didn't define: `SeamClock`
/// defaults to `"clock"` inside its own initializer, `SeamFileSystem` composes `"fs.read:<path>"` at
/// runtime. Getting it wrong produced a green banner over a spec that swept nothing, and claimed the
/// full seam-variant count while generating identical cassettes.
final class UnmatchedDomainTests: XCTestCase {
    private func spec(_ name: String, varying key: String) -> BaselinedSpec<PromoCart> {
        Spec<PromoCart>(name)
            .operations {
                Op("add") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("qty", default: 2)))
                }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary { Seam(key, .int(1 ... 20)) }
            .baselined { GoodCart(center: $0.notifications) }
    }

    private func makeRefactor(_ context: SeamContext) -> PromoCart {
        RefactorCart(center: context.notifications)
    }

    func testADomainNothingReadsCannotBeVerifiedOver() async {
        let verdict = await spec("unmatched.typo", varying: "qtyy").verify(candidate: makeRefactor)

        XCTAssertEqual(
            verdict.verdict,
            .cannotVerify,
            "an EQUIVALENT here claims a swept surface that was never swept\n\(verdict.report())"
        )
        XCTAssertEqual(verdict.coverage.unmatchedDomains.map(\.boundary), ["qtyy"])
    }

    func testTheMatchingKeyStillVerifiesCleanly() async {
        let verdict = await spec("unmatched.correct", varying: "qty").verify(candidate: makeRefactor)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertTrue(verdict.coverage.unmatchedDomains.isEmpty)
        XCTAssertEqual(verdict.coverage.domainExercised, ["qty"])
    }

    func testTheGapIsNamedInTheReport() async {
        let report = await spec("unmatched.report", varying: "qtyy").verify(candidate: makeRefactor).report()

        XCTAssertTrue(report.contains("declared domain matched nothing: qtyy"), report)
    }

    func testASweepOfNothingIsNotReportedAsSixtyFourVariants() async {
        // The variant count came from "did the spec declare any domain", which a typo satisfies. The
        // budget then bought 64 generations of the same cassette and the verdict called them variants.
        let explored = await spec("unmatched.variants", varying: "qtyy")
            .verify(candidate: makeRefactor).exploration

        XCTAssertEqual(explored.variantsPerOrdering, 1, "nothing can vary, so there is one input")
        XCTAssertFalse(explored.summary.contains("seam variants"), explored.summary)
    }

    func testADomainSweptOverNothingReportsZeroRatherThanStayingSilent() async {
        // The report only appended the domain clause above 0%, which hid exactly the damning case.
        let report = await spec("unmatched.zero", varying: "qtyy").verify(candidate: makeRefactor).report()

        XCTAssertTrue(report.contains("domain-swept 0%"), report)
    }

    func testTheUnmatchedKeyCountsAgainstTheDeclaredSurface() async {
        // Leaving it out would report a fraction of a surface quietly smaller than the spec describes.
        let verdict = await spec("unmatched.fraction", varying: "qtyy").verify(candidate: makeRefactor)

        XCTAssertTrue(verdict.coverage.declared.contains("qtyy"))
        XCTAssertFalse(verdict.coverage.exercised.contains("qtyy"))
        XCTAssertLessThan(verdict.coverage.fraction ?? 1, 1)
    }

    func testATypedArgumentCannotProduceThisGapAtAll() async {
        // There is no key to mistype: `.operations` harvests the domain against the key the read uses.
        let typed = Spec<PromoCart>("unmatched.typed")
            .operations {
                Op("add", varying: .int(1 ... 20)) { cart, qty in
                    cart.addItem(priceCents: 999, qty: qty)
                }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .baselined { GoodCart(center: $0.notifications) }

        let verdict = await typed.verify(candidate: makeRefactor)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertTrue(verdict.coverage.unmatchedDomains.isEmpty)
        XCTAssertEqual(verdict.coverage.domainExercised, ["add.0"])
    }
}
