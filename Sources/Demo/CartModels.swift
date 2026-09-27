import Foundation
import HaruspecMacros
import HaruspecSpec
import HaruspecTrace

/// The observable result of a checkout. `orderID` and `issuedAt` are deliberately non-deterministic
/// (fresh every run) to prove the tolerance model neutralizes real-world volatility.
///
/// `Codable` is all it takes for the forwarder to capture a checkout's return value as a structured
/// payload (via the `Codable → CanonicalValue` bridge), so the diff can report per-field mismatches.
public struct Receipt: Sendable, Equatable, Codable {
    public var subtotalCents: Int
    public var discountCents: Int
    public var taxCents: Int
    public var totalCents: Int
    public var lineCount: Int
    public var orderID: String // volatile: a fresh UUID each run
    public var issuedAt: String // volatile: wall-clock timestamp

    public init(
        subtotalCents: Int,
        discountCents: Int,
        taxCents: Int,
        totalCents: Int,
        lineCount: Int,
        orderID: String,
        issuedAt: String
    ) {
        self.subtotalCents = subtotalCents
        self.discountCents = discountCents
        self.taxCents = taxCents
        self.totalCents = totalCents
        self.lineCount = lineCount
        self.orderID = orderID
        self.issuedAt = issuedAt
    }
}

/// The behavior contract every variant of the cart implements. The spec driver only knows this
/// surface — exactly the position an AI agent is in when it refactors "the module." The stamp's
/// forwarder, `TracedCartService`, records every variant through this one shape, timed so the
/// checkout's timing budget has a duration to compare.
@Haruspec(timed: true)
public protocol CartService: AnyObject {
    func addItem(sku: String, unitPriceCents: Int, quantity: Int)
    func removeItem(sku: String)
    func applyPromo(_ code: String) -> Bool
    func checkout() -> Receipt
}

/// Shared, obviously-correct pricing math so the *baseline* and *good refactor* can't drift by
/// accident — only the intentionally-buggy variant reimplements it wrongly.
enum Pricing {
    static let promoCode = "SAVE10"
    static let taxRate = 0.08

    static func discount(subtotal: Int, promoActive: Bool) -> Int {
        promoActive ? Int((Double(subtotal) * 0.10).rounded()) : 0
    }

    static func tax(taxable: Int) -> Int {
        Int((Double(taxable) * taxRate).rounded())
    }

    static func freshOrderID() -> String {
        UUID().uuidString
    }

    static func issuedNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
