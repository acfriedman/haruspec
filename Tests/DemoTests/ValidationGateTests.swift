import XCTest
@testable import HaruspecCore
@testable import HaruspecTrace
@testable import HaruspecDemo

/// The *validation gate*: capture two traces of one real module and produce a meaningful,
/// deterministic behavioral diff. Each test here is one leg of that proof.
final class ValidationGateTests: XCTestCase {

    /// Determinism, the hard research question: two independent captures of the *same* code differ
    /// only in genuinely volatile fields (a fresh UUID, a wall-clock timestamp). Strict diffing sees
    /// that noise; the tolerance model cancels it. If this fails, the whole thesis wobbles.
    func testCaptureIsDeterministicUnderTolerances() {
        let first = CheckoutScenario.baseline()
        let second = CheckoutScenario.baseline()

        let strict = BehavioralDiff.compare(baseline: first, candidate: second)
        XCTAssertFalse(strict.isEquivalent, "raw traces should differ on the volatile UUID/timestamp")
        XCTAssertTrue(strict.divergences.allSatisfy { $0.kind == .valueMismatch })

        let tolerant = BehavioralDiff.compare(baseline: first, candidate: second,
                                              tolerances: CheckoutScenario.tolerances)
        XCTAssertTrue(tolerant.isEquivalent, "canonicalization + tolerances must make repeat runs equivalent")
    }

    /// A genuine behavior-preserving refactor is *verified*, not merely asserted.
    func testRefactorVerifiesAsEquivalent() {
        let diff = BehavioralDiff.compare(baseline: CheckoutScenario.baseline(),
                                          candidate: CheckoutScenario.refactor(),
                                          tolerances: CheckoutScenario.tolerances)
        XCTAssertTrue(diff.isEquivalent, "refactor changed internals only; observable behavior is identical\n\(diff.report())")
    }

    /// The payoff: a change that compiles and "looks right" but silently breaks behavior is caught,
    /// and each regression is localized to the right kind of divergence.
    func testRegressionIsCaught() {
        let diff = BehavioralDiff.compare(baseline: CheckoutScenario.baseline(),
                                          candidate: CheckoutScenario.regression(),
                                          tolerances: CheckoutScenario.tolerances)
        XCTAssertFalse(diff.isEquivalent)
        let kinds = Set(diff.divergences.map(\.kind))

        // Bug #1: integer-division discount → wrong discount + total.
        XCTAssertTrue(kinds.contains(.valueMismatch))
        let valueLabels = diff.divergences.filter { $0.kind == .valueMismatch }.map(\.detail).joined(separator: "\n")
        XCTAssertTrue(valueLabels.contains("discountCents"), "expected discount mismatch:\n\(valueLabels)")
        XCTAssertTrue(valueLabels.contains("totalCents"), "expected total mismatch:\n\(valueLabels)")

        // Bug #2: dropped CartDidChange notification in removeItem.
        XCTAssertTrue(diff.divergences.contains { $0.kind == .missingEvent && $0.label == "CartDidChange" },
                      "expected a dropped CartDidChange:\n\(diff.report())")

        // Bug #3: checkout over its timing budget (@Timed measures the whole method).
        XCTAssertTrue(diff.divergences.contains { $0.kind == .timingRegression && $0.label == "CartService.checkout" },
                      "expected a timing regression:\n\(diff.report())")
    }

    /// The semantic (observable-behavior) tier is the durable contract: even if every fragile
    /// structural (code-symbol) event is ignored, the *production notifications* still catch the
    /// regression — the dropped `CartDidChange` and the wrong `CheckoutDidComplete` total. Values live
    /// on real production seams, not on hand-authored marker payloads.
    func testDurableTierCatchesRegressionWhenStructuralIgnored() {
        var spec = CheckoutScenario.tolerances
        spec.structuralComparison = .ignored
        let diff = BehavioralDiff.compare(baseline: CheckoutScenario.baseline(),
                                          candidate: CheckoutScenario.regression(),
                                          tolerances: spec)
        XCTAssertFalse(diff.isEquivalent)
        XCTAssertFalse(diff.divergences.contains { $0.label.hasPrefix("CartService.") },
                       "structural call mechanics should be dropped:\n\(diff.report())")
        XCTAssertTrue(diff.divergences.contains { $0.kind == .missingEvent && $0.label == "CartDidChange" },
                      "the dropped notification is caught:\n\(diff.report())")
        XCTAssertTrue(diff.divergences.contains { $0.kind == .valueMismatch && $0.label == "CheckoutDidComplete"
                                                  && $0.detail.contains("totalCents") },
                      "the wrong total is caught via the production notification:\n\(diff.report())")
    }

    /// Traces survive a serialize → reload round-trip unchanged (capture→store→reload).
    func testTraceRoundTripsThroughJSON() throws {
        let original = CheckoutScenario.baseline()
        let reloaded = try Trace(jsonData: original.jsonData())
        XCTAssertEqual(original, reloaded)
    }
}
