import Foundation
import HaruspecMacros
import HaruspecSpec
import HaruspecTrace

/// The observable result of a checkout. `orderID` and `issuedAt` come from the cart's injected
/// ``ReceiptIssuer``, so a capture can hold them still.
///
/// `Codable` is all it takes for the forwarder to capture a checkout's return value as a structured
/// payload (via the `Codable → CanonicalValue` bridge), so the diff can report per-field mismatches.
public struct Receipt: Sendable, Equatable, Codable {
    public var subtotalCents: Int
    public var discountCents: Int
    public var taxCents: Int
    public var totalCents: Int
    public var lineCount: Int
    public var orderID: String
    public var issuedAt: String

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

/// Where a receipt's identity comes from: a fresh order ID and the moment it was issued. Both are
/// values a checkout makes up, so they are injected rather than read from the world.
///
/// A cart that minted its own UUID and read the wall clock would hold two uncontrolled seams: no two
/// runs could agree on a receipt, and a comparison of two carts would read UNSTABLE.
public struct ReceiptIssuer: Sendable {
    /// Returns the next order ID.
    public var orderID: @Sendable () -> String
    /// Returns the ISO 8601 timestamp of the moment of issue.
    public var issuedAt: @Sendable () -> String

    public init(orderID: @escaping @Sendable () -> String, issuedAt: @escaping @Sendable () -> String) {
        self.orderID = orderID
        self.issuedAt = issuedAt
    }

    /// The production issuer: a fresh UUID and the wall clock.
    public static let live = ReceiptIssuer(
        orderID: { UUID().uuidString },
        issuedAt: { ISO8601DateFormatter().string(from: Date()) }
    )

    /// Returns an issuer that issues the same order ID and timestamp every time.
    ///
    /// - Parameters:
    ///   - orderID: The order ID every receipt carries.
    ///   - issuedAt: The ISO 8601 timestamp every receipt carries.
    /// - Returns: The issuer; two carts built on it issue identical receipts for identical carts.
    public static func fixed(
        orderID: String = "00000000-0000-0000-0000-000000000001",
        issuedAt: String = "2026-01-01T00:00:00Z"
    ) -> ReceiptIssuer {
        ReceiptIssuer(orderID: { orderID }, issuedAt: { issuedAt })
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
}
