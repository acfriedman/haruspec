import XCTest
import OracleTrace          // the deliberate `Oracle.marker` in the SUT
import OracleMacros         // `@Traced` — the low-intrusion structural-tier capture
import OracleCore
import OracleScenario
import OracleSeams          // `SeamDomain` for property-varied op arguments

// ─────────────────────────────────────────────────────────────────────────────────────────────
// A clean, decoupled system under test. It imports only the featherweight facade (`@Traced` +
// `Oracle.marker`) — never the engine, no test scaffolding (no simulateCost). `@Traced` gives the
// structural tier for free (every call / args / return diffed); the notifications + marker give the
// durable semantic tier. Both are surface the oracle checks against.
// ─────────────────────────────────────────────────────────────────────────────────────────────

protocol PromoCart: AnyObject {
    func addItem(priceCents: Int, qty: Int)
    func applyPromo()
    func checkout() -> Int
}

/// Baseline: discount is computed at checkout from the final subtotal — order-independent.
@Traced("PromoCart")
final class GoodCart: PromoCart {
    private let center: NotificationCenter
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter) { self.center = center }

    func addItem(priceCents: Int, qty: Int) {
        subtotal += priceCents * qty
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }
    func applyPromo() { promo = true }
    func checkout() -> Int {
        let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0
        let total = subtotal - discount
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        Oracle.marker("checkout_completed")   // deliberate: this milestone's position is the contract
        return total
    }
}

/// A behavior-preserving refactor (restructured storage, same observable behavior) → EQUIVALENT.
@Traced("PromoCart")
final class RefactorCart: PromoCart {
    private let center: NotificationCenter
    private var lines: [(price: Int, qty: Int)] = []
    private var promo = false
    init(center: NotificationCenter) { self.center = center }
    private var subtotal: Int { lines.reduce(0) { $0 + $1.price * $1.qty } }

    func addItem(priceCents: Int, qty: Int) {
        lines.append((priceCents, qty))
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }
    func applyPromo() { promo = true }
    func checkout() -> Int {
        let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0
        let total = subtotal - discount
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        Oracle.marker("checkout_completed")
        return total
    }
}

/// An ORDER-DEPENDENT regression: `applyPromo` snapshots the discountable subtotal *at apply time*, so
/// items added after the promo aren't discounted. Identical to baseline on the usual order
/// (add → promo → checkout); wrong when promo runs before an item is added.
@Traced("PromoCart")
final class OrderBugCart: PromoCart {
    private let center: NotificationCenter
    private var subtotal = 0
    private var discountableAtPromo: Int? = nil
    init(center: NotificationCenter) { self.center = center }

    func addItem(priceCents: Int, qty: Int) {
        subtotal += priceCents * qty
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }
    func applyPromo() { discountableAtPromo = subtotal }   // BUG: freezes the base too early
    func checkout() -> Int {
        let discount = discountableAtPromo.map { Int((Double($0) * 0.10).rounded()) } ?? 0
        let total = subtotal - discount
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        Oracle.marker("checkout_completed")
        return total
    }
}

/// A VALUE-DEPENDENT regression: integer-truncation discount (`subtotal / 10`) instead of rounded 10%.
/// Identical to baseline when the subtotal is a multiple of 10; off-by-one otherwise.
@Traced("PromoCart")
final class RoundBugCart: PromoCart {
    private let center: NotificationCenter
    private var subtotal = 0
    private var promo = false
    init(center: NotificationCenter) { self.center = center }

    func addItem(priceCents: Int, qty: Int) {
        subtotal += priceCents * qty
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }
    func applyPromo() { promo = true }
    func checkout() -> Int {
        let discount = promo ? subtotal / 10 : 0   // BUG: truncates instead of rounding 10%
        let total = subtotal - discount
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": total])
        Oracle.marker("checkout_completed")
        return total
    }
}

