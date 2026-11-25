import Foundation
@testable import HaruspecSpec
import XCTest

/// How many times each op appears. `Ordering(repeating:)` was one number for every op, which stopped
/// fitting once ops collapsed — one `add` wants applying six times where one `applyPromo` wants two, and
/// raising the global dial buys both.
///
/// Worse, an *exact* count means every sequence runs every op the same number of times, so a state that
/// needs an op to be absent or scarce is unreachable no matter how many orderings are sampled. A range is
/// what reaches it.
final class OpMultiplicityTests: XCTestCase {
    private func labelCounts(_ orderings: [[Op<PromoCart>]], _ label: String) -> Set<Int> {
        Set(orderings.map { $0.filter { $0.label == label }.count })
    }

    // MARK: - Exact

    func testAPerOpCountOverridesTheSpecWideOne() {
        let ops = [
            Op<PromoCart>("a") { _ in }.repeating(3),
            Op<PromoCart>("b") { _ in }
        ]
        let orderings = linearExtensions(ops, max: 50, repeating: 2)

        XCTAssertEqual(labelCounts(orderings, "a"), [3], "the op's own count wins")
        XCTAssertEqual(labelCounts(orderings, "b"), [2], "an op that declares nothing takes the spec's")
        XCTAssertEqual(Set(orderings.map(\.count)), [5], "exact counts mean one sequence length")
    }

    func testOnceIsExactlyOneAndLastImpliesIt() {
        let ops = [
            Op<PromoCart>("a") { _ in },
            Op<PromoCart>("b") { _ in }.once(),
            Op<PromoCart>("c") { _ in }.last()
        ]
        let orderings = linearExtensions(ops, max: 50, repeating: 3)

        XCTAssertEqual(labelCounts(orderings, "b"), [1])
        XCTAssertEqual(labelCounts(orderings, "c"), [1])
        XCTAssertTrue(orderings.allSatisfy { $0.last?.label == "c" })
    }

    // MARK: - Ranged

    func testARangeVariesTheCountBetweenSequences() {
        let ops = [
            Op<PromoCart>("a") { _ in }.repeating(0 ... 2),
            Op<PromoCart>("b") { _ in }.repeating(1)
        ]
        let orderings = linearExtensions(ops, max: 50, repeating: 1)

        XCTAssertEqual(labelCounts(orderings, "a"), [0, 1, 2], "every declared count has to be reachable")
        XCTAssertEqual(labelCounts(orderings, "b"), [1])
    }

    func testARangeIsTheOnlyWayToReachAnOpAbsentState() {
        // Exactly the shape of the cart's unreachable branches: with `add` fixed at N, no sampled
        // ordering can ever check out an empty cart.
        let exact = [
            Op<PromoCart>("add") { _ in },
            Op<PromoCart>("checkout") { _ in }.last()
        ]
        let ranged = [
            Op<PromoCart>("add") { _ in }.repeating(0 ... 2),
            Op<PromoCart>("checkout") { _ in }.last()
        ]

        XCTAssertFalse(
            linearExtensions(exact, max: 50, repeating: 2).contains { !$0.contains { $0.label == "add" } },
            "an exact count has a floor no amount of ordering sampling gets under"
        )
        XCTAssertTrue(
            linearExtensions(ranged, max: 50, repeating: 2).contains { !$0.contains { $0.label == "add" } },
            "checkout on an empty cart is the state the range exists to reach"
        )
    }

    func testASequenceThatWouldRunNothingIsNotExplored() {
        // Every count zero is a run with an empty trace on both branches — it cannot say anything.
        let ops = [
            Op<PromoCart>("a") { _ in }.repeating(0 ... 1),
            Op<PromoCart>("b") { _ in }.repeating(0 ... 1)
        ]
        let orderings = linearExtensions(ops, max: 50, repeating: 1)

        XCTAssertFalse(orderings.contains { $0.isEmpty })
        XCTAssertEqual(orderings.count, 4, "ab, ba, a, b — only the empty shape is dropped")
    }

    // MARK: - The denominator

    func testTheDenominatorSumsEveryShape() {
        let ops = [
            Op<PromoCart>("a") { _ in }.repeating(0 ... 2),
            Op<PromoCart>("b") { _ in }.repeating(0 ... 2)
        ]

        let counted = countLinearExtensions(ops, repeating: 1, limit: 100_000)

        // Shapes (a,b) over 0…2 minus the empty one, each contributing (a+b)!/(a!b!):
        // 1 + 1 + 1 + 2 + 3 + 1 + 3 + 6 = 18.
        XCTAssertEqual(counted.count, 18)
        XCTAssertTrue(counted.exact)
    }

    func testTheSpecReportsTheSummedDenominator() async {
        let spec = Spec<PromoCart>("promo-cart.ranged")
            .operations {
                Op("add") { $0.addItem(priceCents: 999, qty: 2) }.repeating(0 ... 2)
                Op("promo") { $0.applyPromo() }.repeating(0 ... 2)
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary { Ordering(max: 100) }
            .baselined { GoodCart(center: $0.notifications) }

        let available = spec.spec.availableOrderings()

        // Nine shapes here, not eight: `checkout` is pinned at one, so no shape is empty and
        // `[checkout]` alone — a checkout on a cart nothing was ever added to — counts.
        // Σ over (add, promo) in 0…2 of (add + promo)! / (add! promo!) = 19.
        XCTAssertEqual(available.count, 19)
        XCTAssertTrue(available.exact)

        let verdict = await spec.verify { RefactorCart(center: $0.notifications) }
        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }
}
