import Foundation
import HaruspecCore
import HaruspecTrace

/// A behavior-preserving refactor of the baseline — this stands in for an agent's transform.
///
/// The internals are genuinely restructured (items in a dictionary keyed by SKU plus an
/// insertion-order list, totals via a reduce), and the concrete type is even renamed. The forwarder
/// records under the stamp's stable label `"CartService"`, so the trace stays comparable across the
/// rename — none of the restructuring is observable, so the oracle should return EQUIVALENT.
public final class CartServiceV2: CartService {
    private let center: NotificationCenter
    private var order: [String] = []
    private var lines: [String: (price: Int, qty: Int)] = [:]
    private var promoActive = false

    public init(center: NotificationCenter) {
        self.center = center
    }

    private var lineCount: Int {
        order.count
    }

    public func addItem(sku: String, unitPriceCents: Int, quantity: Int) {
        if lines[sku] == nil {
            order.append(sku)
        }
        lines[sku] = (unitPriceCents, quantity)
        center.post(name: .cartDidChange, object: self, userInfo: ["itemCount": lineCount])
        center.post(name: .analyticsDidTrack, object: self, userInfo: ["event": "add_to_cart", "sku": sku])
    }

    public func removeItem(sku: String) {
        lines[sku] = nil
        order.removeAll { $0 == sku }
        center.post(name: .cartDidChange, object: self, userInfo: ["itemCount": lineCount])
    }

    public func applyPromo(_ code: String) -> Bool {
        promoActive = (code == Pricing.promoCode)
        return promoActive
    }

    public func checkout() -> Receipt {
        Haruspec.simulateCost(100)
        let subtotal = order.reduce(0) { running, sku in
            let line = lines[sku]!
            return running + line.price * line.qty
        }
        let discount = Pricing.discount(subtotal: subtotal, promoActive: promoActive)
        let taxable = subtotal - discount
        let tax = Pricing.tax(taxable: taxable)
        let receipt = Receipt(
            subtotalCents: subtotal,
            discountCents: discount,
            taxCents: tax,
            totalCents: taxable + tax,
            lineCount: lineCount,
            orderID: Pricing.freshOrderID(),
            issuedAt: Pricing.issuedNow()
        )
        center.post(name: .checkoutDidComplete, object: self, userInfo: ["totalCents": receipt.totalCents])
        // The same payload-free milestone marker as the baseline — pins temporal coupling even though
        // this variant's internals (and type name) are fully restructured.
        Haruspec.marker("checkout_completed")
        return receipt
    }
}
