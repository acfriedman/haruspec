@testable import HaruspecCore
@testable import HaruspecSeams
@testable import HaruspecTrace
import XCTest

/// The whole loop, end to end: the **seam harness feeding the behavioral-diff engine**.
///
/// "Production" logic reads nondeterministic seams (a wall clock + an RNG A/B bucket + a config read)
/// *and* those readings flow into observable behavior (notifications + markers) captured in a
/// `TraceRecorder`. Record the seams once from the golden run; replay the *same* cassette into both
/// branches; diff the traces through the oracle.
///
/// The new thing over the original validation gate: the nondeterminism here (a timestamp, a random
/// bucket) *flows into the output*, so tolerances can't absorb it — only seam replay can. Record once,
/// replay into both branches, and a code change is isolated against a held-identical environment.
final class SeamHarnessEndToEndTests: XCTestCase {
    private static let sessionStarted = Notification.Name("SessionStarted")
    private static let checkoutCompleted = Notification.Name("CheckoutCompleted")
    private static let names: Set<String> = ["SessionStarted", "CheckoutCompleted"]

    /// Stand-in for production code. `pricing` is the only thing that differs between branches.
    private func runSession(cassette: Cassette,
                            pricing: (_ subtotal: Int, _ bucket: Int) -> Int) -> Trace {
        let recorder = TraceRecorder(name: "session", clock: ManualClock())
        let center = NotificationCenter()
        let interceptor = NotificationInterceptor(recorder: recorder, center: center, names: Self.names)
        interceptor.start(); defer { interceptor.stop() }

        let clock = SeamClock(cassette: cassette)
        var rng = SeamRNG(cassette: cassette)
        let defaults = SeamDefaults(cassette: cassette)

        TraceContext.$current.withValue(recorder) {
            let startedAtMicros = Int(clock.now() * 1_000_000) // seam: time → output
            let region = defaults.string(forKey: "region", live: { "US" }) ?? "?" // seam: config
            let bucket = Int.random(in: 0 ..< 100, using: &rng) // seam: randomness (A/B)

            center.post(name: Self.sessionStarted, object: nil,
                        userInfo: ["region": region, "startedAt": startedAtMicros])
            Haruspec.marker("session.started")

            let total = pricing(1000, bucket)
            center.post(name: Self.checkoutCompleted, object: nil, userInfo: ["totalCents": total])
            Haruspec.marker("checkout.completed")
        }
        return recorder.trace()
    }

    /// Baseline pricing: a bucket-gated A/B discount (so the RNG seam genuinely affects the output).
    private func baselinePricing(_ subtotal: Int, _ bucket: Int) -> Int {
        subtotal - (bucket < 50 ? 100 : 0)
    }

    /// Changed pricing: an unconditional +25 fee — a regression attributable to the code, independent
    /// of which bucket was recorded, so the assertion is deterministic.
    private func changedPricing(_ subtotal: Int, _ bucket: Int) -> Int {
        baselinePricing(subtotal, bucket) + 25
    }

    func testSeamReplayMakesTraceDeterministicAndCatchesCodeChange() {
        // 1. RECORD the golden run against real live seams.
        let recording = Cassette()
        let golden = runSession(cassette: recording, pricing: baselinePricing)
        let cassette = recording.snapshot()

        // 2. A fresh LIVE run reads a different timestamp/bucket, and those flow into behavior — so the
        //    trace diverges and no tolerance can absorb it (the values are real outputs, not noise).
        let liveAgain = runSession(cassette: Cassette(), pricing: baselinePricing)
        XCTAssertFalse(BehavioralDiff.compare(baseline: golden, candidate: liveAgain).isEquivalent,
                       "an un-replayed run reads different time/RNG that flows into observable behavior")

        // 3. REPLAY the same cassette into the baseline again → EQUIVALENT: replay restored determinism.
        let baselineReplay = runSession(cassette: Cassette(replaying: cassette), pricing: baselinePricing)
        let equivalence = BehavioralDiff.compare(baseline: golden, candidate: baselineReplay)
        XCTAssertTrue(equivalence.isEquivalent,
                      "replaying the recorded seams reproduces the golden behavior exactly\n\(equivalence.report())")

        // 4. REPLAY the same cassette into the CHANGED branch → DIVERGED, localized to the changed
        //    output, and attributable to the code because the environment was held identical.
        let changedReplay = runSession(cassette: Cassette(replaying: cassette), pricing: changedPricing)
        let diff = BehavioralDiff.compare(baseline: golden, candidate: changedReplay)
        XCTAssertFalse(diff.isEquivalent, "the pricing change diverges under identical replayed inputs")
        XCTAssertTrue(diff.divergences.allSatisfy { $0.label == "CheckoutCompleted" },
                      "the divergence is isolated to the changed output:\n\(diff.report())")
        XCTAssertTrue(diff.divergences.contains { $0.detail.contains("totalCents") },
                      "and it points at the wrong total:\n\(diff.report())")
    }
}
