@testable import HaruspecCore
import XCTest

/// The two-tier durability model: structural (internal call mechanics, code-symbol-named) vs semantic
/// (observable product behavior — notifications, state, markers — domain-named and rename-stable), and
/// how `structuralComparison` chooses which tier gates the verdict.
final class TwoTierTests: XCTestCase {
    /// Internal call mechanics — the fragile, code-symbol-named tier.
    private func structural(_ seq: Int, _ label: String, _ payload: CanonicalValue? = nil) -> TraceEvent {
        TraceEvent(seq: seq, kind: .call, label: label, subject: 1, payload: payload, tier: .structural)
    }

    /// A durable, observable product side effect (a notification) — semantic tier, carries a real value.
    private func semantic(_ seq: Int, _ label: String, _ payload: CanonicalValue) -> TraceEvent {
        TraceEvent(seq: seq, kind: .notification, label: label, subject: 1, payload: payload, tier: .semantic)
    }

    /// Same behavior, but the method was renamed (structural label changes; the side effect does not).
    private var baseline: Trace {
        Trace(name: "before", events: [
            structural(0, "OrderService.placeOrder", ["items": 2]),
            semantic(1, "order_placed", ["totalCents": 2525])
        ])
    }

    private var renamed: Trace {
        Trace(name: "after", events: [
            structural(0, "CheckoutService.submit", ["items": 2]), // renamed method + type
            semantic(1, "order_placed", ["totalCents": 2525])
        ])
    }

    func testStrictFailsOnRename() {
        let diff = BehavioralDiff.compare(baseline: baseline, candidate: renamed) // .strict default
        XCTAssertFalse(diff.isEquivalent)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .missingEvent })
        XCTAssertTrue(diff.divergences.contains { $0.kind == .unexpectedEvent })
    }

    func testAdvisoryReportsStructuralButDoesNotFail() {
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: renamed,
            tolerances: Tolerance(structuralComparison: .advisory)
        )
        XCTAssertTrue(diff.isEquivalent, "the semantic tier matches, so the verdict passes")
        XCTAssertFalse(diff.divergences.isEmpty, "the structural rename is still reported")
        XCTAssertTrue(diff.divergences.allSatisfy(\.isAdvisory))
    }

    func testIgnoredComparesOnlySemanticTier() {
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: renamed,
            tolerances: Tolerance(structuralComparison: .ignored)
        )
        XCTAssertTrue(diff.isEquivalent)
        XCTAssertTrue(diff.divergences.isEmpty, "structural events are dropped entirely")
    }

    func testSemanticRegressionIsCaughtEvenWhenStructuralIgnored() {
        let semanticRegression = Trace(name: "bad", events: [
            structural(0, "CheckoutService.submit", ["items": 2]),
            semantic(1, "order_placed", ["totalCents": 9999]) // product-level regression
        ])
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: semanticRegression,
            tolerances: Tolerance(structuralComparison: .ignored)
        )
        XCTAssertFalse(diff.isEquivalent)
        XCTAssertEqual(diff.divergences.map(\.kind), [.valueMismatch])
        XCTAssertEqual(diff.divergences[0].label, "order_placed")
        XCTAssertFalse(diff.divergences[0].isAdvisory)
    }
}
