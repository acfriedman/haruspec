import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecTrace

/// A plausible-looking but subtly-wrong "refactor". It compiles, reads fine, and would pass a
/// cursory human review — precisely the class of change plausibility alone can't catch.
///
/// Three real regressions are planted, each surfaced by a *different* kind of trace divergence:
///  1. Discount uses integer division (`subtotal / 10`) instead of rounding 10% → off-by-one on the
///     receipt's `discountCents` and `totalCents` (a `valueMismatch`).
///  2. `removeItem` forgets to post `CartDidChange` → a dropped side effect (a `missingEvent`).
///  3. `checkout` recomputes redundantly, blowing its timing budget (a `timingRegression`).
@Traced("CartService")
public final class CartServiceBuggy: CartService {
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
        // BUG #2: forgot to post CartDidChange after mutating the cart.
    }

    public func applyPromo(_ code: String) -> Bool {
        promoActive = (code == Pricing.promoCode)
        return promoActive
    }

    @Timed
    public func checkout() -> Receipt {
        Haruspec.simulateCost(250) // BUG #3: redundant work — over the +50 tick budget.
        let subtotal = items.reduce(0) { $0 + $1.price * $1.qty }
        // BUG #1: integer division truncates instead of rounding 10%.
        let discount = promoActive ? subtotal / 10 : 0
        let taxable = subtotal - discount
        let tax = Pricing.tax(taxable: taxable)
        let receipt = Receipt(subtotalCents: subtotal, discountCents: discount, taxCents: tax,
                              totalCents: taxable + tax, lineCount: items.count,
                              orderID: Pricing.freshOrderID(), issuedAt: Pricing.issuedNow())
        center.post(name: .checkoutDidComplete, object: self, userInfo: ["totalCents": receipt.totalCents])
        // Payload-free milestone marker. The off-by-one total is caught via the CheckoutDidComplete
        // notification (production seam), not the marker — which is exactly the point.
        Haruspec.marker("checkout_completed")
        return receipt
    }
}
