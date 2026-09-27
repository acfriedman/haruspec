import Foundation
import HaruspecCore
import HaruspecTrace

/// A *feature* change, not a refactor: it deliberately extends behavior (a loyalty-points program) and
/// so is *expected* to diverge from the baseline. This is extension mode — the goal isn't parity, it's
/// proving the change is a **safe extension**: its intended new behavior is present, and nothing *else*
/// regressed.
///
/// Two intended additions (declared in `CheckoutSpec.intent`), both on *production seams* — real
/// side effects the app emits, not hand-authored instrumentation:
///  1. `checkout` posts a new notification `LoyaltyPointsEarned`.
///  2. the `CheckoutDidComplete` notification gains a `pointsEarned` field in its userInfo.
///
/// And — as happens in real feature work — one **collateral regression** rides along, undeclared:
///  3. `removeItem` no longer posts `CartDidChange` (a dropped side effect the author didn't intend).
///
/// Pricing is the shared, correct `Pricing` math (unlike `CartServiceBuggy`), so the only value change
/// is the intended `pointsEarned`. The oracle must absorb (1) and (2) as intended while still catching
/// (3) as collateral. The `checkout_completed` marker is payload-free — it just pins the milestone.
public final class CartServiceV3: CartService {
    private let center: NotificationCenter
    private var items: [(sku: String, price: Int, qty: Int)] = []
    private var promoActive = false

    public init(center: NotificationCenter) {
        self.center = center
    }

    public func addItem(sku: String, unitPriceCents: Int, quantity: Int) {
        items.append((sku, unitPriceCents, quantity))
        center.post(name: .cartDidChange, object: self, userInfo: ["itemCount": items.count])
        center.post(name: .analyticsDidTrack, object: self, userInfo: ["event": "add_to_cart", "sku": sku])
    }

    public func removeItem(sku: String) {
        items.removeAll { $0.sku == sku }
        // COLLATERAL REGRESSION (undeclared): dropped CartDidChange while adding the loyalty feature.
    }

    public func applyPromo(_ code: String) -> Bool {
        promoActive = (code == Pricing.promoCode)
        return promoActive
    }

    public func checkout() -> Receipt {
        Haruspec.simulateCost(100)
        let subtotal = items.reduce(0) { $0 + $1.price * $1.qty }
        let discount = Pricing.discount(subtotal: subtotal, promoActive: promoActive)
        let taxable = subtotal - discount
        let tax = Pricing.tax(taxable: taxable)
        let points = subtotal / 100 // FEATURE: 1 loyalty point per dollar of subtotal.
        let receipt = Receipt(
            subtotalCents: subtotal,
            discountCents: discount,
            taxCents: tax,
            totalCents: taxable + tax,
            lineCount: items.count,
            orderID: Pricing.freshOrderID(),
            issuedAt: Pricing.issuedNow()
        )
        // FEATURE: the completion broadcast now carries points earned (a production value change)...
        center.post(
            name: .checkoutDidComplete,
            object: self,
            userInfo: ["totalCents": receipt.totalCents, "pointsEarned": points]
        )
        // FEATURE: ...and a brand-new production side effect announces the reward.
        center.post(name: .loyaltyPointsEarned, object: self, userInfo: ["points": points])
        // Payload-free milestone marker — same as the baseline, so it aligns cleanly.
        Haruspec.marker("checkout_completed")
        return receipt
    }
}
