import XCTest
import HaruspecTrace
import HaruspecMacros
import HaruspecCore
import HaruspecScenario
import HaruspecSeams

// Repro of the example-xcode-migration failure: a @TracedForwarder baseline over a legacy class,
// diffed against a behaviorally-identical @Traced port, driven by the same ops + .observing(on: .default).
// If the faithful port DIVERGES here, the bug is in the Haruspec mechanism (forwarder / capture), not the app.

// NSObject models with IUO-imported-style signatures — to exercise the same `objcObject` (KVC)
// structural-canonicalization path the app's Obj-C `Product`/`Receipt` hit.
final class ReproProduct: NSObject {
    @objc var sku: String = ""
    @objc var price: Int = 0
    init(sku: String, price: Int) { self.sku = sku; self.price = price }
}
final class ReproReceipt: NSObject {
    @objc var subtotal: Int = 0
    @objc var discount: Int = 0
    @objc var total: Int = 0
    @objc var orderID: String = ""
}

/// Plain-Swift stand-in for the Obj-C CartManager: posts to `.default`, object arg + object return.
final class ReproLegacyManager {
    private var lines: [String: (price: Int, qty: Int)] = [:]
    private var order: [String] = []
    private var promo = false

    func add(_ product: ReproProduct!, quantity: Int) {
        guard quantity > 0 else { return }
        let sku = product.sku
        if var l = lines[sku] { l.qty += quantity; lines[sku] = l }
        else { order.append(sku); lines[sku] = (product.price, quantity) }
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
    }
    func removeSku(_ sku: String!) {
        guard lines[sku] != nil else { return }
        lines[sku] = nil; order.removeAll { $0 == sku }
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
    }
    func applyPromo(_ code: String!) -> Bool {
        guard code == "SAVE10" else { return false }
        promo = true
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
        return true
    }
    func checkout() -> ReproReceipt! {
        let subtotal = order.reduce(0) { $0 + lines[$1]!.price * lines[$1]!.qty }
        let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0
        let total = subtotal - discount
        let r = ReproReceipt(); r.subtotal = subtotal; r.discount = discount; r.total = total; r.orderID = UUID().uuidString
        NotificationCenter.default.post(name: .init("CheckoutDidComplete"), object: self, userInfo: ["total": total])
        order.removeAll(); lines.removeAll(); promo = false
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
        return r
    }
}

@TracedForwarder(wrapping: ReproLegacyManager.self, label: "Cart")
protocol ReproCart: AnyObject {
    func add(_ product: ReproProduct!, quantity: Int)
    func removeSku(_ sku: String!)
    func applyPromo(_ code: String!) -> Bool
    func checkout() -> ReproReceipt!
}

/// Faithful port — identical behavior, posting to `.default` directly.
@Traced("Cart")
final class ReproSwiftPort: ReproCart {
    private var lines: [String: (price: Int, qty: Int)] = [:]
    private var order: [String] = []
    private var promo = false

    func add(_ product: ReproProduct!, quantity: Int) {
        guard quantity > 0 else { return }
        let sku = product.sku
        if var l = lines[sku] { l.qty += quantity; lines[sku] = l }
        else { order.append(sku); lines[sku] = (product.price, quantity) }
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
    }
    func removeSku(_ sku: String!) {
        guard lines[sku] != nil else { return }
        lines[sku] = nil; order.removeAll { $0 == sku }
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
    }
    func applyPromo(_ code: String!) -> Bool {
        guard code == "SAVE10" else { return false }
        promo = true
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
        return true
    }
    func checkout() -> ReproReceipt! {
        let subtotal = order.reduce(0) { $0 + lines[$1]!.price * lines[$1]!.qty }
        let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0
        let total = subtotal - discount
        let r = ReproReceipt(); r.subtotal = subtotal; r.discount = discount; r.total = total; r.orderID = UUID().uuidString
        NotificationCenter.default.post(name: .init("CheckoutDidComplete"), object: self, userInfo: ["total": total])
        order.removeAll(); lines.removeAll(); promo = false
        NotificationCenter.default.post(name: .init("CartDidChange"), object: self)
        return r
    }
}

final class ForwarderReproTests: XCTestCase {
    func testForwarderBaselineVsFaithfulPortIsEquivalent() {
        let scenario = Scenario<ReproCart>("cart.repro")
            .system { _ in TracedReproCart() }
            .operations {
                Op("addCoffee") { sut, seams in sut.add(ReproProduct(sku: "COFFEE", price: 1299), quantity: Int(seams.int("coffeeQty", default: 2))) }
                Op("addMug")    { sut, seams in sut.add(ReproProduct(sku: "MUG", price: 899), quantity: Int(seams.int("mugQty", default: 1))) }
                Op("applyPromo") { sut in _ = sut.applyPromo("SAVE10") }
                Op("removeMug")  { sut in sut.removeSku("MUG") }.after("addMug")
                Op("checkout")   { sut in _ = sut.checkout() }.last()
            }
            .observe(notifications: ["CartDidChange", "CheckoutDidComplete"])
            .observing(on: .default)
            .tolerate(ToleranceSpec(volatileFields: ["orderID"], numericEpsilon: 0,
                                    timingBudgets: [:], unorderedGroups: [], ignoredKinds: []))
            .vary {
                Seam("coffeeQty", .int(1...20))
                Seam("mugQty", .int(1...5))
                Ordering(max: 50)
            }

        let verdict = scenario.verify(against: { _ in ReproSwiftPort() })
        print("=== FORWARDER REPRO ===")
        print(verdict.report())
        print("=== FORWARDER REPRO END ===")
        XCTAssertEqual(verdict.verdict, .equivalent, "forwarder baseline and faithful port must be EQUIVALENT")
    }
}
