import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// What a run spends and what it covers. The defects these pin: the seam sample used to be the *same*
// 64 vectors for every ordering (a 1-D sweep in a 2-D shape), the ordering sample used to be the
// enumeration's lexicographic prefix (all sharing a long common head), and neither the spent budget nor
// the swept fraction reached the verdict — a spec that covered 2% reported "50 orderings explored".

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

/// The baseline's behavior everywhere except the very top of the declared quantity domain — the shape
/// of bug a uniform sample finds by luck and a boundary-first one finds by construction.
@Traced("PromoCart")
private final class TopOfRangeBugCart: PromoCart {
    private let center: NotificationCenter
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter) {
        self.center = center
    }

    func addItem(priceCents: Int, qty: Int) {
        subtotal += priceCents * qty + (qty == 20 ? 1 : 0)
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

final class ExplorationTests: XCTestCase {
    /// Five ops, four of them repeatable — a space far larger than any cap, so sampling is in play.
    private func wideSpec(budget: Int? = nil, orderingMax: Int = 100) -> Spec<PromoCart> {
        var spec = Spec<PromoCart>("promo-cart.exploration")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("addMug") { $0.addItem(priceCents: 499, qty: 1) }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: orderingMax)
            }
        if let budget {
            spec = spec.vary { Budget(runs: budget) }
        }
        return spec
    }

    // MARK: - Budget

    func testABudgetBoundsTheRunsSpentAcrossBothAxes() throws {
        let exploration = try XCTUnwrap(wideSpec(budget: 40).verify(against: makeRefactor).exploration)

        XCTAssertLessThanOrEqual(exploration.runs, 40)
        XCTAssertGreaterThan(exploration.orderingsExplored, 1, "the budget must still buy ordering breadth")
        XCTAssertGreaterThan(exploration.variantsPerOrdering, 1, "and still buy seam breadth")
    }

    func testAnUndeclaredBudgetKeepsTheDefaultSurface() throws {
        let exploration = try XCTUnwrap(wideSpec(orderingMax: 8).verify(against: makeRefactor).exploration)

        XCTAssertEqual(exploration.orderingsExplored, 8)
        XCTAssertEqual(exploration.variantsPerOrdering, 64, "the historical default, now merely the default")
    }

    func testASmallBudgetShrinksBothAxesRatherThanDrainingOne() {
        // A budget that zeroes an axis isn't a smaller sweep, it's a different one: ordering and seam
        // variation catch different bugs.
        let split = ExplorationBudget.split(orderingCap: 100, variants: 64, budget: 12)

        XCTAssertGreaterThan(split.orderings, 1)
        XCTAssertGreaterThan(split.variants, 1)
        XCTAssertLessThanOrEqual(split.orderings * split.variants, 12)
    }

    func testABudgetLargerThanTheDeclaredShapeBuysSeamBreadth() {
        // The ordering axis is capped by what the author declared, so the surplus can only widen seams.
        let split = ExplorationBudget.split(orderingCap: 10, variants: 64, budget: 2000)

        XCTAssertEqual(split.orderings, 10)
        XCTAssertEqual(split.variants, 200)
    }

    func testABudgetWithNoSeamAxisBuysOnlyOrderings() {
        let split = ExplorationBudget.split(orderingCap: 100, variants: 1, budget: 30)

        XCTAssertEqual(split.orderings, 30)
        XCTAssertEqual(split.variants, 1)
    }

    func testABudgetIsSpentAgainstTheOrderingsThatExistNotTheDeclaredCap() throws {
        // Two free ops and a pinned `checkout` → exactly 2 orderings. Resolving the budget against
        // `Ordering(max: 100)` instead would spend a 200-run budget on 22 runs.
        let spec = Spec<PromoCart>("promo-cart.narrow")
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
                Ordering(max: 100, repeating: 1)
                Budget(runs: 200)
            }

        let exploration = try XCTUnwrap(spec.verify(against: makeRefactor).exploration)

        XCTAssertEqual(exploration.orderingsExplored, 2)
        XCTAssertEqual(exploration.runs, 200)
    }

    // MARK: - Boundary-first generation, end to end

    func testATinyBudgetStillCatchesABugThatOnlyBitesAtTheEdgeOfADomain() {
        // Four runs over `.int(1 ... 20)`. Uniform sampling would hit 20 about a fifth of the time;
        // boundary-first reaches it on the second variant, by construction.
        let spec = Spec<PromoCart>("promo-cart.edge")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Budget(runs: 4)
            }

        let verdict = spec.verify(against: { context in TopOfRangeBugCart(center: context.notifications) })

        XCTAssertEqual(verdict.verdict, .diverged)
        XCTAssertEqual(
            verdict.counterexampleSeamPairs.first(where: { $0.key == "coffeeQty" })?.value,
            "20",
            "the counterexample must be the edge, reached deterministically\n\(verdict.report())"
        )
    }

    // MARK: - Independent samples

    func testEachOrderingGetsItsOwnSeamSample() {
        // The defect this pins: one fixed seed per *run* meant every ordering replayed an identical
        // cassette list, so O × V runs explored V distinct inputs.
        let spec = wideSpec(orderingMax: 4)
        let recording = Cassette()
        _ = spec.capture(make: makeGood, order: spec.explorationOrder(), cassette: recording)
        let plan = spec.explorationPlan(golden: recording.snapshot())

        XCTAssertGreaterThan(plan.orderings.count, 1)
        XCTAssertNotEqual(
            plan.cassettes(forOrdering: 0),
            plan.cassettes(forOrdering: 1),
            "two orderings sweeping the identical seam vectors is a 1-D sweep wearing a 2-D shape"
        )
    }

    func testTheSameOrderingIndexIsReproducible() {
        let spec = wideSpec(orderingMax: 4)
        let recording = Cassette()
        _ = spec.capture(make: makeGood, order: spec.explorationOrder(), cassette: recording)
        let plan = spec.explorationPlan(golden: recording.snapshot())

        XCTAssertEqual(plan.cassettes(forOrdering: 2), plan.cassettes(forOrdering: 2))
    }

    // MARK: - Ordering sampling

    func testASmallSpaceIsStillEnumeratedExhaustively() {
        let ops = [Op<PromoCart>("a") { _ in }, Op<PromoCart>("b") { _ in }, Op<PromoCart>("c") { _ in }]
        let all = linearExtensions(ops, max: 100, repeating: 1)

        XCTAssertEqual(all.count, 6, "3! — nothing sampled when everything fits")
        XCTAssertEqual(Set(all.map { $0.map(\.label).joined() }).count, 6)
    }

    func testATruncatedSampleIsNotTheEnumerationPrefix() {
        let ops = [
            Op<PromoCart>("a") { _ in },
            Op<PromoCart>("b") { _ in },
            Op<PromoCart>("c") { _ in },
            Op<PromoCart>("d") { _ in },
            Op<PromoCart>("e") { _ in }
        ]
        let sample = linearExtensions(ops, max: 12, repeating: 1)

        XCTAssertEqual(sample.count, 12)
        XCTAssertEqual(Set(sample.map { $0.map(\.label).joined() }).count, 12, "distinct orderings")
        // Depth-first truncation returned 12 orderings that all began with the same op.
        XCTAssertGreaterThan(
            Set(sample.compactMap(\.first?.label)).count,
            1,
            "a sample whose every member shares a first op is the enumeration's prefix, not a sample"
        )
    }

    func testTheSampleIsUniformOverOrderingsNotOverNextOpChoices() {
        // `{a, a, b, b}` — 6 orderings. Picking evenly among available ops gives `aabb` 25% and the
        // interleavings 12.5% apiece, because spending both `a`s forces the tail and collapses that
        // branch to one ordering. Weighting each choice by the orderings beneath it evens that out.
        let ops = [Op<PromoCart>("a") { _ in }, Op<PromoCart>("b") { _ in }]
        var tally: [String: Int] = [:]
        for seed in 0 ..< 4000 {
            for ordering in linearExtensions(ops, max: 1, repeating: 2, seed: UInt64(seed)) {
                tally[ordering.map(\.label).joined(), default: 0] += 1
            }
        }

        XCTAssertEqual(tally.count, 6, "every ordering must remain reachable")
        let expected = Double(tally.values.reduce(0, +)) / 6
        for (ordering, count) in tally {
            XCTAssertLessThan(
                abs(Double(count) - expected) / expected,
                0.15,
                "\(ordering) drew \(count) of an expected \(Int(expected)) — the walk is weighting "
                    + "branches rather than orderings"
            )
        }
    }

    func testAnUncountableStateSpaceFallsBackToAnEvenPickRatherThanRefusing() {
        // A biased sample still beats no sample. `stateLimit: 1` forces the unweighted path.
        let ops = ["a", "b", "c"].map { label in Op<PromoCart>(label) { _ in } }
        var counter = ExtensionCounter(ops, stateLimit: 1)
        var rng = SplitMix64(seed: 1)

        let picks = (0 ..< 50).map { _ in counter.choose(from: ["a", "b", "c"], using: &rng) }

        XCTAssertTrue(picks.allSatisfy { (0 ..< 3).contains($0) })
        XCTAssertGreaterThan(Set(picks).count, 1, "the fallback still has to be a sample")
    }

    // MARK: - Counting the denominator

    func testTheDenominatorIsExactWellPastWhatTheWalkCouldCount() {
        // Eight ops applied up to twice: hundreds of millions of orderings over a few thousand
        // reachable states. Walking them stops at the limit and reports a bound; counting is instant.
        let spec = Spec<PromoCart>("promo-cart.wide")
            .system(makeGood)
            .operations {
                Op("a") { $0.addItem(priceCents: 1, qty: 1) }
                Op("b") { $0.addItem(priceCents: 2, qty: 1) }
                Op("c") { $0.addItem(priceCents: 3, qty: 1) }
                Op("d") { $0.addItem(priceCents: 4, qty: 1) }
                Op("e") { $0.addItem(priceCents: 5, qty: 1) }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary { Ordering(max: 4, repeating: 2) }

        let available = spec.availableOrderings()

        XCTAssertTrue(available.exact, "an exactly countable space must not report a lower bound")
        XCTAssertGreaterThan(available.count, SpecDefaults.orderingCountLimit)
        // 12 interchangeable-in-pairs ops ahead of a pinned `checkout`: 12! / 2^6, independently.
        XCTAssertEqual(available.count, 7_484_400)
    }

    func testCountingIsExactForASmallSpace() {
        let ops = [Op<PromoCart>("a") { _ in }, Op<PromoCart>("b") { _ in }, Op<PromoCart>("c") { _ in }]
        let counted = countLinearExtensions(ops, repeating: 1, limit: 100_000)

        XCTAssertEqual(counted.count, 6)
        XCTAssertTrue(counted.exact)
    }

    func testCountingStopsAtTheLimitAndSaysSo() {
        let ops = (0 ..< 8).map { index in Op<PromoCart>("op\(index)") { _ in } }
        let counted = countLinearExtensions(ops, repeating: 2, limit: 500)

        XCTAssertEqual(counted.count, 500)
        XCTAssertFalse(counted.exact, "a capped count is a lower bound and must not read as the truth")
    }

    // MARK: - Reporting

    func testTheVerdictSaysWhatFractionItSwept() throws {
        let verdict = wideSpec(orderingMax: 6).verify(against: makeRefactor)
        let exploration = try XCTUnwrap(verdict.exploration)

        XCTAssertFalse(exploration.isExhaustive)
        XCTAssertGreaterThan(exploration.orderingsAvailable, exploration.orderingsExplored)
        XCTAssertTrue(verdict.report().contains("\(exploration.runs) runs"), verdict.report())
        XCTAssertTrue(
            verdict.report().contains("of \(exploration.orderingsAvailable) orderings"),
            "a run that swept a fraction must print the denominator\n\(verdict.report())"
        )
    }

    func testAnExhaustiveRunSaysAllRatherThanAFraction() throws {
        let spec = Spec<PromoCart>("promo-cart.exhaustive")
            .system(makeGood)
            .operations {
                Op("addCoffee") { $0.addItem(priceCents: 999, qty: 2) }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .vary { Ordering(max: 100, repeating: 1) }

        let verdict = spec.verify(against: makeRefactor)
        let exploration = try XCTUnwrap(verdict.exploration)

        XCTAssertTrue(exploration.isExhaustive)
        XCTAssertTrue(verdict.report().contains("all 2 orderings"), verdict.report())
    }

    func testAVerdictArtifactWithoutAnExplorationStillDecodes() throws {
        // Artifacts written before the budget existed carry no such field.
        let verdict = wideSpec(orderingMax: 2).verify(against: makeRefactor)
        var json = try JSONSerialization.jsonObject(with: verdict.jsonData()) as? [String: Any] ?? [:]
        json.removeValue(forKey: "exploration")

        let reloaded = try SpecVerdict(jsonData: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(reloaded.exploration)
        XCTAssertEqual(reloaded.orderingsExplored, verdict.orderingsExplored)
        XCTAssertTrue(reloaded.report().contains("orderings"), reloaded.report())
    }
}
