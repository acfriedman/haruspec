@testable import HaruspecCore
@testable import HaruspecDemo
@testable import HaruspecSeams
@testable import HaruspecTrace
import XCTest

/// Property-based differential generation driven against the **real, unmodified** `CartService`
/// implementations, with the cart quantity sourced from a seam — the realistic case where an input
/// arrives from a nondeterministic boundary (user entry / remote config). The Buggy variant's
/// `discount = subtotal / 10` (integer truncation) vs the baseline's rounded 10% is a *value-dependent*
/// off-by-one: benign when the subtotal is a multiple of 10, wrong otherwise. A single recorded cassette
/// whose quantity yields a clean subtotal calls it EQUIVALENT; property gen over the quantity domain
/// finds the value that bites. Prints the reports an LLM / CLI caller would surface.
final class PropertyShowcaseTests: XCTestCase {
    /// Drive a real `CartService`: unit price 999¢, quantity from the `coffeeQty` seam, promo applied.
    /// (No `removeItem`, so the isolated signal is the rounding off-by-one — not the dropped notification
    /// the existing fixed-scenario demo already catches.)
    private func capture(name: String, cassette: Cassette,
                         _ make: (NotificationCenter) -> CartService) -> Trace {
        let recorder = TraceRecorder(name: name, clock: ManualClock())
        let center = NotificationCenter()
        let interceptor = NotificationInterceptor(recorder: recorder, center: center,
                                                  names: checkoutNotificationNames)
        interceptor.start(); defer { interceptor.stop() }
        let service = make(center)
        TraceContext.$current.withValue(recorder) {
            let qty = Int(cassette.int(seam: "coffeeQty", live: { 10 })) // input from a seam boundary
            service.addItem(sku: "COFFEE", unitPriceCents: 999, quantity: qty)
            _ = service.applyPromo("SAVE10")
            _ = service.checkout()
        }
        return recorder.trace()
    }

    /// Fresh order id / timestamp are volatile; the recompute interval gets a generous budget so the
    /// isolated signal is the value-dependent discount, not timing.
    private var tolerances: ToleranceSpec {
        ToleranceSpec(volatileFields: [.key("orderID"), .key("issuedAt")], numericEpsilon: 0,
                      timingBudgets: ["CartService.checkout": 500],
                      unorderedGroups: [["CartDidChange", "AnalyticsDidTrack"]], ignoredKinds: [])
    }

    /// A differential property: baseline = V1, candidate = `makeCandidate`. Golden records coffeeQty = 10
    /// → subtotal 9990 (a multiple of 10), where the truncation bug is benign.
    private func property(candidateName: String,
                          _ makeCandidate: @escaping (NotificationCenter) -> CartService) -> DifferentialProperty {
        let recording = Cassette()
        _ = capture(name: "cartservice.v1", cassette: recording) { CartServiceV1(center: $0) }
        let golden = recording.snapshot()

        return DifferentialProperty(golden: golden, tolerances: tolerances) { cassette, branch in
            branch == .candidate
                ? self.capture(name: candidateName, cassette: cassette, makeCandidate)
                : self.capture(name: "cartservice.v1", cassette: cassette) { CartServiceV1(center: $0) }
        }
    }

    func testPropertyGenerationOnRealCartServices() throws {
        let buggy = property(candidateName: "cartservice.buggy") { CartServiceBuggy(center: $0) }

        print("=== SHOWCASE START ===")

        print("\n── 1. Single recorded path (coffeeQty = 10) · V1 vs Buggy ──")
        let single = buggy.verify(count: 1, varying: [:], seed: 0)
        print(single.report())
        XCTAssertEqual(single.verdict, .equivalent, "benign on the recorded quantity — the bug is hidden")

        print("\n── 2. Property gen over coffeeQty ∈ 1...20 · V1 vs Buggy ──")
        let caught = buggy.check(count: 40, varying: ["coffeeQty": .int(1 ... 20)], seed: 7)
        let counter = try XCTUnwrap(caught.firstFailure)
        print(VerificationResult(diff: counter.diff, coverage: caught.coverage).report())
        let qty = counter.cassette.tracks["coffeeQty"]?.first.flatMap {
            if case let .int(value) = $0 {
                value
            } else {
                nil
            }
        }
        print("  ↳ shrunk counterexample: coffeeQty = \(qty ?? -1)")
        XCTAssertFalse(caught.heldOverSurface, "property gen finds a quantity where truncation ≠ rounding")

        print("\n── 3. Property gen over coffeeQty ∈ 1...20 · V1 vs V2 (behavior-preserving refactor) ──")
        let refactor = property(candidateName: "cartservice.v2") { CartServiceV2(center: $0) }
        let held = refactor.verify(count: 40, varying: ["coffeeQty": .int(1 ... 20)], seed: 7)
        print(held.report())
        XCTAssertEqual(held.verdict, .equivalent, "the refactor holds across the whole quantity domain")
        XCTAssertEqual(held.coverage.domainExercised, ["coffeeQty"])

        print("=== SHOWCASE END ===")
    }
}
