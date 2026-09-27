import HaruspecCore
import HaruspecMacros
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace
import XCTest

// Drives a real spec (seam-swept, so a shrunk counterexample exists) and asserts the visual report
// leads with that counterexample. Uses the DSL rather than a hand-built verdict because SpecVerdict's
// counterexample is only produced by an actual failing run.

@Haruspec
protocol Till: AnyObject {
    func addItem(priceCents: Int, qty: Int)
    func applyPromo()
    func checkout() -> Int
}

/// Baseline: rounded 10% discount at checkout.
final class GoodTill: Till {
    private let center: NotificationCenter
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter) {
        self.center = center
    }

    func addItem(priceCents: Int, qty: Int) {
        subtotal += priceCents * qty
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }

    func applyPromo() {
        promo = true
    }

    func checkout() -> Int {
        let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0
        let total = subtotal - discount
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        return total
    }
}

/// Truncating-discount regression — off-by-one unless the subtotal is a multiple of 10.
final class RoundBugTill: Till {
    private let center: NotificationCenter
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter) {
        self.center = center
    }

    func addItem(priceCents: Int, qty: Int) {
        subtotal += priceCents * qty
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }

    func applyPromo() {
        promo = true
    }

    func checkout() -> Int {
        let discount = promo ? subtotal / 10 : 0 // BUG: truncates
        let total = subtotal - discount
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        return total
    }
}

private func makeGood(_ ctx: SeamContext) -> Till {
    GoodTill(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> Till {
    RoundBugTill(center: ctx.notifications)
}

final class SpecHTMLReportTests: XCTestCase {
    private func till() -> Spec<Till> {
        Spec<Till>("promo-till")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
    }

    private func assertSelfContained(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
        for needle in ["http://", "https://", "src=", "//cdn", "url("] {
            XCTAssertFalse(html.contains(needle), "found \(needle)", file: file, line: line)
        }
        XCTAssertTrue(html.contains("<!doctype html>"), file: file, line: line)
    }

    func testDivergedSpecLeadsWithCounterexample() async {
        let swept = till().vary { Seam("coffeeQty", .int(1 ... 20)) }
        let verdict = await swept.verify(against: makeRoundBug)
        XCTAssertEqual(verdict.verdict, .diverged)

        let html = verdict.htmlReport()
        assertSelfContained(html)
        XCTAssertTrue(html.contains("❌ DIVERGED"))
        // The counterexample hero and its seam value.
        XCTAssertTrue(html.contains("Minimal counterexample"))
        XCTAssertTrue(html.contains("coffeeQty"))
        XCTAssertTrue(html.contains("Orderings explored"))
        XCTAssertTrue(html.contains("seam values"), "the counterexample hero lists the shrunk seam values")
    }

    func testEquivalentSpecRendersCleanPanel() async {
        let verdict = await till().verify(against: makeGood)
        XCTAssertEqual(verdict.verdict, .equivalent)
        let html = verdict.htmlReport()
        assertSelfContained(html)
        XCTAssertTrue(html.contains("✅ EQUIVALENT"))
        XCTAssertTrue(html.contains("matched across everything explored"))
    }
}
