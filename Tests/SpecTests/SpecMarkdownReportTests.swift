import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace
import XCTest

// The PR-comment rendering, asserted over real replay verdicts (the DSL, not hand-built structs —
// counterexamples and coverage gaps only exist on actual runs). One test per verdict shape the CI
// surface can show: diverged tables, equivalent-with-coverage, the intent split, and the two
// abstention flavors (op drift vs seam reach), which must read differently.

/// Posts a declared-new loyalty event *and* carries the truncation regression: with the event
/// intended, one divergence renders in each classification table.
@Traced("PromoCart")
private final class LoyaltyRoundBugCart: PromoCart {
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
        let discount = promo ? subtotal / 10 : 0 // the riding regression: truncates
        let total = subtotal - discount
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        center.post(name: .init("LoyaltyPointsEarned"), object: nil, userInfo: ["points": total / 100])
        Haruspec.marker("checkout_completed")
        return total
    }
}

/// Reads a seam the recording never covered — behaviorally identical, so only coverage can object.
@Traced("PromoCart")
private final class GreedyCart: PromoCart {
    private let center: NotificationCenter
    private let context: SeamContext
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter, context: SeamContext) {
        self.center = center
        self.context = context
    }

    func addItem(priceCents: Int, qty: Int) {
        _ = context.int("surgeFactor", default: 1)
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
        Haruspec.marker("checkout_completed")
        return total
    }
}

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> PromoCart {
    RoundBugCart(center: ctx.notifications)
}

private func makeLoyaltyRoundBug(_ ctx: SeamContext) -> PromoCart {
    LoyaltyRoundBugCart(center: ctx.notifications)
}

private func makeGreedy(_ ctx: SeamContext) -> PromoCart {
    GreedyCart(center: ctx.notifications, context: ctx)
}

final class SpecMarkdownReportTests: XCTestCase {
    private func cart(system: @escaping (SeamContext) -> PromoCart) -> Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.markdown")
            .system(system)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted", "LoyaltyPointsEarned"])
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 10)
            }
    }

    func testDivergedMarkdownRendersTablesAndCounterexample() async {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeRoundBug).verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .diverged)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.hasPrefix("### ❌ DIVERGED — `promo-cart.markdown`"))
        XCTAssertFalse(
            markdown.components(separatedBy: "\n")[0].contains("→"),
            "replay verdicts carry one spec name, not a baseline → candidate arrow"
        )
        XCTAssertTrue(markdown.contains("| Kind | Where | Detail |"), "divergences render as a GFM table")
        XCTAssertTrue(markdown.contains("`valueMismatch`"))
        XCTAssertTrue(markdown.contains("**Counterexample:**"))
        XCTAssertTrue(markdown.contains("coffeeQty="))
        XCTAssertTrue(markdown.contains("**Exposing order**"))
        XCTAssertTrue(markdown.contains("not shrunk"), "replay's failing order is the raw recorded one")
        XCTAssertFalse(
            markdown.lowercased().contains("minimal"),
            "never call a replay ordering minimal — nothing shrank it"
        )
        XCTAssertTrue(markdown.contains("orderings explored: \(verdict.orderingsExplored)"))
    }

    func testEquivalentMarkdownCarriesCoverageAndDomainCredit() async {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeRefactor).verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .equivalent)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.hasPrefix("### ✅ EQUIVALENT"))
        XCTAssertTrue(markdown.contains("matched across everything explored"))
        XCTAssertTrue(markdown.contains("**Coverage:**"))
        XCTAssertTrue(markdown.contains("domain-swept"), "a held replay earns the domain-sweep credit")
    }

    func testIntentSplitRendersIntendedAndCollateralSeparately() async {
        let plan = await cart(system: makeGood).record()
        let declared = Intent(expectedNewEvents: ["LoyaltyPointsEarned"])
        let verdict = await cart(system: makeLoyaltyRoundBug).verify(replaying: plan, declaring: declared)
        XCTAssertEqual(verdict.verdict, .diverged, "the riding regression still gates")
        XCTAssertGreaterThan(verdict.diff.intendedCount, 0)
        XCTAssertGreaterThan(verdict.diff.collateralCount, 0)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.contains("**Collateral — undeclared, gating:**"))
        XCTAssertTrue(markdown.contains("**Intended — declared in the intent spec"))
    }

    func testOpDriftAbstentionNamesTheDrift() async {
        let plan = await cart(system: makeGood).record()
        let drifted = Spec<PromoCart>("promo-cart.markdown")
            .system(makeRefactor)
            .operations {
                Op("addEspresso") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])

        let verdict = await drifted.verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .cannotVerify)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.hasPrefix("### ⚠️ CANNOT-VERIFY"))
        XCTAssertTrue(markdown.contains("`op:addCoffee`"))
        XCTAssertTrue(markdown.contains("no longer declares"), "op drift names the orphaned operation")
        XCTAssertTrue(markdown.contains("re-record the plan"))
        XCTAssertTrue(markdown.contains("**this check does not pass.**"))
    }

    func testSeamReachAbstentionIsDistinct() async {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeGreedy).verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .cannotVerify)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.contains("read seams past the recording"))
        XCTAssertTrue(markdown.contains("`surgeFactor`"))
        XCTAssertFalse(
            markdown.contains("no longer declares"),
            "seam reach is not op drift — the two abstentions must read differently"
        )
        XCTAssertTrue(markdown.contains("**this check does not pass.**"))
    }
}
