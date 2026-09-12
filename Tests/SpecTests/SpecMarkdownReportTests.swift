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

    func testAFullyDeclaredChangePassesWithTheDisclosureBanner() async throws {
        let plan = await cart(system: makeGood).record()
        // Declare exactly what the red verdicts offer (accumulating: a red stops at its first
        // divergent probe) until the change is fully declared. A red offers the narrowest line its
        // probe proves (`.to(<value>)`); the next probe proving a different value is the author's cue
        // that the change is not one value, and the line widens to the bare field.
        var lines: [String] = []
        for _ in 0 ..< 8 {
            let declared = try IntentGrammar.intent(parsing: lines.joined(separator: "\n"))
            let verdict = await cart(system: makeLoyaltyRoundBug).verify(replaying: plan, declaring: declared)
            guard verdict.verdict == .equivalent else {
                for suggested in verdict.diff.divergences.filter(\.isGating).compactMap(\.suggestedDeclaration) {
                    let head = suggested.components(separatedBy: ").").first.map { $0 + ")" } ?? suggested
                    if let narrow = lines.firstIndex(where: { $0.hasPrefix(head) }) {
                        lines[narrow] = head
                    } else {
                        lines.append(suggested)
                    }
                }
                continue
            }

            let markdown = verdict.markdownReport()
            XCTAssertTrue(
                markdown.hasPrefix("### ✅ EQUIVALENT · declared intent absorbed"),
                "an extension-mode green must not read as parity: \(markdown.components(separatedBy: "\n")[0])"
            )
            XCTAssertTrue(markdown.contains("diverges as declared"))
            XCTAssertTrue(markdown.contains("**Intended — declared in the intent spec"), "disclosure leads")
            // Per declaration, what it absorbed and where — not only the first probe that absorbed
            // anything, which is often the golden and says nothing about the values.
            XCTAssertTrue(markdown.contains("**Declared changes, as first observed:**"), markdown)
            XCTAssertFalse(verdict.intentObservations.isEmpty)
            for observation in verdict.intentObservations {
                XCTAssertTrue(declared.declarationTexts.contains(observation.declaration), observation.declaration)
                XCTAssertEqual(observation.divergence.classification, .intended)
                XCTAssertTrue(markdown.contains("`\(observation.declaration)`"), observation.declaration)
            }
            return
        }
        XCTFail("the offered declarations never fully covered the change")
    }

    /// A red walks a window past its first failing case and reports the most informative one; the
    /// offer is derived from every failing case, so a value that moves the same way in all of them
    /// is offered as the direction, not pinned to the one value the first case happened to show.
    func testARedReplayReportsTheRichestOfSeveralFailingCasesAndOffersTheirShape() async throws {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeRoundBug).verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .diverged)

        let cases = try XCTUnwrap(verdict.failingCases)
        XCTAssertGreaterThan(cases.probes.count, 1, "the truncation bug fails in many probes")
        XCTAssertLessThanOrEqual(cases.walkedAfterFirst, 64, "the window is bounded")
        let richest = try XCTUnwrap(cases.richest)
        XCTAssertEqual(verdict.counterexample, richest.inputs, "the reported case is the richest")
        XCTAssertEqual(verdict.diff.divergences, richest.divergences)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.contains("failing cases** among the"), markdown)
        // Truncating the discount only ever raises the total: every failing case agrees on the direction.
        XCTAssertTrue(markdown.contains(#"Changes("CheckoutCompleted", field: "total").increases()"#), markdown)
        XCTAssertFalse(markdown.contains(#"field: "total").to("#), "one case's value must not be pinned")
    }

    func testTheRedVerdictOffersItsDeclarations() async throws {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeRoundBug).verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .diverged)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.contains("```haruspec-intent promo-cart.markdown"), markdown)
        // The offered block must parse back through the grammar — the loop is one paste.
        let fenced = try XCTUnwrap(
            markdown.range(of: "```haruspec-intent promo-cart.markdown\n").map { range in
                String(markdown[range.upperBound...].prefix(while: { $0 != "`" }))
            }
        )
        let intent = try IntentGrammar.intent(parsing: fenced)
        XCTAssertFalse(intent.declarationTexts.isEmpty)
    }

    func testAnUnobservedDeclarationLeadsTheReport() async throws {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeRefactor)
            .verify(replaying: plan, declaring: Intent(expectedNewEvents: ["NeverEmitted"]))
        XCTAssertEqual(verdict.verdict, .equivalent, "behavior matched — only the declaration is dead")

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.contains("**⚠️ Declared but not observed — this check does not pass (exit 6).**"))
        XCTAssertTrue(markdown.contains(#"`Emits("NeverEmitted")`"#))
        let banner = try XCTUnwrap(markdown.range(of: "Declared but not observed")?.lowerBound)
        let body = try XCTUnwrap(markdown.range(of: "matched across everything explored")?.lowerBound)
        XCTAssertLessThan(banner, body, "the dead declaration leads, before the green body")
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
