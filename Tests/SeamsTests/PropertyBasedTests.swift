@testable import HaruspecCore
@testable import HaruspecSeams
@testable import HaruspecTrace
import XCTest

/// Property-based generation at the seam, differential flavor. A single recorded cassette proves
/// equivalence on ONE path; a path-dependent regression the golden input never triggers slips through as
/// EQUIVALENT. Generating many seam-vectors and diffing baseline vs candidate over the surface catches
/// it — the `SeamCoverageTests` money-shot one level deeper: a *value*-dependent miss, not an unrecorded
/// boundary — and a held run *credits domain coverage*, raising the reported surface past a single point.
final class PropertyBasedTests: XCTestCase {
    private static let checkoutCompleted = Notification.Name("CheckoutCompleted")

    /// The gap being closed: on the one recorded path, the regression is invisible.
    func testSingleCassetteMissesThePathDependentRegression() {
        let tape = record(1000) // golden discount = 100 → total 900

        // Baseline vs the clamp on the recorded discount: 100 ≤ 1000, so the clamp never fires → the
        // trace diff is EQUIVALENT. The bug exists but this single input can't see it.
        let base = runCheckout(cassette: Cassette(replaying: tape), subtotal: 1000, total: baseline)
        let cand = runCheckout(cassette: Cassette(replaying: tape), subtotal: 1000, total: clamped)
        XCTAssertTrue(
            BehavioralDiff.compare(baseline: base, candidate: cand).isEquivalent,
            "the recorded discount doesn't trigger the clamp — a false pass at the depth level"
        )
    }

    /// Generating over the discount's domain finds the triggering value; shrinking localizes it.
    func testPropertyGenerationCatchesAndLocalizesTheRegression() throws {
        let tape = record(1000)
        let property = DifferentialProperty(golden: tape) { cassette, branch in
            self.runCheckout(
                cassette: cassette,
                subtotal: 1000,
                total: branch == .candidate ? self.clamped : self.baseline
            )
        }

        let result = property.check(
            count: 64,
            varying: ["discount": .int(0 ... 2000), "noise": .int(0 ... 1000)],
            seed: 42
        )

        XCTAssertFalse(result.heldOverSurface, "some generated discount must trigger the clamp divergence")
        let counter = try XCTUnwrap(result.firstFailure)

        // Reproducible: replaying the counterexample cassette reproduces the divergence deterministically.
        let base = runCheckout(cassette: Cassette(replaying: counter.cassette), subtotal: 1000, total: baseline)
        let cand = runCheckout(cassette: Cassette(replaying: counter.cassette), subtotal: 1000, total: clamped)
        XCTAssertFalse(
            BehavioralDiff.compare(baseline: base, candidate: cand).isEquivalent,
            "the shrunk counterexample reproduces the bug on replay"
        )

        // Localized: discount is a value > 1000 (where max(0,·) changes output)…
        XCTAssertEqual(intTrack(counter.cassette, "discount")?.count, 1)
        XCTAssertGreaterThan(intTrack(counter.cassette, "discount")?.first ?? 0, 1000)
        // …and the irrelevant `noise` seam was shrunk back to its benign golden reading.
        XCTAssertEqual(intTrack(counter.cassette, "noise"), [7], "shrinking localized to discount")

        // A failed run credits no domain coverage — you found a bug, not a cleared surface.
        XCTAssertTrue(result.coverage.domainExercised.isEmpty)
        XCTAssertEqual(property.verify(count: 64, varying: ["discount": .int(0 ... 2000)], seed: 42).verdict, .diverged)
    }

    private func clamped(_ subtotal: Int64, _ discount: Int64) -> Int64 {
        max(0, subtotal - discount)
    } // bites when discount > subtotal

    private func intTrack(_ data: CassetteData, _ seam: String) -> [Int64]? {
        data.tracks[seam]?.compactMap {
            if case let .int(value) = $0 {
                value
            } else {
                nil
            }
        }
    }

    /// The loop closes: a behavior-preserving refactor holds over the domain, so the property run
    /// *credits domain coverage* — raising the reported surface past the single recorded point.
    func testHeldPropertyRunCreditsDomainCoverage() {
        let tape = record(1000)
        let property = DifferentialProperty(golden: tape) { cassette, branch in
            self.runCheckout(
                cassette: cassette,
                subtotal: 1000,
                total: branch == .candidate ? self.refactored : self.baseline
            )
        }

        let verified = property.verify(count: 64, varying: ["discount": .int(0 ... 2000)], seed: 1)

        // The refactor is equivalent over the whole domain → a trustworthy EQUIVALENT…
        XCTAssertEqual(verified.verdict, .equivalent)
        // …with the swept seam credited as domain-exercised (discount), out of the two declared seams.
        XCTAssertEqual(verified.coverage.domainExercised, ["discount"])
        XCTAssertEqual(verified.coverage.domainFraction, 0.5, "1 of 2 seams (discount, noise) swept over its domain")

        // Contrast: a single-cassette replay is boundary-covered but point-only — domain fraction 0.
        let single = Cassette(replaying: tape)
        _ = runCheckout(cassette: single, subtotal: 1000, total: baseline)
        let pointCoverage = single.coverage()
        XCTAssertEqual(pointCoverage.fraction, 1.0, "boundary-covered: both seams replayed cleanly")
        XCTAssertEqual(pointCoverage.domainFraction, 0.0, "but point-only: no seam swept over its domain")
        XCTAssertTrue(pointCoverage.domainExercised.isEmpty)
    }

    private func record(_ subtotal: Int64) -> CassetteData {
        let recording = Cassette()
        _ = runCheckout(cassette: recording, subtotal: subtotal, total: baseline)
        return recording.snapshot()
    }

    /// "Production" checkout. Reads a `discount` value seam (the same `cassette.int` primitive `SeamClock`
    /// / `SeamRNG` wrap) and a `noise` seam it does *not* act on, then posts the total computed by `total`.
    private func runCheckout(
        cassette: Cassette,
        subtotal: Int64,
        total: (_ subtotal: Int64, _ discount: Int64) -> Int64
    ) -> Trace {
        let recorder = TraceRecorder(name: "checkout", clock: ManualClock())
        let center = RecordingNotificationCenter()

        TraceContext.$current.withValue(recorder) {
            let discount = cassette.int(seam: "discount", live: { 100 }) // seam → output
            _ = cassette.int(seam: "noise", live: { 7 }) // seam read but irrelevant to behavior
            let result = total(subtotal, discount)
            center.post(name: Self.checkoutCompleted, object: nil, userInfo: ["totalCents": Int(result)])
            Haruspec.marker("checkout.completed")
        }
        return recorder.trace()
    }

    /// Pricing branches: baseline, a behavior-preserving refactor, and a path-dependent regression.
    private func baseline(_ subtotal: Int64, _ discount: Int64) -> Int64 {
        subtotal - discount
    }

    private func refactored(_ subtotal: Int64, _ discount: Int64) -> Int64 {
        subtotal + -discount
    } // ≡ baseline
}