// System factories, typed to the protocol so the differential harness sees one system type across the
// baseline and each candidate. (An inline `{ GoodCart(...) }` returns a concrete type upcast to the
// protocol `S`, which defeats closure-parameter inference — a typed factory is the clean idiom.)
private func makeGood(_ ctx: SeamContext) -> PromoCart { GoodCart(center: ctx.notifications) }
private func makeRefactor(_ ctx: SeamContext) -> PromoCart { RefactorCart(center: ctx.notifications) }
private func makeOrderBug(_ ctx: SeamContext) -> PromoCart { OrderBugCart(center: ctx.notifications) }
private func makeRoundBug(_ ctx: SeamContext) -> PromoCart { RoundBugCart(center: ctx.notifications) }

/// A minimal SUT that posts to `NotificationCenter.default` directly — with *no* injected center,
/// exactly like a faithful port of legacy code. `posts: false` models a candidate that never fires.
final class DefaultPinger {
    private let posts: Bool
    init(posts: Bool) { self.posts = posts }
    func ping() {
        guard posts else { return }
        NotificationCenter.default.post(name: .init("Pinged"), object: nil, userInfo: ["n": 1])
    }
}

// A SUT that posts a product notification (`CartChanged`) *and* an analytics side effect
// (`AnalyticsDidTrack`) on every add — modeling legacy code that fires analytics inline.
protocol AnalyticsCart: AnyObject { func addItem() }

final class TrackingCart: AnalyticsCart {
    private let center: NotificationCenter
    init(center: NotificationCenter) { self.center = center }
    func addItem() {
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["delta": 1])
        center.post(name: .init("AnalyticsDidTrack"), object: nil, userInfo: ["event": "item_added"])
    }
}

/// A "faithful" port that drops the analytics post — a real dropped side effect. Identical on
/// `CartChanged`, silent on `AnalyticsDidTrack`.
final class SilentAnalyticsCart: AnalyticsCart {
    private let center: NotificationCenter
    init(center: NotificationCenter) { self.center = center }
    func addItem() {
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["delta": 1])
    }
}

private func makeTracking(_ ctx: SeamContext) -> AnalyticsCart { TrackingCart(center: ctx.notifications) }
private func makeSilent(_ ctx: SeamContext) -> AnalyticsCart { SilentAnalyticsCart(center: ctx.notifications) }

final class ScenarioPrototypeTests: XCTestCase {

