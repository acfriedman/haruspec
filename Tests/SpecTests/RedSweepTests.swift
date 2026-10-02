import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace
import XCTest

// A red sweep walks every probe, so one bug that fails nearly every case cannot end the sweep before
// a quieter bug is reached. Asserted over a live verify (the campaign path) and over the finding
// dedupe the reports list beside the reported case.

/// Two bugs. The loud one fails every probe: `CartChanged` carries the subtotal from before the add.
/// The quiet one fails only at the top of the quantity domain: a single 20-coffee basket loses a cent.
private final class LoudAndQuietBugCart: PromoCart {
    private let center: NotificationCenter
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter) {
        self.center = center
    }

    func addItem(priceCents: Int, qty: Int) {
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
        subtotal += priceCents * qty
    }

    func applyPromo() {
        promo = true
    }

    func checkout() -> Int {
        let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0
        var total = subtotal - discount
        if subtotal == 999 * 20 {
            total -= 1
        }
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        Haruspec.marker("checkout_completed")
        return total
    }
}

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeLoudAndQuiet(_ ctx: SeamContext) -> PromoCart {
    LoudAndQuietBugCart(center: ctx.notifications)
}

final class RedSweepTests: XCTestCase {
    private func cart() -> Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.red-sweep")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 10)
            }
    }

    func testALoudBugDoesNotHideAQuietOne() async throws {
        let verdict = await cart().verify(against: makeLoudAndQuiet)
        XCTAssertEqual(verdict.verdict, .diverged)

        let cases = try XCTUnwrap(verdict.failingCases, "a live red carries every failing case")
        let found = verdict.diff.divergences + cases.unreported(beside: verdict.diff.divergences)
        XCTAssertTrue(found.contains { $0.label == "CartChanged" }, "the loud bug")
        XCTAssertTrue(found.contains { $0.label == "CheckoutCompleted" }, "the quiet bug, behind the loud one")

        let report = verdict.report()
        XCTAssertTrue(report.contains("CartChanged"), report)
        XCTAssertTrue(report.contains("CheckoutCompleted"), report)
    }

    func testOtherCasesListEachFindingOnceAndSkipWhatTheReportedCaseShows() {
        func mismatch(_ label: String, _ field: String, _ candidate: Int) -> Divergence {
            Divergence(
                kind: .valueMismatch,
                label: label,
                baselineSeq: 1,
                candidateSeq: 1,
                detail: "\(field): baseline=0 candidate=\(candidate)",
                field: field,
                baselineValue: .int(0),
                candidateValue: .int(Int64(candidate))
            )
        }
        let reported = [mismatch("CartChanged", "subtotal", 5)]
        let cases = FailingCases(
            probes: [
                DivergentProbe(ordering: ["add"], inputs: CassetteData(tracks: [:]), divergences: reported),
                DivergentProbe(
                    ordering: ["add"],
                    inputs: CassetteData(tracks: [:]),
                    divergences: [mismatch("CartChanged", "subtotal", 7), mismatch("CheckoutCompleted", "total", 1)]
                ),
                DivergentProbe(
                    ordering: ["add"],
                    inputs: CassetteData(tracks: [:]),
                    divergences: [mismatch("CheckoutCompleted", "total", 2)]
                )
            ],
            walkedAfterFirst: 2
        )

        let others = cases.unreported(beside: reported)

        XCTAssertEqual(others.map(\.label), ["CheckoutCompleted"], "one line per finding, values aside")
        XCTAssertEqual(others.first?.candidateValue, .int(1), "the first case's example is kept")
    }
}
