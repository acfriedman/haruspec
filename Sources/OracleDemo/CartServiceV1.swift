import Foundation
import OracleCore
import OracleTrace
import OracleMacros

/// Baseline implementation — the "golden" behavior every change is verified against.
///
/// Look how little the oracle intrudes: `@Traced` instruments every method (call/args/return) with no
/// per-method code, `NotificationInterceptor` captures the posted notifications, and the only explicit
/// hook is `Oracle.interval`, which marks the region a timing budget applies to. The class holds no
/// recorder; capture is ambient.
@Traced("CartService")
public final class CartServiceV1: CartService {
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
        center.post(name: .cartDidChange, object: self, userInfo: ["itemCount": items.count])
    }

    public func applyPromo(_ code: String) -> Bool {
        promoActive = (code == Pricing.promoCode)
        return promoActive
    }

    @Timed
    public func checkout() -> Receipt {
        Oracle.simulateCost(100) // representative recompute cost; @Timed measures the whole method
        let subtotal = items.reduce(0) { $0 + $1.price * $1.qty }
        let discount = Pricing.discount(subtotal: subtotal, promoActive: promoActive)
        let taxable = subtotal - discount
        let tax = Pricing.tax(taxable: taxable)
        let receipt = Receipt(subtotalCents: subtotal, discountCents: discount, taxCents: tax,
                              totalCents: taxable + tax, lineCount: items.count,
                              orderID: Pricing.freshOrderID(), issuedAt: Pricing.issuedNow())
        center.post(name: .checkoutDidComplete, object: self, userInfo: ["totalCents": receipt.totalCents])
        // A payload-free temporal marker: the durable product milestone. Its *values* ride the
        // CheckoutDidComplete notification above (production-observable), not the marker.
        Oracle.marker("checkout_completed")
        return receipt
    }
}
