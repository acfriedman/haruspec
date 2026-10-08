import Foundation
import HaruspecCore
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// `.after` is a *soft* precondition and `.requires` a hard gate. The defect these pin: ordering clamps
// used to filter the sample, so a spec that declared `remove.after("add")` could never interrogate
// remove-on-an-empty-cart — the exact defensive branch a migration most wants diffed. A differential
// oracle has no expected value an out-of-order call could contradict, so the only thing filtering
// bought was a smaller surface reported at full confidence.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

final class OrderingPreconditionTests: XCTestCase {
    /// A space far past any cap, with nothing declared about ordering — the "unchanged behavior" control.
    private func unconstrainedSpec(orderingMax: Int) -> BaselinedSpec<PromoCart> {
        Spec<PromoCart>("promo-cart.unconstrained")
            .operations {
                Op("addCoffee") { $0.addItem(priceCents: 999, qty: 2) }
                Op("addMug") { $0.addItem(priceCents: 499, qty: 1) }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary { Ordering(max: orderingMax) }
            .baselined(on: makeGood)
    }

    // MARK: - Hard gates vs soft preconditions

    /// Five repeatable ops so the space is far past any cap and sampling — not enumeration — is in play.
    private func gatedOps(hard: Bool) -> [Op<PromoCart>] {
        let remove = Op<PromoCart>("remove") { _ in }
        return [
            Op<PromoCart>("add") { _ in },
            hard ? remove.requires("add") : remove.after("add"),
            Op<PromoCart>("promo") { _ in },
            Op<PromoCart>("audit") { _ in },
            Op<PromoCart>("checkout") { _ in }.last()
        ]
    }

    func testSamplingNeverViolatesAHardGate() {
        for ordering in linearExtensions(gatedOps(hard: true), max: 40, repeating: 2) {
            let labels = ordering.map(\.label)
            XCTAssertEqual(labels.last, "checkout", "`.last()` must stay last in every sample")
            XCTAssertLessThan(
                labels.firstIndex(of: "add") ?? .max,
                labels.firstIndex(of: "remove") ?? .max,
                "`.requires` is the hard gate — a violating ordering would trap the SUT, not inform it"
            )
        }
    }

    func testSamplingSpendsADeliberateSliceOnBreakingSoftPreconditions() {
        let ops = gatedOps(hard: false)
        let declared = preconditions(of: ops)
        let sample = linearExtensions(ops, max: 40, repeating: 2)

        let outOfOrder = sample.filter {
            !violatedPreconditions(in: $0.map(\.label), declaredBy: declared).isEmpty
        }
        XCTAssertEqual(sample.count, 40, "the stratified sample must still spend the whole budget")
        XCTAssertFalse(
            outOfOrder.isEmpty,
            "`.after` is soft: remove-before-add is a defensive path the sweep has to reach"
        )
        XCTAssertLessThan(
            Double(outOfOrder.count) / Double(sample.count),
            0.5,
            "the out-of-order stratum is a deliberate slice, not the bulk of the sweep"
        )
        XCTAssertTrue(
            sample.allSatisfy { $0.map(\.label).last == "checkout" },
            "a soft precondition must not loosen `.last()`"
        )
    }

    func testASpecWithNoPreconditionsSamplesExactlyAsItDidBefore() {
        let ops = [
            Op<PromoCart>("a") { _ in },
            Op<PromoCart>("b") { _ in },
            Op<PromoCart>("c") { _ in },
            Op<PromoCart>("d") { _ in }
        ]
        let sample = linearExtensions(ops, max: 20, repeating: 2, seed: 7)

        XCTAssertEqual(sample.count, 20)
        XCTAssertEqual(Set(sample.map { $0.map(\.label).joined() }).count, 20, "distinct orderings")
    }

    func testViolationsAreNamedByTheOpAndTheLabelItShouldHaveFollowed() {
        let declared = ["remove": ["add"], "checkout": ["add"]]

        XCTAssertEqual(
            violatedPreconditions(in: ["remove", "add", "checkout"], declaredBy: declared),
            ["remove after add"],
            "checkout ran after an add, so only the remove is out of order"
        )
        XCTAssertEqual(violatedPreconditions(in: ["add", "remove"], declaredBy: declared), [])
        XCTAssertEqual(
            violatedPreconditions(in: ["remove", "remove"], declaredBy: declared),
            ["remove after add"],
            "a repeated op reports its broken precondition once"
        )
    }

    func testHardGatesShrinkTheCountedSpaceAndSoftPreconditionsDoNot() {
        let free = countLinearExtensions(
            [Op<PromoCart>("a") { _ in }, Op<PromoCart>("b") { _ in }, Op<PromoCart>("c") { _ in }],
            repeating: 1,
            limit: 100_000
        )
        let gated = countLinearExtensions(
            [
                Op<PromoCart>("a") { _ in },
                Op<PromoCart>("b") { _ in }.requires("a"),
                Op<PromoCart>("c") { _ in }.last()
            ],
            repeating: 1,
            limit: 100_000
        )
        let soft = countLinearExtensions(
            [
                Op<PromoCart>("a") { _ in },
                Op<PromoCart>("b") { _ in }.after("a"),
                Op<PromoCart>("c") { _ in }.last()
            ],
            repeating: 1,
            limit: 100_000
        )

        XCTAssertEqual(free.count, 6)
        XCTAssertEqual(gated.count, 1, "a total order admits exactly one extension")
        XCTAssertEqual(
            soft.count,
            2,
            "`.after` is not part of the denominator — b-before-a is an ordering the sweep may spend on"
        )
    }

    func testTheVerdictSaysHowMuchOfTheSweepWasOutOfOrder() async throws {
        let spec = Spec<PromoCart>("promo-cart.preconditions")
            .operations {
                Op("addCoffee") { $0.addItem(priceCents: 999, qty: 2) }
                Op("addMug") { $0.addItem(priceCents: 499, qty: 1) }
                Op("promo") { $0.applyPromo() }
                Op("audit") { _ in }.after("promo")
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary { Ordering(max: 40) }
            .baselined(on: makeGood)

        let verdict = await spec.verify(candidate: makeRefactor)
        let exploration = try XCTUnwrap(verdict.exploration)
        let outOfOrder = try XCTUnwrap(exploration.outOfOrderExplored)

        XCTAssertGreaterThan(outOfOrder, 0, "the defensive stratum has to reach the verdict to be trusted")
        XCTAssertLessThan(outOfOrder, exploration.orderingsExplored)
        XCTAssertTrue(verdict.report().contains("\(outOfOrder) out-of-order"), verdict.report())
    }

    func testASweepWithNoPreconditionsReportsNoOutOfOrderStratum() async throws {
        let spec = unconstrainedSpec(orderingMax: 6)
        let verdict = await spec.verify(candidate: makeRefactor)
        let exploration = try XCTUnwrap(verdict.exploration)

        XCTAssertEqual(exploration.outOfOrderExplored, 0)
        XCTAssertFalse(exploration.summary.contains("out-of-order"), exploration.summary)
    }

    func testAFailingOrderNamesThePreconditionItBroke() {
        let diff = BehavioralDiff.compare(
            baseline: Trace(name: "base", events: []),
            candidate: Trace(name: "candidate", events: []),
            comparison: .strict
        )
        let verdict = SpecVerdict(
            result: VerificationResult(
                diff: diff,
                coverage: Coverage(declared: [], exercised: [], gaps: [], domainExercised: [])
            ),
            orderingsExplored: 40,
            failingOrder: ["remove", "add"],
            counterexample: nil,
            exploration: Exploration(
                orderingsExplored: 40,
                orderingsAvailable: 40,
                orderingsAreExact: true,
                variantsPerOrdering: 1,
                outOfOrderExplored: 12,
                boundaryEdgesScheduled: 0,
                boundaryEdgesCovered: 0,
                combinedVariantsCovered: 0
            ),
            qualification: Qualification(
                coveredClasses: [],
                operations: 2,
                probes: 40,
                seamPositions: [:],
                blindSpots: nil
            ),
            violatedPreconditions: ["remove after add"]
        )

        XCTAssertTrue(
            verdict.report().contains("out-of-order: breaks remove after add"),
            "a divergence on the defensive stratum must say so — triage differs\n\(verdict.report())"
        )
    }

    func testAnArtifactPredatingTheOutOfOrderStratumIsRefused() async throws {
        // Pre-release stance: no tolerant decoders, no migrations. An artifact from before the
        // sample was stratified fails to decode — the fix is re-recording, not coercion.
        let verdict = await unconstrainedSpec(orderingMax: 2).verify(candidate: makeRefactor)
        var json = try JSONSerialization.jsonObject(with: verdict.jsonData()) as? [String: Any] ?? [:]
        var exploration = json["exploration"] as? [String: Any] ?? [:]
        exploration.removeValue(forKey: "outOfOrderExplored")
        json["exploration"] = exploration

        XCTAssertThrowsError(
            try SpecVerdict(jsonData: JSONSerialization.data(withJSONObject: json))
        )
    }
}
