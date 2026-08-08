import Foundation
import HaruspecCore
import HaruspecTrace

/// Drives a fixed, deterministic checkout spec against any `CartService` implementation and
/// returns the captured trace. This is the "replay" half of capture→replay→diff: identical inputs,
/// so any difference in the output trace is attributable to the code, not the driver.
public enum CheckoutSpec {
    /// Run the canonical spec, capturing a trace under a deterministic clock.
    ///
    /// Capture is fully ambient and zero-code on the service side: `@Traced` records call/args/return
    /// against `TraceContext.current` (bound here), and an injected `RecordingNotificationCenter` records a
    /// dedicated `NotificationCenter` (isolated, so parallel runs and system noise can't leak in). The
    /// service is a plain business object with no knowledge of the oracle.
    public static func capture(
        name: String,
        _ makeService: (NotificationCenter) -> CartService
    ) -> Trace {
        let clock = ManualClock()
        let recorder = TraceRecorder(name: name, clock: clock)
        let center = RecordingNotificationCenter(names: checkoutNotificationNames)

        let service = makeService(center)

        TraceContext.$current.withValue(recorder) {
            service.addItem(sku: "COFFEE", unitPriceCents: 1299, quantity: 2)
            service.addItem(sku: "MUG", unitPriceCents: 899, quantity: 1)
            _ = service.applyPromo("SAVE10")
            service.removeItem(sku: "MUG")
            _ = service.checkout()
        }

        return recorder.trace()
    }

    /// Golden baseline behavior.
    public static func baseline() -> Trace {
        capture(name: "checkout.baseline") { CartServiceV1(center: $0) }
    }

    /// A behavior-preserving refactor (should verify EQUIVALENT).
    public static func refactor() -> Trace {
        capture(name: "checkout.refactor") { CartServiceV2(center: $0) }
    }

    /// A subtly-broken change (should be caught as DIVERGED).
    public static func regression() -> Trace {
        capture(name: "checkout.regression") { CartServiceBuggy(center: $0) }
    }

    /// A feature change: intended new behavior (loyalty points) plus one collateral regression.
    /// Verified in *extension mode* against `intent` — the intended deltas are absorbed, the
    /// collateral one is caught. (See `CartServiceV3`.)
    public static func feature() -> Trace {
        capture(name: "checkout.feature") { CartServiceV3(center: $0) }
    }

    /// The declared intent for the `feature()` change: the loyalty additions were *meant* to happen,
    /// so they must not fail the gate. Both are declared on production seams (the notifications the app
    /// actually posts), not on marker payloads. Anything else the change altered is collateral. A
    /// migration would use `Intent.none` instead — parity mode is just the empty intent.
    public static var intent: Intent {
        Intent(
            expectedNewEvents: ["LoyaltyPointsEarned"],
            expectedValueChanges: ["CheckoutDidComplete": ["pointsEarned"]]
        )
    }

    /// The declared tolerance contract for this application: fresh UUIDs/timestamps are volatile,
    /// the recompute interval has a small timing budget, and the two independent post-add
    /// notifications may be emitted in either order.
    public static var tolerances: Tolerance {
        Tolerance(
            volatileFields: [.key("orderID"), .key("issuedAt")],
            numericEpsilon: 0,
            timingBudgets: ["CartService.checkout": 50],
            unorderedGroups: [["CartDidChange", "AnalyticsDidTrack"]],
            ignoredKinds: []
        )
    }
}