    /// The entire authored surface — this is all a developer writes. No recorder, interceptor, or context.
    private func cart() -> Scenario<PromoCart> {
        Scenario<PromoCart>("promo-cart")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10))) }
                Op("promo")     { $0.applyPromo() }
                Op("checkout")  { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
    }

    func testScenarioPrototype() {
        let base = cart()                          // declared order only
        let explored = base.vary { Ordering(max: 50) }   // + call-ordering variation

        print("=== SCENARIO PROTOTYPE ===")

        print("\n── 1. Good vs Refactor · orderings explored → EQUIVALENT ──")
        let refactor = explored.verify(against: makeRefactor)
        print(refactor.report())
        XCTAssertEqual(refactor.verdict, .equivalent)

        print("\n── 2. Good vs OrderBug · declared order only → EQUIVALENT (bug hidden) ──")
        let single = base.verify(against: makeOrderBug)
        print(single.report())
        XCTAssertEqual(single.verdict, .equivalent, "the usual order never triggers the order bug")

        print("\n── 3. Good vs OrderBug · orderings explored → DIVERGED (caught) ──")
        let caught = explored.verify(against: makeOrderBug)
        print(caught.report())
        XCTAssertEqual(caught.verdict, .diverged, "exploring orderings finds the order-dependent regression")
        XCTAssertNotNil(caught.failingOrder)

        print("=== SCENARIO PROTOTYPE END ===")
    }

    /// `.observing(on: .default)` lets a faithful port post to `NotificationCenter.default` exactly
    /// where legacy code does — no injected center. The interceptor must still capture that post.
    func testObservingOnDefaultCapturesUninjectedPost() {
        let scenario = Scenario<DefaultPinger>("default-ping")
            .system { _ in DefaultPinger(posts: true) }
            .operations { Op("ping") { $0.ping() } }
            .observe(notifications: ["Pinged"])
            .observing(on: .default)

        // Baseline posts to `.default`; a silent candidate omits it. The divergence can only appear
        // if the baseline's post to `.default` — reached via no injected center — was observed.
        let verdict = scenario.verify(against: { _ in DefaultPinger(posts: false) })
        XCTAssertEqual(verdict.verdict, .diverged, "a post to NotificationCenter.default is observed under .observing(on:)")
        XCTAssertTrue(verdict.diff.divergences.contains { $0.kind == .missingEvent && $0.label == "Pinged" },
                      "the captured baseline post shows up as missing in the silent candidate")
    }

    func testArgParameterizationCatchesValueBug() {
        let base = cart()                                   // golden coffeeQty = 10 → subtotal 9990 (benign)
        let swept = base.vary { Seam("coffeeQty", .int(1...20)) }

        print("=== ARG PARAMETERIZATION ===")

        print("\n── Good vs RoundBug · fixed qty (10) → EQUIVALENT (bug hidden) ──")
        let fixed = base.verify(against: makeRoundBug)
        print(fixed.report())
        XCTAssertEqual(fixed.verdict, .equivalent, "9990 is a multiple of 10 — truncation == rounding here")

        print("\n── Good vs RoundBug · coffeeQty swept over 1...20 → DIVERGED (caught) ──")
        let caught = swept.verify(against: makeRoundBug)
        print(caught.report())
        XCTAssertEqual(caught.verdict, .diverged, "some quantity makes truncation ≠ rounding")

        print("=== ARG PARAMETERIZATION END ===")
    }

    // The scenario declares *no* `.observe(...)` allowlist, so capture is all-notifications by default.
    private func analyticsCart() -> Scenario<AnalyticsCart> {
        Scenario<AnalyticsCart>("analytics-cart")
            .system(makeTracking)
            .operations { Op("add") { $0.addItem() } }
    }

    /// Capture-all default: a channel the scenario never listed (`AnalyticsDidTrack`) is still watched,
    /// so a candidate that drops it diverges as a `missingEvent` — no `.observe` call, no blind spot.
    func testCaptureAllDefaultSurfacesUnlistedDroppedNotification() {
        let verdict = analyticsCart().verify(against: makeSilent)
        XCTAssertEqual(verdict.verdict, .diverged,
                       "a notification no one allowlisted is captured by default; dropping it must diverge")
        XCTAssertTrue(verdict.diff.divergences.contains { $0.kind == .missingEvent && $0.label == "AnalyticsDidTrack" },
                      "the dropped analytics post shows up as a missing event")
    }

    /// The opt-out denylist removes a named channel from *both* sides at diff time, so once
    /// `AnalyticsDidTrack` is ignored the two carts match again on the remaining behavior.
    func testIgnoredNotificationNamesDropsChannelBackOut() {
        // Via the `.ignore(notifications:)` convenience …
        let viaConvenience = analyticsCart()
            .ignore(notifications: ["AnalyticsDidTrack"])
            .verify(against: makeSilent)
        XCTAssertEqual(viaConvenience.verdict, .equivalent,
                       ".ignore(notifications:) drops the noisy channel from the diff → EQUIVALENT")

        // … and equivalently via the raw tolerance field.
        let viaTolerance = analyticsCart()
            .tolerate(ToleranceSpec(ignoredNotificationNames: ["AnalyticsDidTrack"]))
            .verify(against: makeSilent)
        XCTAssertEqual(viaTolerance.verdict, .equivalent,
                       "ToleranceSpec.ignoredNotificationNames drops the channel identically")
    }
}
