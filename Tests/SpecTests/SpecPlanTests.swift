import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace
import XCTest

// The Continuous (PR) shape, end to end: record a golden plan from the "base build" (the good cart),
// serialize it, replay it into a "changed build" (the same spec source over a different factory —
// exactly what checking out a branch does to `makeSystem`), and prove the four verdict behaviors:
// EQUIVALENT on a faithful change, DIVERGED (localized, reproducible) on a regression, intent-declared
// deltas absorbed with collateral still gating, and CANNOT-VERIFY when the plan's inputs can't be
// faithfully replayed (op drift / seam reach past the recording).

/// A candidate that posts an *extra*, declared notification — the intended feature delta for the
/// extension-mode panel — while otherwise matching `GoodCart`.
private final class LoyaltyCart: PromoCart {
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
        center.post(name: .init("LoyaltyPointsEarned"), object: nil, userInfo: ["points": total / 100])
        Haruspec.marker("checkout_completed")
        return total
    }
}

/// A candidate that reads a seam the base build never recorded — replay must fall back to live and the
/// verdict must abstain rather than trust the (coincidentally identical) trace.
private final class GreedySeamCart: PromoCart {
    private let center: NotificationCenter
    private let context: SeamContext
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter, context: SeamContext) {
        self.center = center
        self.context = context
    }

    func addItem(priceCents: Int, qty: Int) {
        // An un-recorded read; the default makes the behavior identical, so only coverage can object.
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

private func makeLoyalty(_ ctx: SeamContext) -> PromoCart {
    LoyaltyCart(center: ctx.notifications)
}

private func makeGreedy(_ ctx: SeamContext) -> PromoCart {
    GreedySeamCart(center: ctx.notifications, context: ctx)
}

final class SpecPlanTests: XCTestCase {
    /// The authored spec — identical source on the "base" and "branch" side, as it would be in git.
    /// Only the factory differs per test, standing in for what a checkout does to the code under it.
    private func cart(system: @escaping (SeamContext) -> PromoCart) -> BaselinedSpec<PromoCart> {
        Spec<PromoCart>("promo-cart.plan")
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
            .baselined(on: system)
    }

    private func planURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    // MARK: Record → artifact

    func testRecordPinsTheExploredSurfaceAndRoundTrips() async throws {
        let plan = await cart(system: makeGood).record()

        XCTAssertEqual(plan.specName, "promo-cart.plan")
        XCTAssertGreaterThan(plan.probes.count, 1, "orderings × variants explored, not just the declared run")
        XCTAssertEqual(
            plan.probes.first?.ordering,
            ["addCoffee", "promo", "checkout"],
            "the representative probe is the declared order under the golden cassette"
        )
        XCTAssertEqual(plan.variedSeams, ["coffeeQty"])
        XCTAssertFalse(plan.probes.contains { $0.golden.events.isEmpty }, "every probe pins a real trace")

        // The artifact round-trips bit-identically — the reviewer replays *this file*.
        let url = planURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }
        let written = await try cart(system: makeGood).record(to: url)
        let reloaded = try SpecPlan(contentsOf: url)
        XCTAssertEqual(reloaded, written)
    }

    func testRecordIsDeterministic() async {
        // Two records of the same base build produce the same plan — the cross-build analog of
        // `testCaptureIsDeterministicUnderTolerances`, and what makes committed-golden viable.
        let first = await cart(system: makeGood).record()
        let second = await cart(system: makeGood).record()
        XCTAssertEqual(first, second)
    }

    // MARK: Replay verdicts

    func testFaithfulChangeVerifiesEquivalentFromThePlan() async {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeRefactor).verify(replaying: plan)

        XCTAssertEqual(
            verdict.verdict,
            .equivalent,
            "a behavior-preserving change replays EQUIVALENT against the stored goldens"
        )
        XCTAssertTrue(verdict.coverage.trustsEquivalent, "no gaps: every op and seam replayed cleanly")
        XCTAssertEqual(
            verdict.coverage.domainExercised,
            ["coffeeQty"],
            "the recorded sweep earns domain-coverage credit on a held verify"
        )
        XCTAssertGreaterThan(verdict.orderingsExplored, 1)
    }

    func testRegressionDivergesLocalizedAndReproducible() async throws {
        let url = planURL("regression")
        defer { try? FileManager.default.removeItem(at: url) }
        try await cart(system: makeGood).record(to: url)

        // "On the branch": same spec source, changed code under it.
        let verdict = await try cart(system: makeRoundBug).verify(replayingContentsOf: url)

        XCTAssertEqual(verdict.verdict, .diverged, "the truncation bug is caught across the build boundary")
        XCTAssertNotNil(verdict.counterexample, "the varied seam value that exposed it is pinned")
        XCTAssertTrue(
            verdict.diff.divergences.contains { $0.kind == .valueMismatch },
            "localized to the value that changed, not just 'something differs'"
        )

        // The verdict is itself a serializable artifact (result.json)…
        let resultURL = planURL("result")
        defer { try? FileManager.default.removeItem(at: resultURL) }
        try JSONEncoder().encode(verdict).write(to: resultURL)
        let reloaded = try JSONDecoder().decode(SpecVerdict.self, from: Data(contentsOf: resultURL))
        XCTAssertEqual(reloaded.verdict, .diverged)
        XCTAssertEqual(reloaded.diff.divergences, verdict.diff.divergences)

        // …and the reviewer reproduces the exact verdict by re-running the plan.
        let rerun = await try cart(system: makeRoundBug).verify(replayingContentsOf: url)
        XCTAssertEqual(rerun.verdict, verdict.verdict)
        XCTAssertEqual(rerun.diff.divergences, verdict.diff.divergences)
        XCTAssertEqual(rerun.counterexample, verdict.counterexample)
    }

    // MARK: Extension mode on the PR shape

    func testIntentAbsorbsDeclaredDeltaAndGatesOnCollateral() async {
        let plan = await cart(system: makeGood).record()

        // Undeclared: the new LoyaltyPointsEarned post is collateral → gates.
        let parity = await cart(system: makeLoyalty).verify(replaying: plan)
        XCTAssertEqual(parity.verdict, .diverged, "parity mode gates on any divergence")

        // Declared: the same delta under an intent spec is absorbed…
        let declared = Intent(expectedNewEvents: ["LoyaltyPointsEarned"])
        let extended = await cart(system: makeLoyalty).verify(replaying: plan, declaring: declared)
        XCTAssertEqual(extended.verdict, .equivalent, "the declared feature delta doesn't gate")
        XCTAssertGreaterThan(extended.diff.intendedCount, 0, "…but is still reported, labeled intended")

        // …while an *undeclared* regression riding along still gates.
        let riding = await cart(system: makeRoundBug).verify(replaying: plan, declaring: declared)
        XCTAssertEqual(riding.verdict, .diverged, "intent never excuses collateral")
    }

    // MARK: Soundness across the build boundary

    func testOpDriftAbstainsRatherThanSkipping() async {
        let plan = await cart(system: makeGood).record()

        // The branch renamed an op: its recorded probes are unreplayable input, not skippable noise.
        let drifted = Spec<PromoCart>("promo-cart.plan")
            .operations {
                Op("addEspresso") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .baselined(on: makeRefactor)

        let verdict = await drifted.verify(replaying: plan)
        XCTAssertEqual(
            verdict.verdict,
            .cannotVerify,
            "an op the current build can't replay downgrades the verdict — never a silent pass"
        )
        XCTAssertTrue(verdict.coverage.gaps.contains { $0.boundary == "op:addCoffee" && $0.reason == .unrecorded })
    }

    func testSeamReachPastTheRecordingAbstains() async {
        let plan = await cart(system: makeGood).record()

        // Behaviorally identical (the live fallback default changes nothing observable) — the trace
        // alone would pass. Reaching past the recording is what downgrades it.
        let verdict = await cart(system: makeGreedy).verify(replaying: plan)
        XCTAssertEqual(
            verdict.verdict,
            .cannotVerify,
            "an unrecorded seam read means isolation broke; EQUIVALENT can't be trusted"
        )
        XCTAssertTrue(verdict.coverage.unrecordedReach.contains { $0.boundary == "surgeFactor" })
    }

    // MARK: Scope selection

    func testCoverageIndexScopesPlansToChangedClasses() async {
        let plan = await cart(system: makeGood).record()

        XCTAssertTrue(
            plan.coveredClasses.contains("PromoCart"),
            "the structural tier names the classes the spec exercises"
        )
        XCTAssertTrue(plan.covers(anyOf: ["PromoCart", "Unrelated"]))
        XCTAssertFalse(
            plan.covers(anyOf: ["PaymentService"]),
            "a PR touching only unrelated classes deselects this plan"
        )

        // The --scope filter is exactly this predicate over a plan catalog.
        let catalog = [plan]
        XCTAssertEqual(catalog.filter { $0.covers(anyOf: ["PromoCart"]) }.count, 1)
        XCTAssertTrue(catalog.filter { $0.covers(anyOf: ["PaymentService"]) }.isEmpty)
    }
}
